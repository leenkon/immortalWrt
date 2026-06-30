#!/bin/bash
set -e

error_exit() { echo "ERR: $1" >&2; exit 1; }

_escape_uci() { printf '%s' "$1" | sed "s/'/'\\\\''/g"; }

is_valid_ipv4() {
    local o1 o2 o3 o4
    IFS='.' read -r o1 o2 o3 o4 <<< "$1"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        case "$o" in ''|*[!0-9]*) return 1 ;; esac
        [ "$o" -le 255 ] || return 1
    done
    case "$o1" in 0|127) return 1 ;; 169) [ "$o2" = "254" ] && return 1 ;; esac
    [ "$o4" -eq 0 ] || [ "$o4" -eq 255 ] && return 1
    return 0
}

check_build_deps() {
    command -v openssl >/dev/null 2>&1 || error_exit "缺失依赖: openssl"
    command -v git >/dev/null 2>&1 || error_exit "缺失依赖: git"
}

DEF_MAIN_IP="10.10.10.1"
DEF_BYPASS_IP="10.10.10.2"
SUBNET_MASK="255.255.255.0"
DNS_MAIN="1.1.1.1"
DNS_BACKUP="223.5.5.5"

VERSION="" PHASE="" PROFILE_TYPE=""
CUSTOM_IP="" CUSTOM_GATEWAY="" BYPASS_IP="" PPPOE_USERNAME="" PPPOE_PASSWORD="" ROOT_PASSWORD=""

while [ $# -gt 0 ]; do
    case "$1" in
        -v|--version) VERSION="$2"; shift 2 ;;
        -p|--phase)   PHASE="$2"; shift 2 ;;
        -t|--type)    PROFILE_TYPE="$2"; shift 2 ;;
        --ip)         CUSTOM_IP="$2"; shift 2 ;;
        --gateway)    CUSTOM_GATEWAY="$2"; shift 2 ;;
        --pppoe-user) PPPOE_USERNAME="$2"; shift 2 ;;
        --pppoe-pass) PPPOE_PASSWORD="$2"; shift 2 ;;
        --root-pass)  ROOT_PASSWORD="$2"; shift 2 ;;
        --bypass-ip) BYPASS_IP="$2"; shift 2 ;;
        *) error_exit "未知参数 $1" ;;
    esac
done

check_build_deps

[ -n "$VERSION" ] && [ -n "$PHASE" ] || error_exit "必填 --version / --phase"
[ "$PHASE" = "after" ] && [ -z "$PROFILE_TYPE" ] && error_exit "after阶段必须指定 --type main/bypass/full"
case "$PROFILE_TYPE" in ""|main|bypass|full) ;; *) error_exit "--type 仅支持 main / bypass / full" ;; esac

if [ "$PROFILE_TYPE" = "bypass" ]; then
    [ -z "$CUSTOM_IP" ] && CUSTOM_IP="$DEF_BYPASS_IP"
    [ -z "$CUSTOM_GATEWAY" ] && CUSTOM_GATEWAY="$DEF_MAIN_IP"
    is_valid_ipv4 "$CUSTOM_IP" || error_exit "非法旁路由IP: $CUSTOM_IP"
    is_valid_ipv4 "$CUSTOM_GATEWAY" || error_exit "非法旁路由网关: $CUSTOM_GATEWAY"
    [ -n "$PPPOE_USERNAME" ] || [ -n "$PPPOE_PASSWORD" ] && error_exit "旁路由不支持PPPoE，请使用 --type main/full"
    [ -z "$BYPASS_IP" ] && BYPASS_IP="$CUSTOM_IP"
elif [ "$PROFILE_TYPE" = "full" ]; then
    [ -z "$CUSTOM_IP" ] && CUSTOM_IP="$DEF_MAIN_IP"
    is_valid_ipv4 "$CUSTOM_IP" || error_exit "非法路由IP: $CUSTOM_IP"
else
    [ -z "$CUSTOM_IP" ] && CUSTOM_IP="$DEF_MAIN_IP"
    is_valid_ipv4 "$CUSTOM_IP" || error_exit "非法主路由IP: $CUSTOM_IP"
    [ -z "$BYPASS_IP" ] && BYPASS_IP="$DEF_BYPASS_IP"
    is_valid_ipv4 "$BYPASS_IP" || error_exit "非法旁路路由IP: $BYPASS_IP"
