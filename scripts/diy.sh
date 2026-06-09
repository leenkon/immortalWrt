#!/bin/bash
set -euo pipefail

VERSION="" PHASE="" PROFILE_TYPE="" INSTALL_OAF=false
CUSTOM_IP="" CUSTOM_GATEWAY="" PPPOE_USERNAME="" PPPOE_PASSWORD="" ROOT_PASSWORD=""

DEF_MAIN_IP="192.168.1.1"
DEF_BYPASS_IP="192.168.1.2"
DEF_MAIN_GATEWAY="192.168.1.1"

# 将单引号 ' 转义为 shell 安全的 '\''
_escape_sq() {
    printf '%s' "${1//\'/\'\\\'\'}"
}

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
[[ -n "$PROFILE_TYPE" && "$PROFILE_TYPE" != "main" && "$PROFILE_TYPE" != "bypass" ]] && { echo "错误: 路由类型必须是 main 或 bypass"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# --- before: feeds 配置 ---
if [[ "$PHASE" == "before" ]]; then
    rm -f feeds.conf

    FEEDS_CONF="$PROJECT_ROOT/feeds/$VERSION.conf"
    if [[ -f "$FEEDS_CONF" ]]; then
        cp "$FEEDS_CONF" feeds.conf.default
        echo "✓ 已应用 feeds 配置: $VERSION.conf"
    else
        echo "ℹ 未找到 $VERSION.conf，保留 ImmortalWrt 默认 feeds"
    fi
    exit 0
fi

# --- oaf: 清理并可选安装 ---
if [[ "$PHASE" == "oaf" ]]; then
    rm -rf feeds/packages/net/oaf feeds/packages/net/open-app-filter \
           package/feeds/packages/oaf package/feeds/packages/luci-app-oaf \
           package/feeds/packages/open-app-filter 2>/dev/null || true
    echo "✓ 清理自带 OAF 完成"

    if [[ "$INSTALL_OAF" == true ]]; then
        [[ "$PROFILE_TYPE" == "bypass" ]] && echo "⚠ 旁路由安装 OAF 可能与流量转发软件冲突"
        if git clone --depth 1 https://github.com/destan19/OpenAppFilter.git package/OpenAppFilter 2>/dev/null; then
            echo "CONFIG_PACKAGE_luci-app-oaf=y" >> .config
            echo "✓ 官方 OAF 安装完成"
        else
            echo "✗ OAF 安装失败（可能是网络问题），跳过"
        fi
    fi
    exit 0
fi

# --- after: 系统配置 ---
if [[ "$PHASE" == "after" ]]; then

    if [[ "$PROFILE_TYPE" == "bypass" ]]; then
        ROUTER_IP="${CUSTOM_IP:-$DEF_BYPASS_IP}"
        GATEWAY_IP="${CUSTOM_GATEWAY:-${CUSTOM_IP:+${CUSTOM_IP%.*}.1}}"
        [[ -z "$GATEWAY_IP" ]] && GATEWAY_IP="$DEF_MAIN_GATEWAY"
        HOSTNAME="Router-Bypass"
        echo "→ 配置: 旁路由 | IP: $ROUTER_IP | 网关: $GATEWAY_IP"
    else
        ROUTER_IP="${CUSTOM_IP:-$DEF_MAIN_IP}"
        HOSTNAME="Router-Main"
        echo "→ 配置: 主路由 | IP: $ROUTER_IP"
    fi

    PPPOE_USERNAME_SAFE=$(_escape_sq "$PPPOE_USERNAME")
    PPPOE_PASSWORD_SAFE=$(_escape_sq "$PPPOE_PASSWORD")

    mkdir -p files/etc/uci-defaults
    BOOT_SCRIPT="files/etc/uci-defaults/99-custom-config"

    {
        echo '#!/bin/sh'
        echo ''

        if [[ "$PROFILE_TYPE" == "bypass" ]]; then
            cat <<CUSTOM_EOF
uci set network.lan.proto='static'
uci set network.lan.ipaddr='$ROUTER_IP'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='$GATEWAY_IP'
uci set network.lan.dns='$GATEWAY_IP 223.5.5.5'
uci set network.wan.proto='none' 2>/dev/null
uci set network.wan6.proto='none' 2>/dev/null
uci set dhcp.lan.ignore='1'
uci delete dhcp.lan.start 2>/dev/null
uci delete dhcp.lan.limit 2>/dev/null
uci delete dhcp.lan.leasetime 2>/dev/null

CUSTOM_EOF
        else
            cat <<CUSTOM_EOF
uci set network.lan.ipaddr='$ROUTER_IP'
CUSTOM_EOF

            if [[ -n "$PPPOE_USERNAME" && -n "$PPPOE_PASSWORD" ]]; then
                cat <<CUSTOM_EOF
uci set network.wan.proto='pppoe'
uci set network.wan.username='$PPPOE_USERNAME_SAFE'
uci set network.wan.password='$PPPOE_PASSWORD_SAFE'
uci set network.wan.ipv6='auto'
CUSTOM_EOF
            else
                cat <<'CUSTOM_EOF'
uci set network.wan.proto='dhcp'
uci set network.wan6.proto='dhcpv6'
CUSTOM_EOF
            fi

            cat <<'CUSTOM_EOF'

uci set dhcp.lan.ignore='0'
uci set dhcp.lan.start='100'
uci set dhcp.lan.limit='150'
uci set dhcp.lan.leasetime='12h'

CUSTOM_EOF
        fi

        cat <<CUSTOM_EOF
uci set system.@system[0].hostname='$HOSTNAME'
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
CUSTOM_EOF
    } > "$BOOT_SCRIPT"

    chmod +x "$BOOT_SCRIPT"
    echo "✓ uci-defaults 脚本创建完成"

    if [[ -n "$ROOT_PASSWORD" ]]; then
        echo "→ 设置 root 密码..."

        ENCRYPTED_PASS=""
        if command -v mkpasswd &>/dev/null; then
            ENCRYPTED_PASS=$(printf '%s' "$ROOT_PASSWORD" | mkpasswd -m sha-512 -s 2>/dev/null) || true
        fi
        if [[ -z "$ENCRYPTED_PASS" ]] && command -v openssl &>/dev/null; then
            ENCRYPTED_PASS=$(printf '%s' "$ROOT_PASSWORD" | openssl passwd -6 -stdin 2>/dev/null) || true
        fi

        if [[ -n "$ENCRYPTED_PASS" ]]; then
            mkdir -p files/etc
            if [[ -f "package/base-files/files/etc/shadow" ]]; then
                cp package/base-files/files/etc/shadow files/etc/shadow
            else
                cat > files/etc/shadow <<'SHADOW_EOF'
root::0:0:99999:7:::
daemon:*:0:0:99999:7:::
ftp:*:0:0:99999:7:::
network:*:0:0:99999:7:::
nobody:*:0:0:99999:7:::
dnsmasq:*:0:0:99999:7:::
logd:*:0:0:99999:7:::
SHADOW_EOF
            fi
            awk -F: -v hash="$ENCRYPTED_PASS" 'BEGIN{OFS=":"} $1=="root"{$2=hash} {print}' files/etc/shadow > files/etc/shadow.tmp && mv files/etc/shadow.tmp files/etc/shadow
            echo "✓ root 密码设置完成（SHA-512 加密）"
        else
            echo "⚠ 系统缺少 mkpasswd/openssl，密码无法提前加密"
            echo "  固件启动后请手动执行: passwd root"
        fi
    fi

    echo "✓ 系统配置完成"
    exit 0
fi

echo "错误: 无效的阶段: $PHASE"
exit 1