#!/bin/bash
set -eu

error_exit() { echo "ERR: $1" >&2; exit 1; }

_escape_uci() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/'\''/\\'\''/g; s/\$/\\\$/g; s/;/\\;/g; s/&/\\&/g; s/`/\\`/g'
}

_escape_sh() {
    printf '%s' "$1" | sed 's/[`"$\\]/\\&/g'
}

is_valid_ipv4() {
    local ip="$1"
    if ! echo "$ip" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; then
        return 1
    fi
    local o1 o2 o3 o4
    IFS='.' read -r o1 o2 o3 o4 <<EOF
$ip
EOF
    for o in "$o1" "$o2" "$o3" "$o4"; do
        if ! echo "$o" | grep -qE '^[0-9]+$' || [ "$o" -lt 0 ] || [ "$o" -gt 255 ]; then
            return 1
        fi
    done
    # 拒绝保留/特殊段
    case "$o1" in
        0|127) return 1 ;;
        169) [ "$o2" -eq 254 ] && return 1 ;;
    esac
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
DNSMASQ_CUSTOM_PORT="5453"
DHCP_START="8"
DHCP_LIMIT="150"

VERSION="" PHASE="" PROFILE_TYPE=""
CUSTOM_IP="" CUSTOM_GATEWAY="" PPPOE_USERNAME="" PPPOE_PASSWORD="" ROOT_PASSWORD=""

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
        *) error_exit "未知参数 $1" ;;
    esac
done

check_build_deps

if [ -z "$VERSION" ] || [ -z "$PHASE" ]; then
    error_exit "必填 --version / --phase"
fi
if [ "$PHASE" = "after" ] && [ -z "$PROFILE_TYPE" ]; then
    error_exit "after阶段必须指定 --type main/bypass"
fi
if [ -n "$PROFILE_TYPE" ] && [ "$PROFILE_TYPE" != "main" ] && [ "$PROFILE_TYPE" != "bypass" ]; then
    error_exit "--type 仅支持 main / bypass"
fi

if [ "$PROFILE_TYPE" = "bypass" ]; then
    [ -z "$CUSTOM_IP" ] && CUSTOM_IP="$DEF_BYPASS_IP"
    [ -z "$CUSTOM_GATEWAY" ] && CUSTOM_GATEWAY="$DEF_MAIN_IP"
    is_valid_ipv4 "$CUSTOM_IP" || error_exit "非法旁路由IP: $CUSTOM_IP"
    is_valid_ipv4 "$CUSTOM_GATEWAY" || error_exit "非法旁路由网关: $CUSTOM_GATEWAY"
else
    [ -z "$CUSTOM_IP" ] && CUSTOM_IP="$DEF_MAIN_IP"
    is_valid_ipv4 "$CUSTOM_IP" || error_exit "非法主路由IP: $CUSTOM_IP"
fi

if [ -n "$PPPOE_USERNAME" ] || [ -n "$PPPOE_PASSWORD" ]; then
    if [ -z "$PPPOE_USERNAME" ] || [ -z "$PPPOE_PASSWORD" ]; then
        error_exit "PPPoE账号密码必须成对传入"
    fi
fi

SCRIPT_PATH=""
if [ "${BASH_SOURCE+set}" = "set" ] && [ -n "${BASH_SOURCE[0]}" ]; then
    SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")
elif [ -n "$0" ] && [ "$0" != "-sh" ] && [ "$0" != "sh" ]; then
    SCRIPT_PATH=$(readlink -f "$0")
fi
if [ -z "$SCRIPT_PATH" ] || [ ! -f "$SCRIPT_PATH" ]; then
    SCRIPT_PATH=$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")
fi
PROJECT_ROOT=$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd -P)
[ ! -d "$PROJECT_ROOT" ] && error_exit "无法定位项目根目录: $PROJECT_ROOT"

# ===================== before 阶段：feeds初始化优化 =====================
case "$PHASE" in
before)
    echo "[BEFORE] 初始化 feeds 配置: $VERSION"
    FEED_CONF_SRC="$PROJECT_ROOT/feeds/$VERSION.conf"
    [ -f "$FEED_CONF_SRC" ] || error_exit "缺失feed配置: $FEED_CONF_SRC"

    rm -f feeds.conf
    cp "$FEED_CONF_SRC" feeds.conf

    if grep -qs '^[^#].*src-git small' feeds.conf; then
        GOLANG_DIR="feeds/packages/lang/golang"
        if [ ! -d "$GOLANG_DIR/.git" ]; then
            echo "[BEFORE] 替换golang1.26"
            rm -rf feeds/luci/applications/luci-app-mosdns \
                feeds/packages/net/{alist,adguardhome,mosdns,xray*,v2ray*,sing*,smartdns} \
                feeds/packages/utils/v2dat \
                "$GOLANG_DIR"
            git clone --depth 1 -b 1.26 https://github.com/kenzok8/golang "$GOLANG_DIR" || error_exit "golang1.26克隆失败"
        fi
    fi
    ;;

