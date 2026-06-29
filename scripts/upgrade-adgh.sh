#!/bin/bash
# AdGuardHome 版本升级脚本
# 自动获取官方最新版本，patch feeds Makefile 以使用最新源码编译
#
# 用法: ./scripts/upgrade-adgh.sh [openwrt源码目录]
# 默认目录: . (当前目录)
#
# 执行时机: feeds update -a 之后、feeds install -a 之前
# 原理: 修改 feeds/packages/net/adguardhome/Makefile 中的
#        PKG_VERSION / PKG_HASH / FRONTEND_HASH

set -e

OPENWRT_DIR="${1:-.}"
AGH_MAKEFILE="$OPENWRT_DIR/feeds/packages/net/adguardhome/Makefile"

if [ ! -f "$AGH_MAKEFILE" ]; then
    echo "[SKIP] AdGuardHome Makefile 未找到: $AGH_MAKEFILE"
    exit 0
fi

# 当前 feeds 版本
CURRENT_VER=$(sed -n 's/^PKG_VERSION:=//p' "$AGH_MAKEFILE")

# 获取官方最新版本（GitHub API），失败则回退到硬编码版本
AGH_VER=$(curl -s --connect-timeout 10 https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest \
    | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
[ -z "$AGH_VER" ] && AGH_VER="0.107.77"

if [ "$CURRENT_VER" = "$AGH_VER" ]; then
    echo "[SKIP] AdGuardHome 已是最新版本: v$AGH_VER"
    exit 0
fi

echo "[UPGRADE] AdGuardHome: v$CURRENT_VER -> v$AGH_VER"

# 下载源码 tarball 并计算 SHA256
echo "  下载源码..."
AGH_SRC_HASH=$(curl -sL --connect-timeout 30 \
    "https://codeload.github.com/AdguardTeam/AdGuardHome/tar.gz/v${AGH_VER}" \
    | sha256sum | cut -d' ' -f1)
if [ -z "$AGH_SRC_HASH" ] || [ ${#AGH_SRC_HASH} -ne 64 ]; then
    echo "[ERROR] 源码下载或 hash 计算失败"
    exit 1
fi
echo "  源码 SHA256: $AGH_SRC_HASH"

# 下载前端 tarball 并计算 SHA256
echo "  下载前端..."
AGH_FE_HASH=$(curl -sL --connect-timeout 30 \
    "https://github.com/AdguardTeam/AdGuardHome/releases/download/v${AGH_VER}/AdGuardHome_frontend.tar.gz" \
    | sha256sum | cut -d' ' -f1)
if [ -z "$AGH_FE_HASH" ] || [ ${#AGH_FE_HASH} -ne 64 ]; then
    echo "[ERROR] 前端下载或 hash 计算失败"
    exit 1
fi
echo "  前端 SHA256: $AGH_FE_HASH"

# Patch Makefile
sed -i "s/^PKG_VERSION:=.*/PKG_VERSION:=$AGH_VER/" "$AGH_MAKEFILE"
sed -i "s/^PKG_HASH:=.*/PKG_HASH:=$AGH_SRC_HASH/" "$AGH_MAKEFILE"
sed -i "s/^FRONTEND_HASH:=.*/FRONTEND_HASH:=$AGH_FE_HASH/" "$AGH_MAKEFILE"
sed -i "s/^PKG_RELEASE:=.*/PKG_RELEASE:=1/" "$AGH_MAKEFILE"
# FRONTEND_PKG_VERSION 通常等于 PKG_VERSION，若 Makefile 中存在则一并更新
sed -i "s/^FRONTEND_PKG_VERSION:=.*/FRONTEND_PKG_VERSION:=$AGH_VER/" "$AGH_MAKEFILE"

echo "[DONE] AdGuardHome Makefile 已升级到 v$AGH_VER"
