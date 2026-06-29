#!/bin/bash
# OpenClash Meta 核心预装脚本
# 下载最新 mihomo 核心二进制放入 files/，跳过首次启动时的在线下载
#
# 用法: ./scripts/upgrade-openclash-core.sh [项目根目录] [架构]
# 默认架构: linux-amd64 (x86_64)
#
# 仅旁路由和完整路由构建时调用
# 执行时机: diy.sh after 之后、files/ 复制到 openwrt 之前

set -e

PROJECT_ROOT="${1:-.}"
CORE_ARCH="${2:-linux-amd64}"
RELEASE_BRANCH="master"

CORE_DIR="$PROJECT_ROOT/files/etc/openclash/core"
CORE_BIN="$CORE_DIR/clash_meta"

# 获取最新版本号
echo "[CORE] 获取 OpenClash Meta 核心版本..."
CORE_VERSION=$(curl -s --connect-timeout 10 \
    "https://raw.githubusercontent.com/vernesong/OpenClash/core/${RELEASE_BRANCH}/core_version" \
    | sed -n '1p')
if [ -z "$CORE_VERSION" ]; then
    echo "[ERROR] 无法获取核心版本（GitHub 可能不可达）"
    exit 1
fi
echo "  最新版本: $CORE_VERSION"

# 已有核心且版本相同则跳过
if [ -x "$CORE_BIN" ]; then
    CURRENT_V=$("$CORE_BIN" -v 2>/dev/null | awk -F ' ' '{print $3}' | head -1)
    if [ "$CURRENT_V" = "$CORE_VERSION" ]; then
        echo "[SKIP] 核心已是最新版本: $CORE_VERSION"
        exit 0
    fi
fi

# 下载核心二进制
echo "[CORE] 下载 Meta 核心 (clash-${CORE_ARCH})..."
mkdir -p "$CORE_DIR"
TMP_TAR="/tmp/clash-${CORE_ARCH}.tar.gz"

curl -sL --connect-timeout 30 --output "$TMP_TAR" \
    "https://raw.githubusercontent.com/vernesong/OpenClash/core/${RELEASE_BRANCH}/meta/clash-${CORE_ARCH}.tar.gz"

if [ ! -s "$TMP_TAR" ]; then
    echo "[ERROR] 核心二进制下载失败"
    rm -f "$TMP_TAR"
    exit 1
fi

# 解压（tar.gz 内含 clash 二进制）
tar zxf "$TMP_TAR" -C /tmp clash >/dev/null 2>&1 || {
    echo "[ERROR] 核心解压失败"
    rm -f "$TMP_TAR" /tmp/clash
    exit 1
}

mv /tmp/clash "$CORE_BIN"
rm -f "$TMP_TAR"

# 设置权限（与 openclash_core.sh 一致: 4755）
chmod 4755 "$CORE_BIN"

# 验证二进制
CORE_V=$("$CORE_BIN" -v 2>/dev/null | awk -F ' ' '{print $3}' | head -1)
if [ -z "$CORE_V" ]; then
    echo "[WARN] 核心版本验证失败（可能在非 x86_64 平台运行），文件已保存但不保证可用"
else
    echo "[DONE] OpenClash Meta 核心已预装: v${CORE_V} → $CORE_BIN"
fi
