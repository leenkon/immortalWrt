#!/bin/bash

VERSION=""
PHASE=""
PROFILE_TYPE=""
INSTALL_OAF=false
CUSTOM_IP=""
PPPOE_USERNAME=""
PPPOE_PASSWORD=""

DEFAULT_MAIN_ROUTER_IP="10.10.10.1"
DEFAULT_BYPASS_ROUTER_IP="10.10.10.99"

remove_immortalwrt_oaf() {
    echo "→ 删除 ImmortalWrt 自带的 OAF..."
    rm -rf package/feeds/packages/oaf 2>/dev/null
    rm -rf package/feeds/packages/luci-app-oaf 2>/dev/null
    rm -rf package/feeds/packages/open-app-filter 2>/dev/null
    rm -rf feeds/packages/net/oaf 2>/dev/null
    rm -rf feeds/packages/net/open-app-filter 2>/dev/null
    echo "✓ OAF 清理完成"
}

install_official_oaf() {
    echo "→ 安装官方 OpenAppFilter..."
    if git clone https://github.com/destan19/OpenAppFilter.git package/OpenAppFilter 2>/dev/null; then
        echo "CONFIG_PACKAGE_luci-app-oaf=y" >> .config
        echo "✓ 官方 OAF 安装完成"
    else
        echo "✗ OAF 安装失败"
    fi
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--version) VERSION="$2"; shift 2 ;;
        -p|--phase) PHASE="$2"; shift 2 ;;
        -t|--type) PROFILE_TYPE="$2"; shift 2 ;;
        --ip) CUSTOM_IP="$2"; shift 2 ;;
        --pppoe-user) PPPOE_USERNAME="$2"; shift 2 ;;
        --pppoe-pass) PPPOE_PASSWORD="$2"; shift 2 ;;
        --install-oaf) INSTALL_OAF=true; shift ;;
        --custom-feeds) INSTALL_OAF=true; shift ;;
        *) echo "错误: 未知选项 $1"; exit 1 ;;
    esac
done

# 参数验证
if [[ -z "$VERSION" || -z "$PHASE" ]]; then
    echo "错误: 必须指定版本 (-v) 和阶段 (-p)"
    exit 1
fi

if [[ "$PHASE" == "after" && -z "$PROFILE_TYPE" ]]; then
    echo "错误: after 阶段必须指定路由类型 (-t)"
    exit 1
fi

if [[ "$PHASE" == "oaf" && -z "$PROFILE_TYPE" ]]; then
    echo "错误: oaf 阶段必须指定路由类型 (-t)"
    exit 1
fi

if [[ -n "$PROFILE_TYPE" && "$PROFILE_TYPE" != "main" && "$PROFILE_TYPE" != "bypass" ]]; then
    echo "错误: 路由类型必须是 main 或 bypass"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

case "$PHASE" in
    before)
        echo "=== 应用 Feeds 配置 ==="
        FEEDS_CONF="$PROJECT_ROOT/feeds/$VERSION.conf"
        if [[ -f "$FEEDS_CONF" ]]; then
            cp "$FEEDS_CONF" feeds.conf.default
            echo "✓ 已应用 feeds 配置: $VERSION.conf"
        else
            touch feeds.conf.default
            echo "✓ 使用默认 feeds 配置"
        fi
        ;;
        
    oaf)
        echo "=== 处理 OAF ==="
        remove_immortalwrt_oaf
        
        if [[ "$INSTALL_OAF" == true ]]; then
            if [[ "$PROFILE_TYPE" == "bypass" ]]; then
                echo "⚠️  旁路由安装 OAF 可能与流量转发软件产生冲突，请谨慎使用"
            fi
            install_official_oaf
        else
            echo "→ 跳过 OAF 安装"
        fi
        ;;
        
    after)
        echo "=== 配置系统 ==="
        if [[ "$PROFILE_TYPE" == "main" ]]; then
            ROUTER_IP="${CUSTOM_IP:-$DEFAULT_MAIN_ROUTER_IP}"
            HOSTNAME="Router-Main"
        else
            ROUTER_IP="${CUSTOM_IP:-$DEFAULT_BYPASS_ROUTER_IP}"
            HOSTNAME="Router-Bypass"
        fi
        echo "配置: $PROFILE_TYPE | IP: $ROUTER_IP"
        
        # 修改默认配置
        CONFIG_FILE="package/base-files/files/bin/config_generate"
        if [[ -f "$CONFIG_FILE" ]]; then
            sed -i "s/set network.lan.ipaddr='192.168.1.1'/set network.lan.ipaddr='$ROUTER_IP'/g" "$CONFIG_FILE"
            sed -i "s/set system.@system\[0\].hostname='ImmortalWrt'/set system.@system[0].hostname='$HOSTNAME'/g" "$CONFIG_FILE"
            sed -i "s/set system.@system\[0\].timezone='GMT0'/set system.@system[0].timezone='CST-8'/g" "$CONFIG_FILE"
            sed -i "s/set system.@system\[0\].zonename='UTC'/set system.@system[0].zonename='Asia\/Shanghai'/g" "$CONFIG_FILE"
        fi
        
        # 创建 UCI 默认配置脚本
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
        echo "✓ 系统配置完成"
        ;;
        
    *)
        echo "错误: 无效的阶段: $PHASE"
        exit 1
        ;;
esac

echo
echo "✓ 阶段 $PHASE 执行完成"
