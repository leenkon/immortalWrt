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

# IP简化逻辑：空值填充默认后统一校验
if [[ "$PROFILE_TYPE" == "bypass" ]]; then
    [[ -z "$CUSTOM_IP" ]] && CUSTOM_IP="$DEF_BYPASS_IP"
else
    [[ -z "$CUSTOM_IP" ]] && CUSTOM_IP="$DEF_MAIN_IP"
fi
[[ -z "$CUSTOM_GATEWAY" ]] && CUSTOM_GATEWAY="$DEF_GATEWAY"

# 仅校验填充完成后的非空IP
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
    echo "[after] 生成开机预置配置文件"
    out="$PROJECT_ROOT/files/etc/uci-defaults/99-custom-config"
    mkdir -p "$(dirname "$out")"
    net_block=""
    extra_block=""

    # ====================== 全局通用逻辑：所有机型开机替换清华opkg源（无模板依赖） ======================
    extra_block+=$(cat <<GLOBAL
# 替换软件源为清华镜像
sed -i 's|https://mirrors.vsean.net/openwrt|https://mirrors.tuna.tsinghua.edu.cn/openwrt|g' /etc/opkg/distfeeds.conf
# 追加wget弱网下载优化参数
echo "option wget '--dns-servers=114.114.114.114 --retry-connrefused --timeout=120 --tries=10 -c'" >> /etc/opkg.conf
GLOBAL
)

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
# 关闭DHCP分配，主路由全权负责
uci set dhcp.lan.ignore='1'
uci set dhcp.lan6.ignore='1'
# 释放53端口，AdGuardHome独占
uci set dhcp.@dnsmasq[0].port='0'
# 关闭本地DNS缓存
uci set dhcp.@dnsmasq[0].cachelocal='0'
# 关闭域名反弹保护（旁路无上游转发冲突）
uci set dhcp.@dnsmasq[0].rebind_protection='0'
uci commit network dhcp
EOT
)
        # ====================== 旁路由专属：全部用uci动态配置，放弃sed改静态模板 ======================
extra_block+=$(cat <<BYPASS
# 开启WAN IP动态伪装SNAT
uci set firewall.@zone[1].masq='1'

# 不全局放开output，新增规则放行本机出站（替代危险的output=ACCEPT）
uci add firewall rule
uci set firewall.@rule[-1].name='Local-All-Output-Accept'
uci set firewall.@rule[-1].direction='output'
uci set firewall.@rule[-1].src='*'
uci set firewall.@rule[-1].target='ACCEPT'
uci commit firewall
# 开启内核IPv4转发
sed -i '/^net.ipv4.ip_forward=/d' /etc/sysctl.conf
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf && sysctl -p /etc/sysctl.conf
BYPASS
)
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

    # 完整写入开机自动执行脚本
    cat > "$out" <<EOF
#!/bin/sh
# 网络基础IP/拨号配置
${net_block}
# 全局+机型专属优化
${extra_block}
# 系统时区主机名NTP
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
    echo "[after] uci-defaults 预置脚本生成完成，开机自动执行所有优化"

    # root密码写入：files目录覆盖，规避sed源码模板+密文$转义报错
    if [[ -n "$ROOT_PASSWORD" ]]; then
        echo "[after] 预置root加密密码文件"
        crypt=$(printf '%s' "$ROOT_PASSWORD" | openssl passwd -6 -stdin) || error_exit "openssl加密失败"
        mkdir -p "$PROJECT_ROOT/files/etc"
        shadow="$PROJECT_ROOT/files/etc/shadow"
        echo "root:$crypt:0:0:99999:7:::" > "$shadow"
    fi
    ;;

*) error_exit "仅支持 before / after" ;;
esac

echo "脚本执行完成"
exit 0