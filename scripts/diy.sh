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
        [[ ! "$o" =~ ^[0-9]+$ || $o -lt 0 || $o -gt 255 ]] && return 1
    done
    return 0
}

# 默认常量
DEF_MAIN_IP="10.10.10.1"
DEF_BYPASS_IP="${OVERRIDE_BYPASS_IP:-10.10.10.2}"
DEF_GATEWAY="10.10.10.1"

# 参数容器
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

# 基础参数校验
[[ -z "$VERSION" || -z "$PHASE" ]] && error_exit "必填 --version / --phase"
[[ "$PHASE" == "after" && -z "$PROFILE_TYPE" ]] && error_exit "after需指定 --type main/bypass"
[[ -n "$PROFILE_TYPE" && "$PROFILE_TYPE" != "main" && "$PROFILE_TYPE" != "bypass" ]] && error_exit "type仅支持 main / bypass"

# ===================== 简化IP逻辑：空值填充默认后统一校验 =====================
# 填充IP默认值
if [[ "$PROFILE_TYPE" == "bypass" ]]; then
    [[ -z "$CUSTOM_IP" ]] && CUSTOM_IP="$DEF_BYPASS_IP"
else
    [[ -z "$CUSTOM_IP" ]] && CUSTOM_IP="$DEF_MAIN_IP"
fi
[[ -z "$CUSTOM_GATEWAY" ]] && CUSTOM_GATEWAY="$DEF_GATEWAY"

# 仅校验最终使用的两个IP，无空变量
for ip in "$CUSTOM_IP" "$CUSTOM_GATEWAY"; do
    is_valid_ipv4 "$ip" || error_exit "非法IP: $ip"
done

# PPPoE成对校验
if [[ -n "$PPPOE_USERNAME" || -n "$PPPOE_PASSWORD" ]]; then
    [[ -z "$PPPOE_USERNAME" || -z "$PPPOE_PASSWORD" ]] && error_exit "pppoe user/pass成对传入"
fi

# 项目根目录
PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ ! -d "$PROJECT_ROOT" ]] && error_exit "无法定位项目根目录"

case "$PHASE" in
before)
    echo "[before] 初始化feeds"
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

    # 全局固化清华opkg源
    echo "[after] 替换清华软件源"
    OPKG_CONF="$PROJECT_ROOT/package/base-files/files/etc/opkg/distfeeds.conf"
    [[ -f "$OPKG_CONF" ]] && sed -i 's|https://mirrors.vsean.net/openwrt|https://mirrors.tuna.tsinghua.edu.cn/openwrt|g' "$OPKG_CONF"

    if [[ "$PROFILE_TYPE" == "bypass" ]]; then
        lan_ip="$CUSTOM_IP"
        if [[ -n "$CUSTOM_GATEWAY" ]]; then
            lan_gw="$CUSTOM_GATEWAY"
        else
            lan_gw="${CUSTOM_IP%.*}.1"
            is_valid_ipv4 "$lan_gw" || error_exit "自动推导网关非法 $lan_gw"
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
        # 旁路由防火墙/转发优化
        echo "[after] 旁路由网络固化"
        FIREWALL_CONF="$PROJECT_ROOT/package/base-files/files/etc/config/firewall"
        SYSCTL_CONF="$PROJECT_ROOT/package/base-files/files/etc/sysctl.conf"
        if [[ -f "$FIREWALL_CONF" ]]; then
            sed -i '/config zone/,/wan/{s/option name '\''wan'\''/&\n\toption masq '\''1'\''/}' "$FIREWALL_CONF"
            sed -i 's/option flow_offloading '\''1'\''/option flow_offloading '\''0'\''/' "$FIREWALL_CONF"
            sed -i 's/option flow_offloading_hw '\''1'\''/option flow_offloading_hw '\''0'\''/' "$FIREWALL_CONF"
            sed -i 's/option output '\''REJECT'\''/option output '\''ACCEPT'\''/' "$FIREWALL_CONF"
        else
            echo "[WARN] 防火墙模板缺失，跳过修改"
        fi
        # 内核转发，去重写入
        mkdir -p "$(dirname "$SYSCTL_CONF")"
        touch "$SYSCTL_CONF"
        sed -i '/^net.ipv4.ip_forward=/d' "$SYSCTL_CONF"
        echo "net.ipv4.ip_forward=1" >> "$SYSCTL_CONF"
    else
        # 主路由网络配置
        lan_ip="$CUSTOM_IP"
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

    # 写入uci默认配置
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

    # 写入root加密密码（修复$符号转义.config报错）
    if [[ -n "$ROOT_PASSWORD" ]]; then
        echo "[after] 写入root密码"
        crypt=$(printf '%s' "$ROOT_PASSWORD" | openssl passwd -6 -stdin) || error_exit "openssl加密失败"
        mkdir -p "$PROJECT_ROOT/files/etc"
        shadow="$PROJECT_ROOT/files/etc/shadow"
        [[ -f "$PROJECT_ROOT/package/base-files/files/etc/shadow" ]] && cp "$PROJECT_ROOT/package/base-files/files/etc/shadow" "$shadow" || echo 'root::0:0:99999:7:::' > "$shadow"
        sed -i 's#^root:[^:]*:#root:'"$crypt":'#' "$shadow"
    fi
    ;;

*) error_exit "仅支持 before / after" ;;
esac

echo "脚本执行完成"
exit 0