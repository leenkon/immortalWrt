#!/bin/bash
# 强制升级 feeds 的 lang/golang 到目标 Go 版本
#
# 背景：OpenWrt 25.12 的 feeds 自带 Go 1.26.4（包 golang1.26），而最新 AdGuardHome
#       的 go.mod 要求 go >= 1.26.5，直接编译会在 .built 阶段报
#       "requires go >= 1.26.5 (running go 1.26.4; GOTOOLCHAIN=local)" 而失败。
#       本脚本把匹配大版本的 golang<maj>.<min> 包补丁号提到目标版本并重算 PKG_HASH，
#       使依赖 golang/host 的包（如 AdGuardHome）自动用上新 Go。
#
# 结构适配：
#   25.12+  按大版本拆分（golang1.26 等），默认 golang 虚包 -> golang<ver>/host
#   24.10   单一 golang 包（1.23.x），bootstrap 链(go1.4/1.17/1.20)过旧无法
#           bootstrap Go 1.26 -> 不支持，明确 ABORT 并提示改用 25.12
#
# 用法: upgrade-golang.sh <openwrt_dir> --require-go <X.Y.Z | X.Y>
#   X.Y.Z  精确目标（如 1.26.5）
#   X.Y    仅大版本，自动取该 minor 最新补丁
#
# 执行时机: feeds update -a 之后（Makefile 已存在）
set -e

OPENWRT_DIR="${1:-.}"
shift || true

REQ_GO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --require-go) REQ_GO="$2"; shift 2;;
    *) shift;;
  esac
done

[ -z "$REQ_GO" ] && { echo "[GOLANG][ERROR] 缺少 --require-go"; exit 1; }

# ---- 解析目标版本 ----
REQ_MAJ=$(echo "$REQ_GO" | cut -d. -f1)
REQ_MIN=$(echo "$REQ_GO" | cut -d. -f2)
REQ_PAT=$(echo "$REQ_GO" | cut -d. -f3)
if [ -z "$REQ_PAT" ]; then
  echo "[GOLANG] 目标仅大版本 ${REQ_MAJ}.${REQ_MIN}，查询最新补丁..."
  REQ_PAT=$(curl -sL --connect-timeout 15 "https://go.dev/dl/?mode=json" \
    | grep -oE "\"version\": \"go${REQ_MAJ}\.${REQ_MIN}\.[0-9]+\"" \
    | grep -oE "${REQ_MAJ}\.${REQ_MIN}\.[0-9]+" | sort -V | tail -1)
  [ -z "$REQ_PAT" ] && { echo "[GOLANG][ERROR] 无法确定 go${REQ_MAJ}.${REQ_MIN} 最新补丁"; exit 1; }
  REQ_GO="${REQ_MAJ}.${REQ_MIN}.${REQ_PAT}"
fi
echo "[GOLANG] 目标 Go 版本: $REQ_GO"

# ---- 定位 feeds golang 包 ----
GOLANG_DIR="$OPENWRT_DIR/feeds/packages/lang/golang"
TARGET_MK=""
PKG_KIND=""
if [ -f "$GOLANG_DIR/golang${REQ_MAJ}.${REQ_MIN}/Makefile" ]; then
  TARGET_MK="$GOLANG_DIR/golang${REQ_MAJ}.${REQ_MIN}/Makefile"
  PKG_KIND="split"
elif [ -f "$GOLANG_DIR/golang/Makefile" ]; then
  MK_MAJMIN=$(sed -n 's/^GO_VERSION_MAJOR_MINOR:=//p' "$GOLANG_DIR/golang/Makefile" | head -1)
  if [ "$MK_MAJMIN" = "${REQ_MAJ}.${REQ_MIN}" ]; then
    TARGET_MK="$GOLANG_DIR/golang/Makefile"
    PKG_KIND="single"
  else
    echo "[GOLANG][ABORT] feeds 的 lang/golang 仅有 Go $MK_MAJMIN，无法提供 ${REQ_MAJ}.${REQ_MIN}。"
    echo "        24.10 的 bootstrap 链(go1.4/1.17/1.20)过旧，无法 bootstrap Go ${REQ_MAJ}.${REQ_MIN}。"
    echo "        请改用 25.12 基线编译需要 Go >= ${REQ_MAJ}.${REQ_MIN} 的包；"
    echo "        或在 24.10 手动加入 golang${REQ_MAJ}.${REQ_MIN} 包后重试。"
    exit 1
  fi
else
  echo "[GOLANG][ABORT] 未找到 feeds 的 lang/golang 包（feeds update -a 是否已执行？）"
  exit 1
fi
echo "[GOLANG] 命中 golang 包: $TARGET_MK ($PKG_KIND)"

# ---- 当前版本 ----
CUR_MAJMIN=$(sed -n 's/^GO_VERSION_MAJOR_MINOR:=//p' "$TARGET_MK" | head -1)
CUR_PAT=$(sed -n 's/^GO_VERSION_PATCH:=//p' "$TARGET_MK" | head -1)
CUR_GO="${CUR_MAJMIN}.${CUR_PAT}"
echo "[GOLANG] 当前 feeds Go: $CUR_GO"

ver_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]; }

if ver_ge "$CUR_GO" "$REQ_GO"; then
  echo "[GOLANG][SKIP] feeds Go $CUR_GO 已 >= $REQ_GO，无需升级"
  exit 0
fi

# ---- 下载并计算 SHA256（同时校验为真实 gzip，排除 404 HTML） ----
download_go_hash() {
  local url="$1" tmp
  tmp=$(mktemp)
  if ! curl -sL --connect-timeout 30 -o "$tmp" "$url"; then
    echo "[GOLANG][ERROR] 下载 Go 源码失败: $url"; rm -f "$tmp"; return 1
  fi
  local magic; magic=$(head -c2 "$tmp" | od -An -tx1 | tr -d ' \n')
  if [ "$magic" != "1f8b" ]; then
    echo "[GOLANG][ERROR] 下载内容非 gzip（可能 404）: $url"; rm -f "$tmp"; return 1
  fi
  sha256sum "$tmp" | cut -d' ' -f1
  rm -f "$tmp"
}

GO_SRC_URL="https://go.dev/dl/go${REQ_GO}.src.tar.gz"
echo "[GOLANG] 下载 Go 源码 $GO_SRC_URL ..."
GO_HASH=$(download_go_hash "$GO_SRC_URL") || exit 1
[ ${#GO_HASH} -ne 64 ] && { echo "[GOLANG][ERROR] Go hash 异常"; exit 1; }
echo "[GOLANG] Go 源码 SHA256: $GO_HASH"

# ---- 打补丁：仅改补丁号与源码哈希，包名(大版本)不变，依赖链自动跟随 ----
sed -i "s/^GO_VERSION_PATCH:=.*/GO_VERSION_PATCH:=$REQ_PAT/" "$TARGET_MK"
sed -i "s/^PKG_HASH:=.*/PKG_HASH:=$GO_HASH/" "$TARGET_MK"

echo "[GOLANG][DONE] feeds golang 已升级: $CUR_GO -> $REQ_GO"