fi

if [ -n "$PPPOE_USERNAME" ] || [ -n "$PPPOE_PASSWORD" ]; then
    [ -z "$PPPOE_USERNAME" ] || [ -z "$PPPOE_PASSWORD" ] && error_exit "PPPoE账号密码必须成对传入"
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)
PROJECT_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
[ -d "$PROJECT_ROOT" ] || error_exit "无法定位项目根目录: $PROJECT_ROOT"

case "$PHASE" in
before)
    echo "[diy] before: $VERSION"
    FEED_CONF_SRC="$PROJECT_ROOT/feeds/$VERSION.conf"
    [ -f "$FEED_CONF_SRC" ] || error_exit "缺失feed配置: $FEED_CONF_SRC"
    rm -f feeds.conf
    cp "$FEED_CONF_SRC" feeds.conf
    if grep -qs '^[^#].*src-git small' feeds.conf; then
        GOLANG_DIR="feeds/packages/lang/golang"
        if [ ! -d "$GOLANG_DIR/.git" ]; then
            echo "[diy] golang → 1.26"
            rm -rf feeds/luci/applications/luci-app-osdns \
                feeds/packages/net/{alist,adguardhome,mosdns,xray*,v2ray*,sing*,smartdns} \
                feeds/packages/utils/v2dat \
                "$GOLANG_DIR"
            git clone --depth 1 -b 1.26 https://github.com/kenzok8/golang "$GOLANG_DIR" || error_exit "golang1.26克隆失败"
        fi
    fi
    ;;

after)
    echo "[diy] after: $PROFILE_TYPE"
    OUT="$PROJECT_ROOT/files/etc/uci-defaults/99-custom.sh"
    SHADOW="$PROJECT_ROOT/files/etc/shadow"
    mkdir -p "$(dirname "$OUT")"
    rm -f "$OUT" "$SHADOW"

    ip_esc=$(_escape_uci "$CUSTOM_IP")

    echo '#!/bin/sh' > "$OUT"
    echo "logger -t uci-defaults \"开始应用${PROFILE_TYPE}配置\"" >> "$OUT"

    if [ "$PROFILE_TYPE" = "bypass" ]; then
        gw_esc=$(_escape_uci "$CUSTOM_GATEWAY")
        cat >> "$OUT" <<EOT
grep -q 'net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
uci set network.lan.proto='static'
uci set network.lan.ipaddr='$ip_esc'
uci set network.lan.netmask='$SUBNET_MASK'
uci set network.lan.gateway='$gw_esc'
uci -q delete network.lan.dns || true
uci add_list network.lan.dns='$DNS_MAIN'
uci add_list network.lan.dns='$DNS_BACKUP'
uci -q delete network.lan6 || true
uci -q delete network.default_route || true
uci set network.default_route=route
uci set network.default_route.interface='lan'
uci set network.default_route.target='0.0.0.0'
uci set network.default_route.netmask='0.0.0.0'
uci set network.default_route.gateway='$gw_esc'
uci -q delete network.wan || true
uci -q delete network.wan6 || true
uci commit network

uci set dhcp.lan.ignore='1'
uci set dhcp.lan6.ignore='1'
uci -q set dhcp.@dnsmasq[0].port='5453' || true
uci -q set dhcp.@dnsmasq[0].rebind_protection='0' || true
uci -q delete dhcp.@dnsmasq[0].listen_address || true
uci add_list dhcp.@dnsmasq[0].listen_address='127.0.0.1'
uci set dhcp.@dnsmasq[0].dns_redirect='0'
uci commit dhcp
LAN_FW=\$(uci show firewall | grep "\.name='lan'" | cut -d. -f1-2)
WAN_FW=\$(uci show firewall | grep "\.name='wan'" | cut -d. -f1-2)
[ -n "\$LAN_FW" ] && {
    uci set \${LAN_FW}.input='ACCEPT'
    uci set \${LAN_FW}.output='ACCEPT'
    uci set \${LAN_FW}.forward='ACCEPT'
}
[ -n "\$WAN_FW" ] && {
    uci set \${WAN_FW}.network=''
    uci set \${WAN_FW}.masq='0'
}
while uci -q delete firewall.@forwarding[0]; do :; done
uci commit firewall
uci set adguardhome.config.enabled='1'
uci commit adguardhome

