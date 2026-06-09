#!/bin/bash
set -euo pipefail

VERSION="" PHASE="" PROFILE_TYPE="" INSTALL_OAF=false
CUSTOM_IP="" CUSTOM_GATEWAY="" PPPOE_USERNAME="" PPPOE_PASSWORD="" ROOT_PASSWORD=""
DEF_MAIN_IP="10.10.10.1" DEF_BYPASS_IP="10.10.10.99" DEF_GATEWAY="10.10.10.1"
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

[[ -z "$VERSION" || -z "$PHASE" ]] && { echo "错误: 必须指定版本 (-v) 和阶段 (-p)"; exit 1; }
[[ "$PHASE" =~ ^(after|oaf)$ && -z "$PROFILE_TYPE" ]] && { echo "错误: $PHASE 阶段必须指定路由类型 (-t)"; exit 1; }
[[ "$PROFILE_TYPE" && "$PROFILE_TYPE" != main && "$PROFILE_TYPE" != bypass ]] && { echo "错误: 路由类型必须是 main 或 bypass"; exit 1; }

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

[[ "$PHASE" == "after" ]] && {
    echo "--- 配置参数 ---"
    echo "路由类型: $PROFILE_TYPE"
    [[ "$PROFILE_TYPE" == "bypass" ]] && echo "IP地址: ${CUSTOM_IP:-$DEF_BYPASS_IP}" || echo "IP地址: ${CUSTOM_IP:-$DEF_MAIN_IP}"
    echo "网关: ${CUSTOM_GATEWAY:-$DEF_GATEWAY}"
    [[ -n "$PPPOE_USERNAME" ]] && echo "PPPoE: $PPPOE_USERNAME"
    [[ -n "$ROOT_PASSWORD" ]] && echo "密码: 已设置"
    echo "-----------------"
}

# before: feeds 配置与冲突处理
if [[ "$PHASE" == "before" ]]; then
    rm -f feeds.conf
    [[ -f "$PROJECT_ROOT/feeds/$VERSION.conf" ]] && cp "$PROJECT_ROOT/feeds/$VERSION.conf" feeds.conf.default
    sed -i '/src-git kenzo/d' feeds.conf.default
    sed -i '/src-git small/d' feeds.conf.default
    sed -i '1i src-git kenzo https://github.com/kenzok8/openwrt-packages' feeds.conf.default
    sed -i '2i src-git small https://github.com/kenzok8/small' feeds.conf.default
    ./scripts/feeds update -a
    rm -rf feeds/luci/applications/luci-app-mosdns feeds/packages/net/{alist,adguardhome,mosdns,xray*,v2ray*,sing*,smartdns} feeds/packages/utils/v2dat 2>/dev/null || true
    rm -rf feeds/packages/lang/golang && git clone --depth 1 -b 1.26 https://github.com/kenzok8/golang feeds/packages/lang/golang 2>/dev/null
    exit 0
fi

# oaf: 清理并可选安装
if [[ "$PHASE" == "oaf" ]]; then
    rm -rf feeds/packages/net/{oaf,open-app-filter} package/feeds/packages/{oaf,luci-app-oaf,open-app-filter} 2>/dev/null || true
    [[ "$INSTALL_OAF" == true ]] && {
        [[ "$PROFILE_TYPE" == "bypass" ]] && echo "⚠ 旁路由安装 OAF 可能与流量转发软件冲突"
        git clone --depth 1 https://github.com/destan19/OpenAppFilter.git package/OpenAppFilter 2>/dev/null && echo "CONFIG_PACKAGE_luci-app-oaf=y" >> .config
    }
    exit 0
fi

# after: 系统配置
if [[ "$PHASE" == "after" ]]; then
    if [[ "$PROFILE_TYPE" == "bypass" ]]; then
        ROUTER_IP="${CUSTOM_IP:-$DEF_BYPASS_IP}"
        GATEWAY_IP="${CUSTOM_GATEWAY:-${CUSTOM_IP:+${CUSTOM_IP%.*}.1}}"
        [[ -z "$GATEWAY_IP" ]] && GATEWAY_IP="$DEF_GATEWAY"
        NETWORK_CONF="uci set network.lan.proto='static'
uci set network.lan.ipaddr='$ROUTER_IP'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='$GATEWAY_IP'
uci set network.lan.dns='$GATEWAY_IP 223.5.5.5'
uci set network.wan.proto='none' 2>/dev/null
uci set network.wan6.proto='none' 2>/dev/null
uci set dhcp.lan.ignore='1'"
    else
        ROUTER_IP="${CUSTOM_IP:-$DEF_MAIN_IP}"
        [[ -n "$PPPOE_USERNAME" && -n "$PPPOE_PASSWORD" ]] && WAN_CONF="uci set network.wan.proto='pppoe'
uci set network.wan.username='$(_escape_sq "$PPPOE_USERNAME")'
uci set network.wan.password='$(_escape_sq "$PPPOE_PASSWORD")'
uci set network.wan.ipv6='auto'" || WAN_CONF="uci set network.wan.proto='dhcp'
uci set network.wan6.proto='dhcpv6'"
        NETWORK_CONF="uci set network.lan.ipaddr='$ROUTER_IP'
$WAN_CONF
uci set dhcp.lan.ignore='0'
uci set dhcp.lan.start='100'
uci set dhcp.lan.limit='150'
uci set dhcp.lan.leasetime='12h'"
    fi

    mkdir -p files/etc/uci-defaults
    cat > files/etc/uci-defaults/99-custom-config <<EOF
#!/bin/sh
$NETWORK_CONF
uci set system.@system[0].hostname='Router-${PROFILE_TYPE^}'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci delete system.ntp.server 2>/dev/null
uci add_list system.ntp.server='ntp.aliyun.com'
uci add_list system.ntp.server='ntp.tencent.com'
uci add_list system.ntp.server='ntp.ntsc.ac.cn'
uci add_list system.ntp.server='cn.pool.ntp.org'
uci set system.ntp.enable_server='1'
uci commit
/etc/init.d/network reload 2>/dev/null
exit 0
EOF

    [[ -n "$ROOT_PASSWORD" ]] && {
        ENCRYPTED_PASS=$(printf '%s' "$ROOT_PASSWORD" | openssl passwd -6 -stdin 2>/dev/null)
        if [[ -n "$ENCRYPTED_PASS" ]]; then
            mkdir -p files/etc
            [[ -f "package/base-files/files/etc/shadow" ]] && cp package/base-files/files/etc/shadow files/etc/shadow || cat > files/etc/shadow <<'SHADOW_EOF'
root::0:0:99999:7:::
daemon:*:0:0:99999:7:::
ftp:*:0:0:99999:7:::
network:*:0:0:99999:7:::
nobody:*:0:0:99999:7:::
dnsmasq:*:0:0:99999:7:::
logd:*:0:0:99999:7:::
SHADOW_EOF
            awk -F: -v h="$ENCRYPTED_PASS" 'BEGIN{OFS=":"} $1=="root"{$2=h}1' files/etc/shadow > files/etc/shadow.tmp && mv -f files/etc/shadow.tmp files/etc/shadow
        fi
    }
    echo "✓ 配置完成"
    exit 0
fi

echo "错误: 无效的阶段: $PHASE"
exit 1
