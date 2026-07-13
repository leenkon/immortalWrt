#!/bin/bash
# AdGuardHome 版本升级脚本
# 默认行为：不覆盖 feeds 自带版本（与 feed Go 工具链匹配，可稳定编译）。
# 仅当显式设置 ADGH_VER 时才升级：
#   ADGH_VER=0.107.78        升级到指定版本
#   ADGH_VER=latest          升级到 GitHub 最新版
# 升级时会读取目标版本 go.mod 要求的 Go 版本，并强制把 feeds 的 lang/golang
# 升级到该版本（25.12 的 golang1.26 包提升补丁号），以解决
# "requires go >= X.Y.Z (running go ...)" 的 .built 失败。
# 24.10 因 bootstrap 链过旧无法升级到 Go 1.26+，会明确 ABORT 并提示改用 25.12。
#
# 执行时机: feeds update -a 之后、feeds install -a 之前
# 用法: ADGH_VER=xxx ./scripts/upgrade-adgh.sh [openwrt源码目录]
# 默认目录: .

set -e

OPENWRT_DIR="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGH_MAKEFILE="$OPENWRT_DIR/feeds/packages/net/adguardhome/Makefile"

if [ ! -f "$AGH_MAKEFILE" ]; then
    echo "[SKIP] AdGuardHome Makefile 未找到: $AGH_MAKEFILE"
    exit 0
fi

# 默认不升级：使用 feeds 自带版本（与 feed Go 匹配，最稳）
if [ -z "$ADGH_VER" ]; then
    CURRENT_VER=$(sed -n 's/^PKG_VERSION:=//p' "$AGH_MAKEFILE")
    echo "[SKIP] 未设置 ADGH_VER，使用 feeds 自带版本 v$CURRENT_VER（已与 feed Go 匹配，避免编译失败）"
    exit 0
fi

# 解析 latest
if [ "$ADGH_VER" = "latest" ]; then
    AGH_VER=$(curl -s --connect-timeout 10 https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest \
        | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
    [ -z "$AGH_VER" ] && { echo "[ERROR] 获取最新版本失败（GitHub API 受限？）"; exit 1; }
    echo "[INFO] 解析 latest -> v$AGH_VER"
fi

CURRENT_VER=$(sed -n 's/^PKG_VERSION:=//p' "$AGH_MAKEFILE")
if [ "$CURRENT_VER" = "$AGH_VER" ]; then
    echo "[SKIP] 已是最新版本: v$AGH_VER"
    exit 0
fi

# 读取目标版本 go.mod 要求的 Go 版本，强制升级 feeds golang 以满足
req_go=$(curl -sL --connect-timeout 15 "https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/v${AGH_VER}/go.mod" 2>/dev/null \
    | grep -E '^go ' | head -1 | awk '{print $2}')
if [ -n "$req_go" ]; then
    echo "[INFO] v$AGH_VER 要求 Go >= $req_go，强制升级 feeds golang 以满足"
else
    # go.mod 取不到时，退化为“强制升级 feeds 当前大版本的最新补丁”
    req_go=$(sed -n 's/^GO_DEFAULT_VERSION:=//p' "$OPENWRT_DIR/feeds/packages/lang/golang/golang-values.mk" 2>/dev/null | head -1)
    req_go="${req_go:-1.26}"
    echo "[WARN] 无法获取 v$AGH_VER 的 go.mod，退化为强制升级 feeds golang 至 ${req_go} 最新补丁"
fi
"$SCRIPT_DIR/upgrade-golang.sh" "$OPENWRT_DIR" --require-go "$req_go" || {
    echo "[ABORT] 升级 feeds golang 失败，无法用 feed 工具链编译 v$AGH_VER"; exit 1;
}

echo "[UPGRADE] AdGuardHome: v$CURRENT_VER -> v$AGH_VER"

# 下载并计算 SHA256，同时校验内容为真实 gzip（排除 GitHub 的 404 HTML 页面）
download_hash() {
    local url="$1" tmp
    tmp=$(mktemp)
    if ! curl -sL --connect-timeout 30 -o "$tmp" "$url"; then
        echo "[ERROR] 下载失败: $url"
        rm -f "$tmp"
        return 1
    fi
    local magic; magic=$(head -c2 "$tmp" | od -An -tx1 | tr -d ' \n')
    if [ "$magic" != "1f8b" ]; then
        echo "[ERROR] 下载内容非 gzip（可能 404/HTML）: $url"
        rm -f "$tmp"
        return 1
    fi
    sha256sum "$tmp" | cut -d' ' -f1
    rm -f "$tmp"
}

echo "  下载源码..."
AGH_SRC_HASH=$(download_hash "https://codeload.github.com/AdguardTeam/AdGuardHome/tar.gz/v${AGH_VER}") || exit 1
[ ${#AGH_SRC_HASH} -ne 64 ] && { echo "[ERROR] 源码 hash 异常"; exit 1; }
echo "  源码 SHA256: $AGH_SRC_HASH"

echo "  下载前端..."
AGH_FE_HASH=$(download_hash "https://github.com/AdguardTeam/AdGuardHome/releases/download/v${AGH_VER}/AdGuardHome_frontend.tar.gz") || exit 1
[ ${#AGH_FE_HASH} -ne 64 ] && { echo "[ERROR] 前端 hash 异常"; exit 1; }
echo "  前端 SHA256: $AGH_FE_HASH"

# Patch Makefile
sed -i "s/^PKG_VERSION:=.*/PKG_VERSION:=$AGH_VER/" "$AGH_MAKEFILE"
sed -i "s/^PKG_HASH:=.*/PKG_HASH:=$AGH_SRC_HASH/" "$AGH_MAKEFILE"
sed -i "s/^FRONTEND_HASH:=.*/FRONTEND_HASH:=$AGH_FE_HASH/" "$AGH_MAKEFILE"
sed -i "s/^PKG_RELEASE:=.*/PKG_RELEASE:=1/" "$AGH_MAKEFILE"
sed -i "s/^FRONTEND_PKG_VERSION:=.*/FRONTEND_PKG_VERSION:=$AGH_VER/" "$AGH_MAKEFILE"

echo "[DONE] AdGuardHome Makefile 已升级到 v$AGH_VER"
