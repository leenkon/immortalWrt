#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

error_exit() { echo "ERR: $1" >&2; exit 1; }

_escape_uci() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//\'/\\\'}"
    s="${s//\$/\\\$}"
    s="${s//;/\\;}"
    s="${s//&/\\&}"
    s="${s//$'\n'/\\n}"
    printf '%s' "$s"
}

is_valid_ipv4() {
    local ip="$1"
    [[ ! "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && return 1
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        if ! [[ "$o" =~ ^[0-9]+$ ]] || (( o < 0 || o > 255 )); then
            return 1
        fi
    done
    return 0
}

# 默认常量
DEF_MAIN_IP="10.10.10.1"
DEF_BYPASS_IP="${OVERRIDE_BYPASS_IP:-10.10.10.2}"
DEF_GATEWAY="10.10.10.1"

# 参数变量
VERSION="" PHASE="" PROFILE_TYPE=""
CUSTOM_IP="" CUSTOM_GATEWAY="" PPPOE_USERNAME="" PPPOE_PASSWORD="" ROOT_PASSWORD=""

# 解析入参
while [[ $# -gt 0 ]]; do
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

# 参数校验
[[ -z "$VERSION" || -z "$PHASE" ]] && error_exit "必填参数 --version / --phase"
[[ "$PHASE" == "after" && -z "$PROFILE_TYPE" ]] && error_exit "after阶段需指定 --type main/bypass"
[[ -n "$PROFILE_TYPE" && "$PROFILE_TYPE" != "main" && "$PROFILE_TYPE" != "bypass" ]] && error_exit "type仅支持 main / bypass"

for ip in "$CUSTOM_IP" "$CUSTOM_GATEWAY" "$DEF_MAIN_IP" "$DEF_BYPASS_IP" "$DEF_GATEWAY"; do
    if [[ -n "$ip" ]]; then
        is_valid_ipv4 "$ip" || error_exit "非法IP: $ip"
    fi
done

if [[ -n "$PPPOE_USERNAME" || -n "$PPPOE_PASSWORD" ]]; then
    [[ -z "$PPPOE_USERNAME" || -z "$PPPOE_PASSWORD" ]] && error_exit "pppoe user/pass必须成对传入"
fi

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ ! -d "$PROJECT_ROOT" ]] && error_exit "无法定位项目根目录"

case "$PHASE" in
before)
    echo "[before] 初始化feeds源"
    rm -f feeds.conf feeds.conf.default
    feed_file="$PROJECT_ROOT/feeds/$VERSION.conf"
    [[ -f "$feed_file" ]] || error_exit "缺失 $feed_file"
    cp "$feed_file" feeds.conf

    if grep -qs '^[^#].*src-git small' feeds.conf; then
        echo "[before] 替换golang1.26"
        rm -rf \
            feeds/luci/applications/luci-app-mosdns \
            feeds/packages/net/{alist,adguardhome,mosdns,xray*,v2ray*,sing*,smartdns} \
            feeds/packages/utils/v2dat \
            feeds/packages/lang/golang
        git clone --depth 1 -b 1.26 https://github.com/kenzok8/golang feeds/packages/lang/golang
    fi
    ;;

after)
    echo "[after] 生成预置配置"
    out="$PROJECT_ROOT/files/etc/uci-defaults/99-custom-config"
    mkdir -p "$(dirname "$out")"
    net_block=""
    echo "[after] 固化清华软件源"
    OPKG_CONF="$PROJECT_ROOT/package/base-files/files/etc/opkg/distfeeds.conf"
    if [[ -f "$OPKG_CONF" ]]; then
        sed -i 's|https://mirrors.vsean.net/openwrt|https://mirrors.tuna.tsinghua.edu.cn/openwrt|g' "$OPKG_CONF"
    fi

    if [[ "$PROFILE_TYPE" == "bypass" ]]; then
        lan_ip="${CUSTOM_IP:-$DEF_BYPASS_IP}"
        if [[ -n "$CUSTOM_GATEWAY" ]]; then
            lan_gw="$CUSTOM_GATEWAY"
        elif [[ -n "$CUSTOM_IP" ]]; then
            lan_gw="${CUSTOM_IP%.*}.1"
            is_valid_ipv4 "$lan_gw" || error_exit "自动推导网关非法 $lan_gw"
        else
            lan_gw="$DEF_GATEWAY"
        fi

