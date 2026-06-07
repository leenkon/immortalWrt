#!/bin/bash
#
# ImmortalWrt 多版本统一 DIY 脚本
# 支持按版本区分 feeds 和配置，自动设置路由 IP
#

set -e

VERSION=""
PHASE=""
PROFILE_TYPE=""  # main (主路由) 或 bypass (旁路由)
CUSTOM_FEEDS=false
CUSTOM_IP=""
PPPOE_USERNAME=""
PPPOE_PASSWORD=""

# 默认 IP 地址
DEFAULT_MAIN_ROUTER_IP="10.10.10.1"
DEFAULT_BYPASS_ROUTER_IP="10.10.10.99"

usage() {
    echo "用法: $0 -v <版本> -p <阶段> [-t <类型>] [--ip <地址>] [--pppoe-user <账号>] [--pppoe-pass <密码>] [--custom-feeds]"
    echo ""
    echo "选项:"
    echo "  -v, --version      版本号 (例如: 24.10, 25.12)"
    echo "  -p, --phase        执行阶段: before (更新 feeds 前) 或 after (更新 feeds 后)"
    echo "  -t, --type         路由类型: main (主路由, IP: $DEFAULT_MAIN_ROUTER_IP) 或 bypass (旁路由, IP: $DEFAULT_BYPASS_ROUTER_IP)"
    echo "  --ip               自定义 IP 地址 (可选，不指定则使用默认)"
    echo "  --pppoe-user       PPPoE 账号 (可选)"
    echo "  --pppoe-pass       PPPoE 密码 (可选)"
    echo "  --custom-feeds     启用自定义 feeds"
    echo "  -h, --help         显示帮助信息"
    echo ""
    echo "示例:"
    echo "  # 主路由编译 - 更新 feeds 后"
    echo "  $0 -v 24.10 -p after -t main"
    echo ""
    echo "  # 旁路由编译 - 更新 feeds 后 (使用默认 IP)"
    echo "  $0 -v 24.10 -p after -t bypass"
    echo ""
    echo "  # 主路由编译 - 使用自定义 IP 和 PPPoE"
    echo "  $0 -v 24.10 -p after -t main --ip 192.168.1.1 --pppoe-user myuser --pppoe-pass mypass"
    echo ""
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--version)
            VERSION="$2"
            shift 2
            ;;
        -p|--phase)
            PHASE="$2"
            shift 2
            ;;
        -t|--type)
            PROFILE_TYPE="$2"
            shift 2
            ;;
        --ip)
            CUSTOM_IP="$2"
            shift 2
            ;;
        --pppoe-user)
            PPPOE_USERNAME="$2"
            shift 2
            ;;
        --pppoe-pass)
            PPPOE_PASSWORD="$2"
            shift 2
            ;;
        --custom-feeds)
            CUSTOM_FEEDS=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "错误: 未知选项 $1"
            usage
            ;;
    esac
done

if [[ -z "$VERSION" || -z "$PHASE" ]]; then
    echo "错误: 必须指定版本号和阶段"
    usage
fi

# 验证路由类型
if [[ "$PHASE" == "after" && -z "$PROFILE_TYPE" ]]; then
    echo "错误: 更新 feeds 后 (-p after) 必须指定路由类型 (-t)"
    usage
fi

# 验证路由类型值
if [[ -n "$PROFILE_TYPE" && "$PROFILE_TYPE" != "main" && "$PROFILE_TYPE" != "bypass" ]]; then
    echo "错误: 无效的路由类型 '$PROFILE_TYPE'，必须是 'main' 或 'bypass'"
    usage
fi

