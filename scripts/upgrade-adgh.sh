#!/bin/bash
# AdGuardHome 升级脚本（默认升到 GitHub 最新版，并配套升级 feeds Go 工具链）
#
# 由 build.sh / CI workflow 在 feeds update 之后、feeds install 之前调用。
# “是否升级”的决策在调用方（见下），本脚本只负责“升到指定/最新版本 + 配套升 Go”：
#   24.10  → 调用方【不调用】本脚本，直接使用 feeds 自带的 AdGuardHome
#            （其 Go 1.23 工具链匹配，最稳，无需升级）
#   25.12  → 调用方以默认 latest 调用本脚本，自动升到 GitHub 最新版，
#            并强制把 feeds 的 lang/golang（golang1.26 包）补丁号提到该版本
#            go.mod 要求的 Go，解决 ".built Error 1: requires go >= X.Y.Z" 的编译失败
#
# 用法: upgrade-adgh.sh [openwrt目录] [--version latest|<版本号>]
#   不带 --version 时默认 latest；也兼容 ADGH_VER 环境变量（ADGH_VER=0.107.78 ./script）

set -e

OPENWRT_DIR="."
VERSION_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION_ARG="$2"; shift 2;;
    *) OPENWRT_DIR="$1"; shift;;
  esac
done
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADGH_VER="${VERSION_ARG:-${ADGH_VER:-latest}}"

AGH_MAKEFILE="$OPENWRT_DIR/feeds/packages/net/adguardhome/Makefile"
if [ ! -f "$AGH_MAKEFILE" ]; then
  echo "[SKIP] AdGuardHome Makefile 未找到: $AGH_MAKEFILE"
  exit 0
fi

# 解析 latest
if [ "$ADGH_VER" = "latest" ]; then
  AGH_VER=$(curl -s --connect-timeout 10 https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest \
    | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
  [ -z "$AGH_VER" ] && { echo "[ERROR] 获取最新版本失败（GitHub API 受限？）"; exit 1; }
  echo "[INFO] 解析 latest -> v$AGH_VER"
else
  AGH_VER="$ADGH_VER"
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