# OpenClash: redir-host, DNS 劫持关闭, sniffer 预置于 openclash_custom_overwrite.yaml
uci set openclash.config.core_type='Meta'
uci set openclash.config.core_version='linux-amd64'
uci set openclash.config.enable_redirect_dns='0'
uci set openclash.config.en_mode='redir-host'
uci set openclash.config.operation_mode='redir-host'
uci set openclash.config.enable_custom_overwrite='1'
uci commit openclash
EOT
    elif [ "$PROFILE_TYPE" = "full" ]; then
        if [ -n "$PPPOE_USERNAME" ]; then
            u=$(_escape_uci "$PPPOE_USERNAME")
            p=$(_escape_uci "$PPPOE_PASSWORD")
            cat >> "$OUT" <<EOT
uci set network.wan.proto='pppoe'
uci set network.wan.username='$u'
uci set network.wan.password='$p'
uci set network.wan.ipv6='auto'
uci -q delete network.wan6 || true
EOT
        else
            cat >> "$OUT" <<EOT
uci set network.wan.proto='dhcp'
uci -q delete network.wan6 || true
uci set network.wan6.proto='dhcpv6'
EOT
        fi

        cat >> "$OUT" <<EOT
uci -q delete network.lan6 || true
uci set network.lan.ip6assign='64'
uci set network.lan.proto='static'
uci set network.lan.ipaddr='$ip_esc'
uci set network.lan.netmask='$SUBNET_MASK'
uci set network.wan.peerdns='0'
uci -q delete network.wan.dns || true
uci add_list network.wan.dns='$DNS_MAIN'
uci add_list network.wan.dns='$DNS_BACKUP'
uci commit network

grep -q 'net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

# dnsmasq: port 5353, DHCP only (ADGH 占用 53)
uci -q delete dhcp.lan.dhcp_option || true
uci add_list dhcp.lan.dhcp_option='6,$ip_esc,$DNS_MAIN,$DNS_BACKUP'
uci set dhcp.lan.start='6'
uci set dhcp.lan.limit='150'
uci -q set dhcp.@dnsmasq[0].rebind_protection='0' || true
uci set dhcp.@dnsmasq[0].sequential_ip='1'
uci -q set dhcp.@dnsmasq[0].port='5353' || true
uci -q delete dhcp.@dnsmasq[0].listen_address || true
uci add_list dhcp.@dnsmasq[0].listen_address='127.0.0.1'
uci -q delete dhcp.@dnsmasq[0].server || true
uci set dhcp.@dnsmasq[0].dns_redirect='0'
uci commit dhcp

# Block-QUIC: UDP 443 阻断，防代理逃逸
LAN_FW=\$(uci show firewall | grep "\.name='lan'" | cut -d. -f1-2)
[ -n "\$LAN_FW" ] && uci set \${LAN_FW}.forward='ACCEPT'
while uci -q delete firewall.@forwarding[0]; do :; done
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='wan'
uci add firewall rule
uci set firewall.@rule[-1].name='Block-QUIC'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest='wan'
uci set firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].dest_port='443'
uci set firewall.@rule[-1].target='REJECT'

# DNS 劫持：强制 LAN 客户端 DNS 走 ADGH(53)
chmod 755 /usr/sbin/dns-hijack
/usr/sbin/dns-hijack
uci -q delete firewall.dns_hijack_include 2>/dev/null
uci set firewall.dns_hijack_include=include
uci set firewall.dns_hijack_include.path='/usr/sbin/dns-hijack'
uci set firewall.dns_hijack_include.enabled='1'
uci commit firewall

# OAF: gateway mode
uci set oaf.global.enable='1'
uci set oaf.global.work_mode='gateway'
uci commit oaf

# AdGuardHome: port 53
uci set adguardhome.config.enabled='1'
uci set adguardhome.config.port='53'
uci set adguardhome.config.redirect='0'
uci commit adguardhome

