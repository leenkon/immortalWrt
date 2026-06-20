#!/bin/bash

error_exit() { echo "错误：$1" >&2; exit 1; }
_escape_uci() { printf '%s' "${1//\\/\\\\}"; }

# 默认配置
DEF_MAIN_IP="10.10.10.1"
DEF_BYPASS_IP="10.10.10.2"
DEF_GATEWAY="10.10.10.1"

# 参数解析
VERSION="" PHASE="" PROFILE_TYPE=""
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
        --root-pass) ROOT_PASSWORD="$2"; shift 2 ;;
        *) error_exit "未知选项 $1" ;;
    esac
done

# 参数验证
[[ -z "$VERSION" || -z "$PHASE" ]] && error_exit "必须指定版本和阶段"
[[ "$PHASE" == "after" && -z "$PROFILE_TYPE" ]] && error_exit "after 阶段必须指定路由类型"
[[ -n "$PROFILE_TYPE" && "$PROFILE_TYPE" != "main" && "$PROFILE_TYPE" != "bypass" ]] && error_exit "路由类型必须是 main 或 bypass"

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)
[[ -z "$PROJECT_ROOT" || ! -d "$PROJECT_ROOT" ]] && error_exit "无法定位项目根目录"

case "$PHASE" in
    before)
        rm -f feeds.conf feeds.conf.default
        [[ -f "$PROJECT_ROOT/feeds/$VERSION.conf" ]] && cp "$PROJECT_ROOT/feeds/$VERSION.conf" feeds.conf || error_exit "feeds 配置文件不存在"
        # small 源 + golang 处理
        if grep -qs '^[^#].*src-git small' feeds.conf 2>/dev/null; then
            rm -rf feeds/luci/applications/luci-app-mosdns feeds/packages/net/{alist,adguardhome,mosdns,xray*,v2ray*,sing*,smartdns} feeds/packages/utils/v2dat 2>/dev/null
            rm -rf feeds/packages/lang/golang
            timeout 120 git clone --depth 1 -b 1.26 https://github.com/kenzok8/golang feeds/packages/lang/golang 2>/dev/null || true
        fi
        ;;

    after)
        OUTPUT="$PROJECT_ROOT/files/etc/uci-defaults/99-custom-config"
        mkdir -p "$(dirname "$OUTPUT")" || error_exit "创建配置目录失败"

        if [[ "$PROFILE_TYPE" == "bypass" ]]; then
            # 旁路由配置
            ROUTER_IP="${CUSTOM_IP:-$DEF_BYPASS_IP}"
            GATEWAY_IP="${CUSTOM_GATEWAY:-${CUSTOM_IP:+${CUSTOM_IP%.*}.1}}"
            GATEWAY_IP="${GATEWAY_IP:-$DEF_GATEWAY}"
            NETWORK_CMD="uci set network.lan.proto='static'
uci set network.lan.ipaddr='$ROUTER_IP'
uci set network.lan.netmask='255.255.0.0'
uci set network.lan.gateway='$GATEWAY_IP'
uci set network.wan.proto='none'
uci set network.wan6.proto='none'
uci set network.lan6.proto='none'
uci set dhcp.lan.ignore='1'
uci set dhcp.lan6.ignore='1'
/etc/init.d/dnsmasq disable 2>/dev/null || true
uci commit network
uci commit dhcp"
        else
            # 主路由配置
            ROUTER_IP="${CUSTOM_IP:-$DEF_MAIN_IP}"
            # WAN 配置
            if [[ -n "$PPPOE_USERNAME" && -n "$PPPOE_PASSWORD" ]]; then
                WAN_CMD="uci set network.wan.proto='pppoe'
uci set network.wan.username='$(_escape_uci "$PPPOE_USERNAME")'
uci set network.wan.password='$(_escape_uci "$PPPOE_PASSWORD")'
uci set network.wan.ipv6='auto'"
            else
                WAN_CMD="uci set network.wan.proto='dhcp'
uci set network.wan6.proto='dhcpv6'"
            fi
            # 自定义网关（可选）
            [[ -n "$CUSTOM_GATEWAY" ]] && GATEWAY_CMD="uci set network.lan.gateway='$CUSTOM_GATEWAY'" || GATEWAY_CMD=""
            NETWORK_CMD="uci set network.lan.proto='static'
uci set network.lan.ipaddr='$ROUTER_IP'
uci set network.lan.netmask='255.255.0.0'
\${GATEWAY_CMD}
\${WAN_CMD}
uci set dhcp.@dnsmasq[0].noresolv='1'
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='$DEF_BYPASS_IP'
uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'
uci add_list dhcp.@dnsmasq[0].server='223.5.5.5'
uci set network.wan.dns='$DEF_BYPASS_IP 8.8.8.8 223.5.5.5'
uci set network.lan.dns='$DEF_BYPASS_IP 8.8.8.8 223.5.5.5'
uci add_list dhcp.lan.dhcp_option='6,$DEF_BYPASS_IP'
uci set dhcp.lan.start='8'
uci set dhcp.lan.limit='150'
uci commit network
uci commit dhcp"
        fi
        # 生成 uci-defaults 脚本
        cat > "$OUTPUT" <<EOF
#!/bin/sh
${NETWORK_CMD}
uci set system.@system[0].hostname='Router-${PROFILE_TYPE}'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci del_list system.ntp.server
uci set system.ntp.enable_server='1'
uci add_list system.ntp.server='ntp.aliyun.com'
uci add_list system.ntp.server='ntp.tencent.com'
uci add_list system.ntp.server='ntp.ntsc.ac.cn'
uci add_list system.ntp.server='cn.pool.ntp.org'
uci commit system
exit 0
EOF
        chmod +x "$OUTPUT"
        # Root 密码
        if [[ -n "$ROOT_PASSWORD" ]]; then
            ENCRYPTED_PASS=$(printf '%s' "$ROOT_PASSWORD" | openssl passwd -6 -stdin 2>/dev/null) && {
                mkdir -p files/etc
                cp package/base-files/files/etc/shadow files/etc/shadow 2>/dev/null || echo 'root::0:0:99999:7:::' > files/etc/shadow
                sed -i "s|^root:[^:]*:|root:$ENCRYPTED_PASS:|" files/etc/shadow
            }
        fi
        ;;

    *) error_exit "无效阶段 $PHASE" ;;
esac
