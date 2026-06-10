#!/bin/bash
set -euo pipefail

# 自定义错误处理
error_exit() {
    echo "错误：$1" >&2
    exit 1
}

# 增强的 UCI 字符转义
_escape_uci() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//\'/\\\'}"
    printf '%s' "$str"
}

DEF_MAIN_IP="10.10.10.1"
DEF_BYPASS_IP="10.10.10.10"
DEF_GATEWAY="10.10.10.1"

VERSION="" PHASE="" PROFILE_TYPE="" INSTALL_OAF=false
CUSTOM_IP="" CUSTOM_GATEWAY="" PPPOE_USERNAME="" PPPOE_PASSWORD="" ROOT_PASSWORD=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--version) VERSION="$2"; shift 2 ;;
        -p|--phase) PHASE="$2"; shift 2 ;;
        -t|--type) PROFILE_TYPE="$2"; shift 2 ;;
        --ip) CUSTOM_IP="$2"; shift 2 ;;
        --gateway) CUSTOM_GATEWAY="$2"; shift 2 ;;
        --pppoe-user) PPPOE_USERNAME="$2"; shift 2 ;;
        --pppoe-pass) PPPOE_PASSWORD="$2"; shift 2 ;;
        --install-oaf) INSTALL_OAF=true; shift ;;
        --root-pass) ROOT_PASSWORD="$2"; shift 2 ;;
        *) error_exit "未知选项 $1" ;;
    esac
done

# 必选参数检查
[[ -z "$VERSION" || -z "$PHASE" ]] && error_exit "必须指定版本和阶段"
[[ "$PHASE" == "after" && -z "$PROFILE_TYPE" ]] && error_exit "after 阶段必须指定路由类型"
[[ -n "$PROFILE_TYPE" && "$PROFILE_TYPE" != "main" && "$PROFILE_TYPE" != "bypass" ]] && error_exit "路由类型必须是 main 或 bypass"

# 项目根目录检查
PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)
[[ -z "$PROJECT_ROOT" || ! -d "$PROJECT_ROOT" ]] && error_exit "无法定位项目根目录"

case "$PHASE" in
    before)
        rm -f feeds.conf feeds.conf.default
        [[ -f "$PROJECT_ROOT/feeds/$VERSION.conf" ]] && cp "$PROJECT_ROOT/feeds/$VERSION.conf" feeds.conf
        echo "==== 当前生效的 feeds.conf 内容 ===="
        cat feeds.conf
        echo "=================================="
        ./scripts/feeds update -a || error_exit "feeds 更新失败"
        
        if grep -qs '^[^#].*src-git small' feeds.conf; then
            rm -rf feeds/luci/applications/luci-app-mosdns feeds/packages/net/{alist,adguardhome,mosdns,xray*,v2ray*,sing*,smartdns} feeds/packages/utils/v2dat 2>/dev/null
            rm -rf feeds/packages/lang/golang && git clone --depth 1 -b 1.26 https://github.com/kenzok8/golang feeds/packages/lang/golang 2>/dev/null || error_exit "克隆 golang 失败"
        fi       
        [[ "$INSTALL_OAF" == true ]] && {
            [[ "$PROFILE_TYPE" == "bypass" ]] && echo "⚠ 旁路由安装 OAF 可能冲突"
            rm -rf feeds/packages/net/{oaf,open-app-filter} package/feeds/packages/{oaf,luci-app-oaf,open-app-filter} 2>/dev/null
            git clone --depth 1 https://github.com/destan19/OpenAppFilter.git package/OpenAppFilter 2>/dev/null || error_exit "克隆 OpenAppFilter 失败"
        }
        ;;

    after)
        mkdir -p files/etc/uci-defaults || error_exit "创建配置目录失败"
        OUTPUT="files/etc/uci-defaults/99-custom-config"
        > "$OUTPUT" # 清空文件

        if [[ "$PROFILE_TYPE" == "bypass" ]]; then
            # 旁路由 IP/网关配置
            ROUTER_IP="${CUSTOM_IP:-$DEF_BYPASS_IP}"
            if [[ -n "$CUSTOM_GATEWAY" ]]; then
                GATEWAY_IP="$CUSTOM_GATEWAY"
            elif [[ -n "$CUSTOM_IP" ]]; then
                GATEWAY_IP="${CUSTOM_IP%.*}.1"
            else
                GATEWAY_IP="$DEF_GATEWAY"
            fi
            NETWORK_CONF="uci set network.lan.proto='static'
uci set network.lan.ipaddr='$ROUTER_IP'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='$GATEWAY_IP'
uci set network.lan.dns='$GATEWAY_IP 8.8.8.8 223.5.5.5'
uci set network.wan.proto='none' 2>/dev/null || true
uci set network.wan6.proto='none' 2>/dev/null || true
uci set dhcp.lan.ignore='1'"
        else
            # 主路由 IP/网关配置
            ROUTER_IP="${CUSTOM_IP:-$DEF_MAIN_IP}"
            if [[ -n "$PPPOE_USERNAME" && -n "$PPPOE_PASSWORD" ]]; then
                WAN_CONF="uci set network.wan.proto='pppoe'
uci set network.wan.username='$(_escape_uci "$PPPOE_USERNAME")'
uci set network.wan.password='$(_escape_uci "$PPPOE_PASSWORD")'
uci set network.wan.ipv6='auto'"
            else
                WAN_CONF="uci set network.wan.proto='dhcp'
uci set network.wan6.proto='dhcpv6'"
            fi
            GATEWAY_CONF=""
            [[ -n "$CUSTOM_GATEWAY" ]] && GATEWAY_CONF="uci set network.lan.gateway='$CUSTOM_GATEWAY'"
            
            NETWORK_CONF="uci set network.lan.proto='static'
uci set network.lan.ipaddr='$ROUTER_IP'
uci set network.lan.netmask='255.255.255.0'
${GATEWAY_CONF}
${WAN_CONF}
uci set dhcp.lan.start='11'
uci set dhcp.lan.limit='150'"
        fi

        # 写入自定义配置
        cat > "$OUTPUT" <<EOF
#!/bin/sh
$NETWORK_CONF
uci set system.@system[0].hostname='Router-${PROFILE_TYPE}'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci delete system.ntp.server 2>/dev/null
uci set system.ntp.enable_server='1'
for server in ntp.aliyun.com ntp.tencent.com ntp.ntsc.ac.cn cn.pool.ntp.org; do uci add_list system.ntp.server="\$server"; done
uci commit
/etc/init.d/network reload
exit 0
EOF
        chmod +x "$OUTPUT"

        # Root 密码配置
        [[ -n "$ROOT_PASSWORD" ]] && {
            ENCRYPTED_PASS=$(printf '%s' "$ROOT_PASSWORD" | openssl passwd -6 -stdin 2>/dev/null)
            [[ -n "$ENCRYPTED_PASS" ]] && {
                mkdir -p files/etc
                SHADOW_FILE="files/etc/shadow"
                if [[ -f "package/base-files/files/etc/shadow" ]]; then
                    cp "package/base-files/files/etc/shadow" "$SHADOW_FILE" 2>/dev/null
                else
                    echo 'root::0:0:99999:7:::' > "$SHADOW_FILE"
                fi
                awk -F: -v h="$ENCRYPTED_PASS" 'BEGIN{OFS=":"} $1=="root"{$2=h}1' "$SHADOW_FILE" > "${SHADOW_FILE}.tmp" && mv -f "${SHADOW_FILE}.tmp" "$SHADOW_FILE"
            }
        }
        ;;

    *) error_exit "无效阶段 $PHASE" ;;
esac