after)
    echo "[AFTER] 生成uci-defaults配置: $PROFILE_TYPE"
    UCI_DEFAULT_OUT="$PROJECT_ROOT/files/etc/uci-defaults/99-custom-config"
    SYSCTL_DROP_FILE="$PROJECT_ROOT/files/etc/sysctl.d/99-ipforward.conf"
    mkdir -p "$(dirname "$UCI_DEFAULT_OUT")" "$(dirname "$SYSCTL_DROP_FILE")"
    rm -f "$UCI_DEFAULT_OUT" "$PROJECT_ROOT/files/etc/shadow"

    net_block=""
    firewall_block=""
    sysctl_block=""

    if [ "$PROFILE_TYPE" = "bypass" ]; then
        lan_ip_esc=$(_escape_sh "$CUSTOM_IP")
        lan_gw_esc=$(_escape_sh "$CUSTOM_GATEWAY")
        sysctl_block="net.ipv4.ip_forward=1"
        net_block=$(cat <<-EOT
uci set network.lan.proto='static'
uci set network.lan.ipaddr='$lan_ip_esc'
uci set network.lan.netmask='$SUBNET_MASK'
uci set network.lan.gateway='$lan_gw_esc'
uci set network.wan.proto='none'
uci set network.wan6.proto='none'
uci -q delete network.lan6 || true
uci set network.lan6.proto='none'
uci -q delete network.lan.dns || true
uci add_list network.lan.dns='$lan_gw_esc'
uci set dhcp.lan.ignore='1'
uci set dhcp.lan6.ignore='1'
uci -q set dhcp.@dnsmasq[0].port='$DNSMASQ_CUSTOM_PORT' || true
uci -q set dhcp.@dnsmasq[0].rebind_protection='0' || true
uci commit network dhcp
EOT
)
        firewall_block=$(cat <<-FW
uci set firewall.@zone[lan].input='ACCEPT'
uci set firewall.@zone[lan].output='ACCEPT'
uci set firewall.@zone[lan].forward='ACCEPT'
uci set firewall.@zone[lan].masq='1'
uci set firewall.@zone[lan].mtu_fix='1'
uci set firewall.@zone[wan].network=''
uci -q delete firewall.@forwarding[0]
uci -q delete firewall.@forwarding[1]
uci commit firewall
FW
)
        echo "$sysctl_block" > "$SYSCTL_DROP_FILE"
    else
        lan_ip_esc=$(_escape_sh "$CUSTOM_IP")
        wan_block=""
        if [ -n "$PPPOE_USERNAME" ]; then
            u=$(_escape_uci "$PPPOE_USERNAME")
            p=$(_escape_uci "$PPPOE_PASSWORD")
            wan_block="uci set network.wan.proto='pppoe'
uci set network.wan.username='$u'
uci set network.wan.password='$p'
uci set network.wan.ipv6='auto'
uci -q delete network.wan6 || true
uci -q delete network.lan6 || true
uci set network.lan6.proto='static'"
        else
            wan_block="uci set network.wan.proto='dhcp'
uci -q delete network.wan6 || true
uci set network.wan6.proto='dhcpv6'
uci -q delete network.lan6 || true
uci set network.lan6.proto='static'"
        fi
        bypass_dns_esc=$(_escape_sh "$DEF_BYPASS_IP")
        net_block=$(cat <<-EOT
uci set network.lan.proto='static'
uci set network.lan.ipaddr='$lan_ip_esc'
uci set network.lan.netmask='$SUBNET_MASK'
$wan_block
uci set network.wan.peerdns='0'
uci -q delete network.wan.dns || true
uci add_list network.wan.dns='$DNS_MAIN'
uci add_list network.wan.dns='$DNS_BACKUP'
uci -q delete dhcp.lan.dhcp_option || true
uci add_list dhcp.lan.dhcp_option='6,$bypass_dns_esc'
uci add_list dhcp.lan.dhcp_option='6,$DNS_MAIN'
uci add_list dhcp.lan.dhcp_option='6,$DNS_BACKUP'
uci set dhcp.lan.sequential_ip='1'
uci set dhcp.lan.start='$DHCP_START'
uci set dhcp.lan.limit='$DHCP_LIMIT'
uci -q set dhcp.@dnsmasq[0].rebind_protection='0' || true
uci commit network dhcp
EOT
)
        firewall_block=$(cat <<-FW
uci set firewall.@zone[lan].forward='ACCEPT'
uci set firewall.@zone[wan].forward='ACCEPT'
uci commit firewall
FW
)
    fi
    cat > "$UCI_DEFAULT_OUT" <<-EOF
#!/bin/sh
set -e
# 网络IP、拨号、DHCP基础配置
${net_block}
# 防火墙转发规则
${firewall_block}
# 系统基础配置：时区、主机名、NTP
uci set system.@system[0].hostname='Router-${PROFILE_TYPE}'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci -q delete system.ntp.server
uci set system.ntp.enable_server='1'
uci add_list system.ntp.server='ntp.aliyun.com'
uci add_list system.ntp.server='ntp.tencent.com'
uci add_list system.ntp.server='ntsc.ac.cn'
uci add_list system.ntp.server='cn.pool.ntp.org'
uci commit system
exit 0
EOF
    chmod 755 "$UCI_DEFAULT_OUT"
    echo "[AFTER] uci-defaults生成: $UCI_DEFAULT_OUT"

    if [ -n "$ROOT_PASSWORD" ]; then
        crypt=$(printf '%s' "$ROOT_PASSWORD" | openssl passwd -6 -stdin) || error_exit "openssl密码加密失败"
        SHADOW_FILE="$PROJECT_ROOT/files/etc/shadow"
        echo "root:$crypt:0:0:99999:7:::" > "$SHADOW_FILE"
        chmod 600 "$SHADOW_FILE"
    fi
    ;;
*) error_exit "PHASE仅支持 before / after" ;;
esac

echo "[DONE] 阶段: $PHASE 类型: ${PROFILE_TYPE:-N/A} 根目录: $PROJECT_ROOT"