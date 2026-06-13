#!/bin/bash
# 自定义错误处理
error_exit() {
    echo "错误：$1" >&2
    exit 1
}
# UCI 字符转义
_escape_uci() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//\'/\\\'}"
    printf '%s' "$str"
}
# 默认配置
DEF_MAIN_IP="10.10.10.1"
DEF_BYPASS_IP="10.10.10.10"
DEF_GATEWAY="10.10.10.1"
# 变量初始化
VERSION="" PHASE="" PROFILE_TYPE="" INSTALL_OAF=false
CUSTOM_IP="" CUSTOM_GATEWAY="" PPPOE_USERNAME="" PPPOE_PASSWORD="" ROOT_PASSWORD=""
# 参数解析
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--version) VERSION="$2"; shift 2 ;;
        -p|--phase) PHASE="$2"; shift 2 ;;
        -t|--type) PROFILE_TYPE="$2"; shift 2 ;;
        --ip) CUSTOM_IP="$2"; shift 2 ;;
        --gateway) CUSTOM_GATEWAY="$2"; shift 2 ;;
        --pppoe-user) PPPOE_USERNAME="$2"; shift 2 ;;
        --pppoe-pass) PPPOE_PASSWORD="$2"; shift 2 ;;
        --install-oaf) INSTALL_OAF=true; shift 2 ;;
        --root-pass) ROOT_PASSWORD="$2"; shift 2 ;;
        *) error_exit "未知选项 $1" ;;
    esac
done
# 参数验证
[[ -z "$VERSION" || -z "$PHASE" ]] && error_exit "必须指定版本和阶段"
[[ "$PHASE" == "after" && -z "$PROFILE_TYPE" ]] && error_exit "after 阶段必须指定路由类型"
[[ -n "$PROFILE_TYPE" && "$PROFILE_TYPE" != "main" && "$PROFILE_TYPE" != "bypass" ]] && error_exit "路由类型必须是 main 或 bypass"
# 获取项目根目录
PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)
[[ -z "$PROJECT_ROOT" || ! -d "$PROJECT_ROOT" ]] && error_exit "无法定位项目根目录"
case "$PHASE" in
    before)
        rm -f feeds.conf feeds.conf.default
        [[ -f "$PROJECT_ROOT/feeds/$VERSION.conf" ]] && cp "$PROJECT_ROOT/feeds/$VERSION.conf" feeds.conf || error_exit "feeds 配置文件不存在"
        
        if grep -qs '^[^#].*src-git small' feeds.conf; then
            rm -rf feeds/luci/applications/luci-app-mosdns feeds/packages/net/{alist,adguardhome,mosdns,xray*,v2ray*,sing*,smartdns} feeds/packages/utils/v2dat 2>/dev/null
            rm -rf feeds/packages/lang/golang
            # 增加超时，防止git clone无限卡死
            timeout 120 git clone --depth 1 -b 1.26 https://github.com/kenzok8/golang feeds/packages/lang/golang 2>/dev/null || true
        fi

        if [[ "$INSTALL_OAF" == true && "$PROFILE_TYPE" != "bypass" ]]; then
            rm -rf feeds/oaf 2>/dev/null
            rm -rf feeds/luci/applications/luci-app-oaf 2>/dev/null
            rm -rf feeds/packages/net/appfilter feeds/packages/net/oaf 2>/dev/null
            rm -rf feeds/packages/kernel/kmod-oaf 2>/dev/null
            if grep -qs "^#.*src-git oaf" feeds.conf; then
                sed -i "s/^#\(.*src-git oaf.*\)/\1/" feeds.conf
            elif ! grep -qs "^[^#].*src-git oaf" feeds.conf; then
                echo "src-git oaf https://github.com/destan19/OpenAppFilter.git" >> feeds.conf
            fi
            timeout 120 ./scripts/feeds update oaf

            if [[ -d "$PROJECT_ROOT/oaf_files" ]]; then
                if [[ -f "$PROJECT_ROOT/oaf_files/feature.cfg" ]]; then
                    cp -f "$PROJECT_ROOT/oaf_files/feature.cfg" feeds/oaf/open-app-filter/files/ || echo "复制feature.cfg失败"
                fi
                if [[ -d "$PROJECT_ROOT/oaf_files/app_icons" ]]; then
                    mkdir -p feeds/luci-app-oaf/htdocs/luci-static/resources/ || echo "创建app_icons目标目录失败"
                    cp -rf "$PROJECT_ROOT/oaf_files/app_icons" feeds/luci-app-oaf/htdocs/luci-static/resources/ || echo "复制app_icons文件夹失败"
                fi
            fi
        else
            if grep -qs "^[^#].*src-git oaf" feeds.conf; then
                sed -i "s/^\(.*src-git oaf.*\)/#\1/" feeds.conf
                [[ -d "feeds/oaf" ]] && rm -rf feeds/oaf 2>/dev/null
            fi
        fi
        ./scripts/feeds update -a
        ;;
    after)
        mkdir -p files/etc/uci-defaults || error_exit "创建配置目录失败"
        OUTPUT="files/etc/uci-defaults/99-custom-config"
        if [[ "$PROFILE_TYPE" == "bypass" ]]; then
            ROUTER_IP="${CUSTOM_IP:-$DEF_BYPASS_IP}"
            GATEWAY_IP="${CUSTOM_GATEWAY:-$( [[ -n "$CUSTOM_IP" ]] && echo "${CUSTOM_IP%.*}.1" || echo "$DEF_GATEWAY" )}"
            NETWORK_CONF="uci set network.lan.proto='static'
uci set network.lan.ipaddr='$ROUTER_IP'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='$GATEWAY_IP'
uci set network.lan.dns='$GATEWAY_IP 8.8.8.8 223.5.5.5'
uci set network.wan.proto='none'
uci set network.wan6.proto='none'
uci set network.lan6.proto='none'
uci set dhcp.lan.ignore='1'
uci set dhcp.lan6.ignore='1'"
        else
            # 主路由配置
            ROUTER_IP="${CUSTOM_IP:-$DEF_MAIN_IP}"
            WAN_CONF=$([[ -n "$PPPOE_USERNAME" && -n "$PPPOE_PASSWORD" ]] && \
                echo "uci set network.wan.proto='pppoe'
uci set network.wan.username='$(_escape_uci "$PPPOE_USERNAME")'
uci set network.wan.password='$(_escape_uci "$PPPOE_PASSWORD")'
uci set network.wan.ipv6='auto'" || \
                echo "uci set network.wan.proto='dhcp'
uci set network.wan6.proto='dhcpv6'")
            GATEWAY_CONF=$([[ -n "$CUSTOM_GATEWAY" ]] && echo "uci set network.lan.gateway='$CUSTOM_GATEWAY'")
            NETWORK_CONF="uci set network.lan.proto='static'
uci set network.lan.ipaddr='$ROUTER_IP'
uci set network.lan.netmask='255.255.255.0'
${GATEWAY_CONF}
${WAN_CONF}
uci set network.wan.dns='8.8.8.8 223.5.5.5'
uci delete dnsmasq.@dnsmasq[0].server && uci add_list dnsmasq.@dnsmasq[0].server='8.8.8.8' && uci add_list dnsmasq.@dnsmasq[0].server='223.5.5.5'
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