net_block=$(cat <<EOT
uci set network.lan.proto='static'
uci set network.lan.ipaddr='$lan_ip'
uci set network.lan.netmask='255.255.0.0'
uci set network.lan.gateway='$lan_gw'
uci set network.wan.proto='none'
uci set network.wan6.proto='none'
uci set network.lan6.proto='none'
uci set dhcp.lan.ignore='1'
uci set dhcp.lan6.ignore='1'
uci commit network dhcp
EOT
)
        echo "[after] 旁路由防火墙/转发固化"
        FIREWALL_CONF="$PROJECT_ROOT/package/base-files/files/etc/config/firewall"
        touch "$FIREWALL_CONF" && echo "#旁路由防火墙/转发固化" >> "$FIREWALL_CONF"
        SYSCTL_CONF="$PROJECT_ROOT/package/base-files/files/etc/sysctl.conf"
        sed -i '/config zone/,/wan/{s/option name '\''wan'\''/&\n\toption masq '\''1'\''/}' "$FIREWALL_CONF"
        sed -i 's/option flow_offloading '\''1'\''/option flow_offloading '\''0'\''/' "$FIREWALL_CONF"
        sed -i 's/option flow_offloading_hw '\''1'\''/option flow_offloading_hw '\''0'\''/' "$FIREWALL_CONF"
        sed -i 's/option output '\''REJECT'\''/option output '\''ACCEPT'\''/' "$FIREWALL_CONF"
        mkdir -p "$(dirname "$SYSCTL_CONF")" && touch "$SYSCTL_CONF" && echo "net.ipv4.ip_forward=1" >> "$SYSCTL_CONF"
    else
        lan_ip="${CUSTOM_IP:-$DEF_MAIN_IP}"
        gw_cmd=""
        [[ -n "$CUSTOM_GATEWAY" ]] && gw_cmd="uci set network.lan.gateway='$CUSTOM_GATEWAY'"

        wan_block=""
        if [[ -n "$PPPOE_USERNAME" ]]; then
            u="$(_escape_uci "$PPPOE_USERNAME")"
            p="$(_escape_uci "$PPPOE_PASSWORD")"
            wan_block="uci set network.wan.proto='pppoe'
uci set network.wan.username='$u'
uci set network.wan.password='$p'
uci set network.wan.ipv6='auto'"
        else
            wan_block="uci set network.wan.proto='dhcp'
uci set network.wan6.proto='dhcpv6'"
        fi
net_block=$(cat <<EOT
uci set network.lan.proto='static'
uci set network.lan.ipaddr='$lan_ip'
uci set network.lan.netmask='255.255.255.0'
$gw_cmd
$wan_block
uci set network.wan.norelease='1'
uci set network.wan.peerdns='0'
uci -q delete network.wan.dns
uci add_list network.wan.dns='8.8.8.8'
uci add_list network.wan.dns='223.5.5.5'
uci -q delete network.lan.dns
uci add_list network.lan.dns='8.8.8.8'
uci add_list network.lan.dns='223.5.5.5'
uci -q delete dhcp.@dnsmasq[0].server
uci add_list dhcp.@dnsmasq[0].server='$DEF_BYPASS_IP'
uci add_list dhcp.@dnsmasq[0].server='223.5.5.5'
uci add_list dhcp.@dnsmasq[0].server='8.8.8.8'
uci del_list dhcp.lan.dhcp_option='6,*'
uci add_list dhcp.lan.dhcp_option='6,$DEF_BYPASS_IP,223.5.5.5,8.8.8.8'
uci set dhcp.lan.sequential_ip='1'
uci set dhcp.lan.start='8'
uci set dhcp.lan.limit='150'
uci commit network dhcp
EOT
)
    fi
cat > "$out" <<EOF
#!/bin/sh
${net_block}
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
    chmod +x "$out"
    echo "[after] 预置配置写入完成"

    # 设置root密码
    if [[ -n "$ROOT_PASSWORD" ]]; then
        echo "[after] 写入root密码"
        crypt=$(printf '%s' "$ROOT_PASSWORD" | openssl passwd -6 -stdin) || error_exit "openssl加密失败"
        mkdir -p files/etc
        shadow="files/etc/shadow"
        [[ -f package/base-files/files/etc/shadow ]] && cp package/base-files/files/etc/shadow "$shadow" || echo 'root::0:0:99999:7:::' > "$shadow"
        sed -i "s|^root:[^:]*:|root:$crypt:|" "$shadow"
    fi
    ;;
*) error_exit "仅支持 before / after 阶段" ;;
esac
echo "脚本执行完成"
exit 0