#!/bin/bash

VERSION=""
PHASE=""
PROFILE_TYPE=""
CUSTOM_FEEDS=false
CUSTOM_IP=""
PPPOE_USERNAME=""
PPPOE_PASSWORD=""

DEFAULT_MAIN_ROUTER_IP="10.10.10.1"
DEFAULT_BYPASS_ROUTER_IP="10.10.10.99"

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--version) VERSION="$2"; shift 2 ;;
        -p|--phase) PHASE="$2"; shift 2 ;;
        -t|--type) PROFILE_TYPE="$2"; shift 2 ;;
        --ip) CUSTOM_IP="$2"; shift 2 ;;
        --pppoe-user) PPPOE_USERNAME="$2"; shift 2 ;;
        --pppoe-pass) PPPOE_PASSWORD="$2"; shift 2 ;;
        --custom-feeds) CUSTOM_FEEDS=true; shift ;;
        *) echo "未知选项: $1"; exit 1 ;;
    esac
done

[[ -z "$VERSION" || -z "$PHASE" ]] && { echo "错误: 必须指定版本和阶段"; exit 1; }
[[ "$PHASE" == "after" && -z "$PROFILE_TYPE" ]] && { echo "错误: after 阶段必须指定路由类型"; exit 1; }
[[ -n "$PROFILE_TYPE" && "$PROFILE_TYPE" != "main" && "$PROFILE_TYPE" != "bypass" ]] && { echo "错误: 路由类型必须是 main 或 bypass"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

if [[ "$PHASE" == "before" ]]; then
    FEEDS_CONF="$PROJECT_ROOT/feeds/$VERSION.conf"
    if [[ -f "$FEEDS_CONF" ]]; then
        cp "$FEEDS_CONF" feeds.conf.default
    else
        # 如果没有 feeds 配置，确保至少有一个空文件
        touch feeds.conf.default
    fi
    if [[ "$CUSTOM_FEEDS" == true ]]; then
        echo "" >> feeds.conf.default
        echo "src-git OpenAppFilter https://github.com/destan19/OpenAppFilter.git" >> feeds.conf.default
    fi
elif [[ "$PHASE" == "after" ]]; then
    if [[ "$PROFILE_TYPE" == "main" ]]; then
        ROUTER_IP="${CUSTOM_IP:-$DEFAULT_MAIN_ROUTER_IP}"
        HOSTNAME="Router-Main"
    else
        ROUTER_IP="${CUSTOM_IP:-$DEFAULT_BYPASS_ROUTER_IP}"
        HOSTNAME="Router-Bypass"
    fi
    echo "配置: $PROFILE_TYPE | IP: $ROUTER_IP"
    
    if [[ "$PROFILE_TYPE" == "main" && "$CUSTOM_FEEDS" == true ]]; then
        if [[ -f ".config" ]]; then
            sed -i '/CONFIG_PACKAGE_kmod-oaf/d' .config
            echo 'CONFIG_PACKAGE_open-app-filter=y' >> .config
            echo 'CONFIG_PACKAGE_luci-app-oaf=y' >> .config
            echo 'CONFIG_PACKAGE_kmod-oaf=n' >> .config
        fi
    fi
    CONFIG_FILE="package/base-files/files/bin/config_generate"
    if [[ -f "$CONFIG_FILE" ]]; then
        sed -i "s/set network.lan.ipaddr='192.168.1.1'/set network.lan.ipaddr='$ROUTER_IP'/g" "$CONFIG_FILE"
        sed -i "s/set system.@system\[0\].hostname='ImmortalWrt'/set system.@system[0].hostname='$HOSTNAME'/g" "$CONFIG_FILE"
        sed -i "s/set system.@system\[0\].timezone='GMT0'/set system.@system[0].timezone='CST-8'/g" "$CONFIG_FILE"
        sed -i "s/set system.@system\[0\].zonename='UTC'/set system.@system[0].zonename='Asia\/Shanghai'/g" "$CONFIG_FILE"
    fi
    mkdir -p files/etc/uci-defaults
    BOOT_SCRIPT="files/etc/uci-defaults/99-custom-config"
    cat > "$BOOT_SCRIPT" <<EOF
#!/bin/sh
uci set network.lan.ipaddr='$ROUTER_IP'
uci set system.@system[0].hostname='$HOSTNAME'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci set luci.main.mediaurlbase='/luci-static/argon'
uci commit luci
EOF
    if [[ "$PROFILE_TYPE" == "main" ]]; then
        if [[ -n "$PPPOE_USERNAME" && -n "$PPPOE_PASSWORD" ]]; then
            ESCAPED_USER=$(printf '%s\n' "$PPPOE_USERNAME" | sed 's/[\/&]/\\&/g')
            ESCAPED_PASS=$(printf '%s\n' "$PPPOE_PASSWORD" | sed 's/[\/&]/\\&/g')
            cat >> "$BOOT_SCRIPT" <<EOF
uci set network.wan.proto='pppoe'
uci set network.wan.username='$ESCAPED_USER'
uci set network.wan.password='$ESCAPED_PASS'
uci set network.wan.ipv6='auto'
EOF
        else
            cat >> "$BOOT_SCRIPT" <<EOF
uci set network.wan.proto='dhcp'
uci set network.wan6.proto='dhcpv6'
EOF
        fi
    else
        cat >> "$BOOT_SCRIPT" <<EOF
uci set dhcp.lan.ignore='1'
uci delete dhcp.lan.start 2>/dev/null
uci delete dhcp.lan.limit 2>/dev/null
uci delete dhcp.lan.leasetime 2>/dev/null
EOF
    fi
    cat >> "$BOOT_SCRIPT" <<EOF
uci commit network
uci commit system
uci commit dhcp
EOF
    chmod +x "$BOOT_SCRIPT"
fi