# 验证自定义 IP 格式校验
if [[ -n "$CUSTOM_IP" ]]; then
    if ! [[ $CUSTOM_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "错误: 无效的 IP 地址格式 '$CUSTOM_IP'"
        usage
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

if [[ "$PHASE" == "before" ]]; then
    echo "=== 执行更新 feeds 前的 DIY 操作 (版本: $VERSION) ==="

    FEEDS_CONF="$PROJECT_ROOT/feeds/$VERSION.conf"
    if [[ -f "$FEEDS_CONF" ]]; then
        echo "应用 feeds 配置: $FEEDS_CONF"
        cp "$FEEDS_CONF" feeds.conf.default
    else
        echo "警告: 未找到 $VERSION 版本的 feeds 配置，使用默认"
    fi

    if [[ "$CUSTOM_FEEDS" == true ]]; then
        echo "" >> feeds.conf.default
        echo "# OpenAppFilter - 应用过滤 (需要额外启用)" >> feeds.conf.default
        echo "src-git OpenAppFilter https://github.com/destan19/OpenAppFilter.git" >> feeds.conf.default
        echo "已添加 OpenAppFilter feeds"
    fi

elif [[ "$PHASE" == "after" ]]; then
    echo "=== 执行更新 feeds 后的 DIY 操作 (版本: $VERSION, 类型: $PROFILE_TYPE) ==="

    # 根据路由类型设置 IP 地址
    if [[ "$PROFILE_TYPE" == "main" ]]; then
        if [[ -n "$CUSTOM_IP" ]]; then
            ROUTER_IP="$CUSTOM_IP"
        else
            ROUTER_IP="$DEFAULT_MAIN_ROUTER_IP"
        fi
        HOSTNAME="Router-Main"
    elif [[ "$PROFILE_TYPE" == "bypass" ]]; then
        if [[ -n "$CUSTOM_IP" ]]; then
            ROUTER_IP="$CUSTOM_IP"
        else
            ROUTER_IP="$DEFAULT_BYPASS_ROUTER_IP"
        fi
        HOSTNAME="Router-Bypass"
    fi

    echo "路由类型: $PROFILE_TYPE"
    if [[ -n "$CUSTOM_IP" ]]; then
        echo "设置 IP 地址: $ROUTER_IP (自定义)"
    else
        echo "设置 IP 地址: $ROUTER_IP (默认)"
    fi
    echo "设置主机名: $HOSTNAME"
    if [[ -n "$PPPOE_USERNAME" ]]; then
        echo "设置 PPPoE 账号: $PPPOE_USERNAME"
        echo "设置 PPPoE 密码: 已设置"
    fi

    CONFIG_FILE="package/base-files/files/bin/config_generate"

    if [[ -f "$CONFIG_FILE" ]]; then
        # 修改默认 IP 地址
        sed -i "s/192.168.1.1/$ROUTER_IP/g" "$CONFIG_FILE"

        # 修改主机名
        sed -i "s/ImmortalWrt/$HOSTNAME/g" "$CONFIG_FILE"

        # 修改时区为中国时区
        sed -i "s/GMT0/CST-8/g" "$CONFIG_FILE"
        sed -i "s/UTC/Asia\/Shanghai/g" "$CONFIG_FILE"

        echo "IP 地址、主机名和时区已更新"
    else
        echo "警告: 未找到配置文件 $CONFIG_FILE，跳过修改"
    fi

    # 设置 PPPoE 配置
    if [[ -n "$PPPOE_USERNAME" ]]; then
        NETWORK_CONFIG="package/base-files/files/etc/config/network"
        if [[ -f "$NETWORK_CONFIG" ]]; then
            # 移除现有的 PPPoE 配置
            sed -i '/config interface.*wan/,/^$/d' "$NETWORK_CONFIG"
            
            # 添加新的 PPPoE 配置
            cat >> "$NETWORK_CONFIG" <<EOF

config interface 'wan'
        option proto 'pppoe'
        option username '$PPPOE_USERNAME'
        option password '$PPPOE_PASSWORD'
        option device '@wan'
        option ipv6 'auto'
EOF
            echo "PPPoE 配置已更新"
        else
            echo "警告: 未找到网络配置文件 $NETWORK_CONFIG"
        fi
    fi

    # 旁路由配置：禁用 PPPoE 和 DHCP（可选，根据需要启用）
    if [[ "$PROFILE_TYPE" == "bypass" ]]; then
        echo ""
        echo "提示: 旁路由配置建议："
        echo "  - 关闭 DHCP 服务器"
        if [[ -n "$CUSTOM_IP" ]]; then
            echo "  - 网关指向主路由 (根据您的网络配置)"
        else
            echo "  - 网关指向主路由 ($DEFAULT_MAIN_ROUTER_IP)"
        fi
        echo "  - DNS 指向主路由或公共 DNS"
    fi

else
    echo "错误: 无效的阶段 '$PHASE'，必须是 'before' 或 'after'"
    exit 1
fi

echo "=== DIY 操作完成 ==="