# OpenClash: redir-host, sniffer 预置于 openclash_custom_overwrite.yaml
uci set openclash.config.core_type='Meta'
uci set openclash.config.core_version='linux-amd64'
uci set openclash.config.enable_redirect_dns='0'
uci set openclash.config.en_mode='redir-host'
uci set openclash.config.operation_mode='redir-host'
uci set openclash.config.enable_custom_overwrite='1'
uci commit openclash
EOT
    else
        if [ -n "$PPPOE_USERNAME" ]; then
            u=$(_escape_uci "$PPPOE_USERNAME")
            p=$(_escape_uci "$PPPOE_PASSWORD")
            cat >> "$OUT" <<EOT
uci set network.wan.proto='pppoe'
uci set network.wan.username='$u'
uci set network.wan.password='$p'
uci set network.wan.ipv6='auto'
uci -q delete network.wan6 || true
EOT
        else
            cat >> "$OUT" <<EOT
uci set network.wan.proto='dhcp'
uci -q delete network.wan6 || true
uci set network.wan6.proto='dhcpv6'
EOT
        fi

        cat >> "$OUT" <<EOT
uci -q delete network.lan6 || true
uci set network.lan.ip6assign='64'
uci set network.lan.proto='static'
uci set network.lan.ipaddr='$ip_esc'
uci set network.lan.netmask='$SUBNET_MASK'
uci set network.wan.peerdns='0'
uci -q delete network.wan.dns || true
uci add_list network.wan.dns='$DNS_MAIN'
uci add_list network.wan.dns='$DNS_BACKUP'
uci commit network

uci -q delete dhcp.lan.dhcp_option || true
uci add_list dhcp.lan.dhcp_option='6,$BYPASS_IP,$DNS_MAIN,$DNS_BACKUP'
uci set dhcp.lan.start='6'
uci set dhcp.lan.limit='150'
uci -q set dhcp.@dnsmasq[0].rebind_protection='0' || true
uci set dhcp.@dnsmasq[0].sequential_ip='1'
uci -q delete dhcp.@dnsmasq[0].server || true
uci add_list dhcp.@dnsmasq[0].server='$BYPASS_IP'
uci add_list dhcp.@dnsmasq[0].server='$DNS_MAIN'
uci add_list dhcp.@dnsmasq[0].server='$DNS_BACKUP'
uci set dhcp.@dnsmasq[0].strictorder='1'
uci set dhcp.@dnsmasq[0].dns_redirect='0'
uci commit dhcp

LAN_FW=\$(uci show firewall | grep "\.name='lan'" | cut -d. -f1-2)
[ -n "\$LAN_FW" ] && uci set \${LAN_FW}.forward='ACCEPT'
while uci -q delete firewall.@forwarding[0]; do :; done
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='wan'

# DNS 劫持：强制 LAN 客户端 DNS 走旁路 ADGH(53)
chmod 755 /usr/sbin/dns-hijack
/usr/sbin/dns-hijack
uci -q delete firewall.dns_hijack_include 2>/dev/null
uci set firewall.dns_hijack_include=include
uci set firewall.dns_hijack_include.path='/usr/sbin/dns-hijack'
uci set firewall.dns_hijack_include.enabled='1'
uci commit firewall

EOT
    fi

    cat >> "$OUT" <<EOT
uci set system.@system[0].hostname='Router-${PROFILE_TYPE}'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci -q delete system.ntp.server
uci add_list system.ntp.server='ntp.aliyun.com'
uci add_list system.ntp.server='cn.pool.ntp.org'
uci commit system
logger -t uci-defaults "配置应用完成"
EOT
    chmod 755 "$OUT"
    echo "[diy] 输出: $OUT"

    if [ -n "$ROOT_PASSWORD" ]; then
        crypt=$(printf '%s' "$ROOT_PASSWORD" | openssl passwd -6 -stdin) || error_exit "openssl密码加密失败"
        echo "root:$crypt:0:0:99999:7:::" > "$SHADOW"
        chmod 600 "$SHADOW"
    fi
    ;;
*) error_exit "PHASE仅支持 before / after" ;;
esac

echo "[diy] done: $PHASE ${PROFILE_TYPE:-N/A}"
