#!/bin/bash
set -euo pipefail

DEF_MAIN_IP="10.10.10.1"
DEF_BYPASS_IP="10.10.10.10"
DEF_GATEWAY="10.10.10.1"

VERSION="" PHASE="" PROFILE_TYPE=""
INSTALL_OAF=false
CUSTOM_IP="" CUSTOM_GATEWAY=""
PPPOE_USERNAME="" PPPOE_PASSWORD=""
ROOT_PASSWORD=""

_escape_sq() { printf '%s' "${1//\'/\'\\\'\'}"; }

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
        *) echo "错误: 未知选项 $1"; exit 1 ;;
    esac
done

[[ -z "$VERSION" || -z "$PHASE" ]] && { echo "错误: 必须指定版本 和阶段"; exit 1; }
[[ "$PHASE" =~ ^(after|oaf)$ && -z "$PROFILE_TYPE" ]] && { echo "错误: $PHASE 阶段必须指定路由类型"; exit 1; }
[[ -n "$PROFILE_TYPE" && "$PROFILE_TYPE" != "main" && "$PROFILE_TYPE" != "bypass" ]] && { echo "错误: 路由类型必须是 main 或 bypass"; exit 1; }

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

case "$PHASE" in
    before)
        rm -f feeds.conf
        [[ -f "$PROJECT_ROOT/feeds/$VERSION.conf" ]] && cp "$PROJECT_ROOT/feeds/$VERSION.conf" feeds.conf.default
        ./scripts/feeds update -a
        grep -qs 'src-git small' feeds.conf.default && {
            rm -rf feeds/luci/applications/luci-app-mosdns feeds/packages/net/{alist,adguardhome,mosdns,xray*,v2ray*,sing*,smartdns} feeds/packages/utils/v2dat 2>/dev/null
            rm -rf feeds/packages/lang/golang && git clone --depth 1 -b 1.26 https://github.com/kenzok8/golang feeds/packages/lang/golang 2>/dev/null
        }
        ;;

    oaf)
        rm -rf feeds/packages/net/{oaf,open-app-filter} package/feeds/packages/{oaf,luci-app-oaf,open-app-filter} 2>/dev/null
        [[ "$INSTALL_OAF" == true ]] && {
            [[ "$PROFILE_TYPE" == "bypass" ]] && echo "⚠ 旁路由安装 OAF 可能冲突"
            git clone --depth 1 https://github.com/destan19/OpenAppFilter.git package/OpenAppFilter 2>/dev/null && echo "CONFIG_PACKAGE_luci-app-oaf=y" >> .config
        }
        ;;

    after)
        mkdir -p files/etc/uci-defaults
        OUTPUT="files/etc/uci-defaults/99-custom-config"

        if [[ "$PROFILE_TYPE" == "bypass" ]]; then
            # 旁路由：固定IP，禁用DHCP，网关指向主路由
            ROUTER_IP="${CUSTOM_IP:-$DEF_BYPASS_IP}"
            GATEWAY_IP="${CUSTOM_GATEWAY:-${CUSTOM_IP:+${CUSTOM_IP%.*}.1}}"
            GATEWAY_IP="${GATEWAY_IP:-$DEF_GATEWAY}"
            NETWORK_CONF="uci set network.lan.proto='static'
uci set network.lan.ipaddr='$ROUTER_IP'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='$GATEWAY_IP'
uci set network.lan.dns='$GATEWAY_IP 8.8.8.8 223.5.5.5'
uci set network.wan.proto='none' 2>/dev/null
uci set network.wan6.proto='none' 2>/dev/null
uci set dhcp.lan.ignore='1'"
        else
            # 主路由：开启DHCP服务
            ROUTER_IP="${CUSTOM_IP:-$DEF_MAIN_IP}"
            WAN_CONF=$([[ -n "$PPPOE_USERNAME" && -n "$PPPOE_PASSWORD" ]] && \
                echo "uci set network.wan.proto='pppoe'
uci set network.wan.username='$(_escape_sq "$PPPOE_USERNAME")'
uci set network.wan.password='$(_escape_sq "$PPPOE_PASSWORD")'
uci set network.wan.ipv6='auto'" || \
                echo "uci set network.wan.proto='dhcp'
uci set network.wan6.proto='dhcpv6'")
            GATEWAY_CONF=$([[ -n "$CUSTOM_GATEWAY" ]] && echo "uci set network.lan.gateway='$CUSTOM_GATEWAY'")
            NETWORK_CONF="uci set network.lan.proto='static'
uci set network.lan.ipaddr='$ROUTER_IP'
uci set network.lan.netmask='255.255.255.0'
$GATEWAY_CONF
$WAN_CONF
uci set dhcp.lan.start='11'
uci set dhcp.lan.limit='150'"
        fi

        cat > "$OUTPUT" <<EOF
#!/bin/sh
$NETWORK_CONF
uci set system.@system[0].hostname='Router-${PROFILE_TYPE}'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci delete system.ntp.server 2>/dev/null
uci set system.ntp.enable_server='1'
uci add_list system.ntp.server='ntp.aliyun.com'
uci add_list system.ntp.server='ntp.tencent.com'
uci add_list system.ntp.server='ntp.ntsc.ac.cn'
uci add_list system.ntp.server='cn.pool.ntp.org'
uci commit
/etc/init.d/network reload
exit 0
EOF
        chmod +x "$OUTPUT"

        if [[ -n "$ROOT_PASSWORD" ]]; then
            ENCRYPTED_PASS=$(printf '%s' "$ROOT_PASSWORD" | openssl passwd -6 -stdin 2>/dev/null)
            if [[ -n "$ENCRYPTED_PASS" ]]; then
                mkdir -p files/etc
                cp package/base-files/files/etc/shadow files/etc/shadow 2>/dev/null || echo 'root::0:0:99999:7:::' > files/etc/shadow
                awk -F: -v h="$ENCRYPTED_PASS" 'BEGIN{OFS=":"} $1=="root"{$2=h}1' files/etc/shadow > files/etc/shadow.tmp && mv -f files/etc/shadow.tmp files/etc/shadow
            fi
        fi
        ;;

    *)
        echo "错误: 无效阶段 $PHASE"
        exit 1
        ;;
esac