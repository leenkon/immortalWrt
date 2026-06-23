#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# ===================== 工具函数优化 =====================
error_exit() { echo "ERR: $1" >&2; exit 1; }

# 修复换行转义问题，完善所有shell元字符逃逸
_escape_uci() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//\'/\\\'}"
    s="${s//\$/\\\$}"
    s="${s//;/\\;}"
    s="${s//&/\\&}"
    s="${s//`/\\`}"
    s="${s//$'\n'/\\$'\n'}"
    printf '%s' "$s"
}

# 新增：shell变量逃逸，用于写入uci-defaults脚本
_escape_sh() {
    printf '%s' "$1" | sed 's/[`"$\\]/\\&/g'
}

# 增强IP校验：排除广播、0段、保留地址
is_valid_ipv4() {
    local ip="$1"
    [[ ! "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && return 1
    IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        [[ ! "$o" =~ ^[0-9]+$ || $o -lt 0 || $o -gt 255 ]] && return 1
    done
    # 过滤无效保留地址
    [[ "$o1" == 0 || "$o1" == 127 || "$o1" == 169 && "$o2" == 254 ]] && return 1
    [[ "$o4" == 0 || "$o4" == 255 ]] && return 1
    return 0
}

# 校验编译依赖
check_build_deps() {
    command -v openssl &>/dev/null || error_exit "构建依赖缺失：openssl，请先安装"
    command -v git &>/dev/null || error_exit "构建依赖缺失：git"
}

# ===================== 常量定义，调整优先级 =====================
# 环境变量仅作为兜底，入参--ip优先覆盖
DEF_MAIN_IP="10.10.10.1"
DEF_BYPASS_IP="10.10.10.2"
OVERRIDE_BYPASS_IP="${OVERRIDE_BYPASS_IP:-$DEF_BYPASS_IP}"
SUBNET_MASK="255.255.255.0"
DNS_MAIN="1.1.1.1"
DNS_BACKUP="223.5.5.5"
DNSMASQ_CUSTOM_PORT="5453"
DHCP_START="8"
DHCP_LIMIT="150"

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

# 前置依赖检测
check_build_deps

# 基础参数校验
[[ -z "$VERSION" || -z "$PHASE" ]] && error_exit "必填 --version / --phase"
[[ "$PHASE" == "after" && -z "$PROFILE_TYPE" ]] && error_exit "after阶段必须指定 --type main/bypass"
[[ -n "$PROFILE_TYPE" && "$PROFILE_TYPE" != "main" && "$PROFILE_TYPE" != "bypass" ]] && error_exit "--type 仅支持 main / bypass"

# IP逻辑优化：入参 > 默认环境变量
if [[ "$PROFILE_TYPE" == "bypass" ]]; then
    [[ -z "$CUSTOM_IP" ]] && CUSTOM_IP="$DEF_BYPASS_IP"
    [[ -z "$CUSTOM_GATEWAY" ]] && CUSTOM_GATEWAY="$DEF_MAIN_IP"
    is_valid_ipv4 "$CUSTOM_IP" || error_exit "非法旁路由IP: $CUSTOM_IP"
    is_valid_ipv4 "$CUSTOM_GATEWAY" || error_exit "非法旁路由网关: $CUSTOM_GATEWAY"
else
    [[ -z "$CUSTOM_IP" ]] && CUSTOM_IP="$DEF_MAIN_IP"
    is_valid_ipv4 "$CUSTOM_IP" || error_exit "非法主路由IP: $CUSTOM_IP"
    if [[ -n "$CUSTOM_GATEWAY" ]]; then
        is_valid_ipv4 "$CUSTOM_GATEWAY" || error_exit "非法主路由静态网关: $CUSTOM_GATEWAY"
    fi
fi

# PPPoE成对校验
if [[ -n "$PPPOE_USERNAME" || -n "$PPPOE_PASSWORD" ]]; then
    [[ -z "$PPPOE_USERNAME" || -z "$PPPOE_PASSWORD" ]] && error_exit "PPPoE账号密码必须成对传入"
fi

# 修复软链接路径解析问题
SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")
PROJECT_ROOT=$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd -P)
[[ ! -d "$PROJECT_ROOT" ]] && error_exit "无法定位项目根目录: $PROJECT_ROOT"

# ===================== before 阶段：feeds初始化优化 =====================
case "$PHASE" in
before)
    echo "[BUILD BEFORE] 开始初始化 feeds 配置，版本: $VERSION"
    FEED_CONF_SRC="$PROJECT_ROOT/feeds/$VERSION.conf"
    [[ -f "$FEED_CONF_SRC" ]] || error_exit "缺失feed配置文件: $FEED_CONF_SRC"

    # 备份原始feeds.conf，不直接删除default
    [[ -f feeds.conf ]] && cp feeds.conf feeds.conf.bak
    rm -f feeds.conf
    cp "$FEED_CONF_SRC" feeds.conf
    echo "[BUILD BEFORE] 已加载版本对应feeds配置"

    # 仅当包含small源时替换golang，增加重复执行判断
    if grep -qs '^[^#].*src-git small' feeds.conf; then
        GOLANG_DIR="feeds/packages/lang/golang"
        if [[ ! -d "$GOLANG_DIR/.git" ]]; then
            echo "[BUILD BEFORE] 替换golang1.26，清理旧依赖目录"
            rm -rf \
                feeds/luci/applications/luci-app-mosdns \
                feeds/packages/net/{alist,adguardhome,mosdns,xray*,v2ray*,sing*,smartdns} \
                feeds/packages/utils/v2dat \
                "$GOLANG_DIR"
            git clone --depth 1 -b 1.26 https://github.com/kenzok8/golang "$GOLANG_DIR" || error_exit "golang1.26克隆失败"
            echo "[BUILD BEFORE] golang1.26 替换完成"
        else
            echo "[BUILD BEFORE] golang目录已存在，跳过克隆"
        fi
    fi
    echo "[BUILD BEFORE] feeds预处理完成"
    ;;

# ===================== after 阶段：生成固件预置配置（大量逻辑修复） =====================
after)
    echo "[BUILD AFTER] 生成uci-defaults预置配置，机型: $PROFILE_TYPE"
    UCI_DEFAULT_OUT="$PROJECT_ROOT/files/etc/uci-defaults/99-custom-config"
    SYSCTL_DROP_FILE="$PROJECT_ROOT/files/etc/sysctl.d/99-ipforward.conf"
    mkdir -p "$(dirname "$UCI_DEFAULT_OUT")" "$(dirname "$SYSCTL_DROP_FILE")"
    # 清理旧配置残留，避免叠加冲突
    rm -f "$UCI_DEFAULT_OUT" "$PROJECT_ROOT/files/etc/shadow"

    net_block=""
    firewall_block=""
    sysctl_block=""

    if [[ "$PROFILE_TYPE" == "bypass" ]]; then
        # 旁路由配置修复：开启转发、防火墙放行、dnsmasq关闭53端口
        lan_ip_esc=$(_escape_sh "$CUSTOM_IP")
        lan_gw_esc=$(_escape_sh "$CUSTOM_GATEWAY")
        sysctl_block+="# 旁路由强制开启IPv4转发（sysctl.d规范路径）
net.ipv4.ip_forward=1
"
        net_block=$(cat <<-EOT
uci set network.lan.proto='static'
uci set network.lan.ipaddr='$lan_ip_esc'
uci set network.lan.netmask='$SUBNET_MASK'
uci set network.lan.gateway='$lan_gw_esc'
# 旁路由WAN禁用
uci set network.wan.proto='none'
uci set network.wan6.proto='none'
uci set network.lan6.proto='none'
# LAN上游DNS
uci -q delete network.lan.dns || true
uci add_list network.lan.dns='$DNS_MAIN'
uci add_list network.lan.dns='$DNS_BACKUP'
# 关闭本机DHCP服务
uci set dhcp.lan.ignore='1'
uci set dhcp.lan6.ignore='1'
# dnsmasq仅监听自定义端口，释放53给ADGH/Clash
uci -q set dhcp.@dnsmasq[0].port='$DNSMASQ_CUSTOM_PORT' || true
uci -q set dhcp.@dnsmasq[0].bind_dynamic='0' || true
uci -q set dhcp.@dnsmasq[0].rebind_protection='0' || true
uci commit network dhcp
EOT
)
        # 旁路由防火墙核心修复：转发+masquerade，否则无法上网
        firewall_block=$(cat <<-FW
# 旁路由LAN流量转发
uci set firewall.@zone[0].forward='ACCEPT'
uci set firewall.@zone[1].forward='ACCEPT'
uci set firewall.@nat[0].target='MASQUERADE'
uci commit firewall
FW
)
        # 写入sysctl.d替代修改全局sysctl.conf
        echo "$sysctl_block" > "$SYSCTL_DROP_FILE"
    else
        # 主路由配置修复：兼容无旁路由场景、统一ipv6、清理重复DNS
        lan_ip_esc=$(_escape_sh "$CUSTOM_IP")
        wan_block=""
        if [[ -n "$PPPOE_USERNAME" ]]; then
            u=$(_escape_uci "$PPPOE_USERNAME")
            p=$(_escape_uci "$PPPOE_PASSWORD")
            wan_block="uci set network.wan.proto='pppoe'
uci set network.wan.username='$u'
uci set network.wan.password='$p'
uci set network.wan.ipv6='auto'"
        else
            wan_block="uci set network.wan.proto='dhcp'
uci set network.wan6.proto='dhcpv6'"
        fi
        # 主路由DHCP优化：旁路由DNS可选兼容，无旁路由则回退公共DNS
        bypass_dns_esc=$(_escape_sh "$DEF_BYPASS_IP")
        net_block=$(cat <<-EOT
uci set network.lan.proto='static'
uci set network.lan.ipaddr='$lan_ip_esc'
uci set network.lan.netmask='$SUBNET_MASK'
$wan_block
uci set network.wan.norelease='1'
uci set network.wan.peerdns='0'
# WAN DNS
uci -q delete network.wan.dns || true
uci add_list network.wan.dns='$DNS_MAIN'
uci add_list network.wan.dns='$DNS_BACKUP'
# LAN DNS
uci -q delete network.lan.dns || true
uci add_list network.lan.dns='$DNS_MAIN'
uci add_list network.lan.dns='$DNS_BACKUP'
# DHCP下发DNS：优先旁路由，无旁路由自动使用公共DNS
uci del_list dhcp.lan.dhcp_option='6,*'
uci add_list dhcp.lan.dhcp_option='6,$bypass_dns_esc,$DNS_MAIN,$DNS_BACKUP'
# DHCP地址池
uci set dhcp.lan.sequential_ip='1'
uci set dhcp.lan.start='$DHCP_START'
uci set dhcp.lan.limit='$DHCP_LIMIT'
# 全局关闭DNS重绑定保护
uci -q set dhcp.@dnsmasq[0].rebind_protection='0' || true
uci commit network dhcp
EOT
)
    fi

    # 组装最终开机脚本，增加错误捕获set -e
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
uci del_list system.ntp.server
uci set system.ntp.enable_server='1'
uci add_list system.ntp.server='ntp.aliyun.com'
uci add_list system.ntp.server='ntp.tencent.com'
uci add_list system.ntp.ntsc.ac.cn'
uci add_list system.ntp.server='cn.pool.ntp.org'
uci commit system
exit 0
EOF
    chmod 755 "$UCI_DEFAULT_OUT"
    echo "[BUILD AFTER] uci-defaults 脚本生成完成: $UCI_DEFAULT_OUT"

    # root密码预置优化
    if [[ -n "$ROOT_PASSWORD" ]]; then
        echo "[BUILD AFTER] 加密root密码写入files/etc/shadow"
        crypt=$(printf '%s' "$ROOT_PASSWORD" | openssl passwd -6 -stdin) || error_exit "openssl密码加密失败"
        SHADOW_FILE="$PROJECT_ROOT/files/etc/shadow"
        mkdir -p "$(dirname "$SHADOW_FILE")"
        echo "root:$crypt:0:0:99999:7:::" > "$SHADOW_FILE"
        chmod 600 "$SHADOW_FILE"
    fi
    ;;
*) error_exit "PHASE仅支持 before / after" ;;
esac

echo "========================================"
echo "脚本执行全部完成，阶段: $PHASE 类型: ${PROFILE_TYPE:-N/A}"
echo "项目根目录: $PROJECT_ROOT"
echo "========================================"
exit 0