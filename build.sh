#!/bin/bash
# ImmortalWrt 本地编译脚本 - Debian/Ubuntu
# 用法: chmod +x build.sh && ./build.sh

set -e

# 颜色定义
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
error_exit() { echo -e "${RED}错误：$1${NC}" >&2; exit 1; }
success() { echo -e "${GREEN}[OK] $1${NC}"; }

# 默认配置
DEF_MAIN_IP="10.10.10.1"
DEF_BYPASS_IP="10.10.10.2"
DEF_GATEWAY="10.10.10.1"
ROOT_PASSWORD="password"

# 修复换行符
fix_line_endings() { for f in "$@"; do [[ -f "$f" ]] && grep -q $'\r' "$f" 2>/dev/null && sed -i 's/\r$//' "$f"; done || true; }

# 交互式输入
echo "========================================"
echo "   ImmortalWrt x86_64 本地编译脚本"
echo "========================================"

# 版本选择
echo -e "\n请选择 ImmortalWrt 版本："
echo "  1) 25.12.0  2) 25.12.1"
read -p "请输入选择 [1-2，默认 1]: " v
v=${v:-1}
case "$v" in 1) VERSION="25.12.0";; 2) VERSION="25.12.1";; *) error_exit "无效选择";; esac
success "版本: $VERSION"

# 配置选择
echo -e "\n请选择编译配置："
echo "  1) default-main (主路由)  2) mini-bypass (旁路由)  3) full-main (完整路由)  4) full-noadgh (完整路由无ADGH)"
read -p "请输入选择 [1-4，默认 1]: " p
p=${p:-1}
case "$p" in 1) PROFILE="default-main";; 2) PROFILE="mini-bypass";; 3) PROFILE="full-main";; 4) PROFILE="full-noadgh";; *) error_exit "无效选择";; esac
success "配置: $PROFILE"

# 解析配置
IFS='-' read -r CFG_PREFIX RUN_TYPE <<< "$PROFILE"
# full-main / full-noadgh 的 RUN_TYPE 都需要覆盖为 full（diy.sh 需要）
[[ "$CFG_PREFIX" == "full" ]] && RUN_TYPE="full"
NO_ADGH="false"
[[ "$PROFILE" == "full-noadgh" ]] && NO_ADGH="true"
MAIN_VER=${VERSION%.*}

# 自定义IP
echo -e "\n[LAN IP]"
[[ "$RUN_TYPE" == "bypass" ]] && DEF_IP="$DEF_BYPASS_IP" || DEF_IP="$DEF_MAIN_IP"
read -p "自定义LAN IP [默认: $DEF_IP，回车跳过]: " custom_ip
ROUTER_IP="${custom_ip:-$DEF_IP}"
success "LAN IP: $ROUTER_IP"

# 网关(仅旁路由)
GATEWAY_IP=""
[[ "$RUN_TYPE" == "bypass" ]] && { read -p "网关IP [默认: $DEF_GATEWAY]: " gw; GATEWAY_IP="${gw:-$DEF_GATEWAY}"; success "网关: $GATEWAY_IP"; }

# PPPoE (主路由/完整路由)
PPPOE_USER="" PPPOE_PASS=""
[[ "$RUN_TYPE" == "main" || "$RUN_TYPE" == "full" ]] && { read -p "配置PPPoE? [y/N]: " pp; [[ "$pp" =~ ^[Yy]$ ]] && { read -p "用户名: " PPPOE_USER; read -p "密码: " PPPOE_PASS; success "PPPoE已配置"; } || success "使用DHCP"; }

# OAF (主路由可选，完整路由始终安装)
USE_OAF="false"
if [[ "$RUN_TYPE" == "full" ]]; then
    USE_OAF="true"
    success "完整路由: OAF 始终安装"
elif [[ "$RUN_TYPE" == "main" ]]; then
    read -p "安装OAF? [y/N]: " oaf; [[ "$oaf" =~ ^[Yy]$ ]] && USE_OAF="true" && success "将安装OAF"
fi

# 旁路 IP (仅主路由，用于 DNS 劫持排除规则和 DHCP DNS 选项)
BYPASS_IP=""
if [[ "$RUN_TYPE" == "main" ]]; then
    read -p "旁路路由IP [默认: $DEF_BYPASS_IP，回车跳过]: " bip
    BYPASS_IP="${bip:-$DEF_BYPASS_IP}"
    success "旁路IP: $BYPASS_IP"
fi

# Root密码
read -p "Root密码 [默认: password]: " rp
ROOT_PWD="${rp:-$ROOT_PASSWORD}"
success "密码已设置"

# 确认
echo -e "\n========================================  准备编译  ========================================"
echo "  版本: $VERSION | 配置: $PROFILE | IP: $ROUTER_IP | 类型: $RUN_TYPE"
[[ -n "$GATEWAY_IP" ]] && echo "  网关: $GATEWAY_IP"
[[ -n "$PPPOE_USER" ]] && echo "  PPPoE: $PPPOE_USER"
[[ "$USE_OAF" == "true" ]] && echo "  OAF: 是"
[[ -n "$BYPASS_IP" ]] && echo "  旁路IP: $BYPASS_IP"
echo "==================================================================================="
read -p "确认开始? [Y/n]: " c; [[ "$c" =~ ^[Nn]$ ]] && exit 0

# ========== 编译 ==========
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENWRT_DIR="$SCRIPT_DIR/openwrt"
DIY="$SCRIPT_DIR/scripts/diy.sh"

# 1. 换行符
echo -e "\n${YELLOW}[1/7] 检查换行符和权限...${NC}"
fix_line_endings "$DIY" "$SCRIPT_DIR/build.sh" "$SCRIPT_DIR/scripts/upgrade-adgh-binary.sh" "$SCRIPT_DIR/scripts/upgrade-openclash-core.sh" "$SCRIPT_DIR/scripts/upgrade-openclash-luci.sh"
# files/ 下的脚本和 YAML 也需要修复 CRLF（路由器 ash 不兼容 CRLF）
fix_line_endings "$SCRIPT_DIR/files/usr/sbin/dns-hijack" \
  "$SCRIPT_DIR/files/usr/lib/ddns/update_aliyun_com.sh" \
  "$SCRIPT_DIR/files/etc/adguardhome/adguardhome.yaml" \
  "$SCRIPT_DIR/files/etc/openclash/custom/openclash_custom_overwrite.yaml" \
  "$SCRIPT_DIR/files/etc/hotplug.d/iface/99-adgh-filters"
chmod +x "$DIY" "$SCRIPT_DIR/build.sh"
success "完成"

# 2. 依赖
echo -e "\n${YELLOW}[2/7] 安装依赖...${NC}"
sudo apt update -y
sudo apt install -y ack antlr3 asciidoc autoconf automake autopoint binutils bison build-essential \
bzip2 ccache clang cmake cpio curl device-tree-compiler ecj fastjar flex gawk gettext gcc-multilib \
g++-multilib git gnutls-dev gperf haveged help2man intltool lib32gcc-s1 libc6-dev-i386 libelf-dev \
libglib2.0-dev libgmp-dev libltdl-dev libmpc-dev libmpfr-dev libncurses-dev libpython3-dev \
libreadline-dev libssl-dev libtool libyaml-dev libz-dev lld llvm lrzsz mkisofs msmtp nano \
ninja-build p7zip-full patch pkgconf python3 python3-pip python3-ply python3-docutils \
python3-pyelftools qemu-utils re2c rsync scons squashfs-tools subversion swig uglifyjs \
upx-ucl unzip vim wget xmlto xxd zlib1g-dev
success "完成"

# 3. 源码
echo -e "\n${YELLOW}[3/7] 拉取源码...${NC}"
if [[ -d "$OPENWRT_DIR" ]]; then
    read -p "删除现有目录? [y/N]: " r
    [[ "$r" =~ ^[Yy]$ ]] && rm -rf "$OPENWRT_DIR" || { error_exit "请先删除 $OPENWRT_DIR"; }
fi
if [[ ! -d "$OPENWRT_DIR" ]]; then
    git clone --depth 1 https://github.com/immortalwrt/immortalwrt "$OPENWRT_DIR" || error_exit "源码克隆失败"
    (cd "$OPENWRT_DIR" && git fetch origin tag "v$VERSION" --depth 1 && git checkout "v$VERSION") || error_exit "版本切换失败"
fi
success "完成"

# 4. 配置
echo -e "\n${YELLOW}[4/7] 准备配置...${NC}"
cd "$OPENWRT_DIR"
"$DIY" -v "$MAIN_VER" -p before -t "$RUN_TYPE"
./scripts/feeds update -a

# OAF 处理 (主路由可选，完整路由必需) - feeds update 之后，feeds install 之前
if [[ "$USE_OAF" == "true" ]]; then
  rm -rf package/{luci-app-oaf,open-app-filter,oaf} feeds/packages/{net/open-app-filter,luci/luci-app-oaf,kernel/oaf}
  rm -rf package/OpenAppFilter
  timeout 120 git clone --depth 1 https://github.com/destan19/OpenAppFilter package/OpenAppFilter
  [[ -f "$SCRIPT_DIR/oaf_files/feature.cfg" ]] && cp -f "$SCRIPT_DIR/oaf_files/feature.cfg" package/OpenAppFilter/open-app-filter/files/
  [[ -d "$SCRIPT_DIR/oaf_files/app_icons" ]] && cp -rf "$SCRIPT_DIR/oaf_files/app_icons" package/OpenAppFilter/luci-app-oaf/htdocs/luci-static/resources/
fi

# OpenClash LuCI 替换（仅旁路由 / 完整路由需要）。
# 注：AdGuardHome 已改为官方预编译二进制注入（见步骤 6），此处不再做 feeds 编译升级。
if [[ "$RUN_TYPE" == "bypass" || "$RUN_TYPE" == "full" ]]; then
  chmod +x "$SCRIPT_DIR/scripts/upgrade-openclash-luci.sh"
  "$SCRIPT_DIR/scripts/upgrade-openclash-luci.sh" "$OPENWRT_DIR"
fi

# AdGuardHome LuCI 壳去除对引擎包(adguardhome)的硬依赖：引擎改由二进制注入(files/)提供，
# 否则 luci-app-adguardhome 会因 unmet dependency(adguardhome) 编译失败。
# 25.12 feeds 含 luci-app-adguardhome（历史构建已验证可编出界面）。
case "$MAIN_VER" in 25.12)
  ADGH_LUCI_MK="$OPENWRT_DIR/feeds/luci/applications/luci-app-adguardhome/Makefile"
  if [ -f "$ADGH_LUCI_MK" ]; then
    sed -i -e 's/+adguardhome //g' -e '/LUCI_EXTRA_DEPENDS:=adguardhome/d' "$ADGH_LUCI_MK"
    echo "[build] 已去除 luci-app-adguardhome 对 adguardhome 的硬依赖（引擎走二进制注入）"
  else
    echo "[build] 警告: 未找到 luci-app-adguardhome Makefile，跳过依赖去除"
  fi
  ;;
esac

./scripts/feeds install -a -f
cp "$SCRIPT_DIR/configs/${MAIN_VER}-${CFG_PREFIX}.config" .config || error_exit "配置文件不存在"
sed -i 's/\r$//' .config
# full-noadgh：本 profile 不注入 ADGH 引擎，移除 LuCI 壳避免“有菜单无服务”
if [ "$RUN_TYPE" = "full" ] && [ "$NO_ADGH" = "true" ]; then
  sed -i 's/^CONFIG_PACKAGE_luci-app-adguardhome=y/# &/' .config
  sed -i 's/^CONFIG_PACKAGE_luci-i18n-adguardhome-zh-cn=y/# &/' .config
  echo "[build] full-noadgh: 已禁用 luci-app-adguardhome（无引擎）"
fi
# files/ 目录放在源码根目录下会被构建系统自动打包进固件，无需特殊配置
[[ "$USE_OAF" == "true" ]] && echo -e "\nCONFIG_PACKAGE_luci-app-oaf=y" >> .config
success "完成"

# 5. 网络配置
echo -e "\n${YELLOW}[5/7] 生成网络配置...${NC}"
"$DIY" -v "$MAIN_VER" -p after -t "$RUN_TYPE" \
  ${ROUTER_IP:+--ip "$ROUTER_IP"} \
  ${GATEWAY_IP:+--gateway "$GATEWAY_IP"} \
  ${BYPASS_IP:+--bypass-ip "$BYPASS_IP"} \
  ${PPPOE_USER:+--pppoe-user "$PPPOE_USER"} ${PPPOE_PASS:+--pppoe-pass "$PPPOE_PASS"} \
  ${NO_ADGH:+--no-adgh} \
  --root-pass "$ROOT_PWD"
success "完成"

# 6. 预装核心 + 打包 files
echo -e "\n${YELLOW}[6/7] 预装核心与打包文件...${NC}"
# OpenClash Meta 核心预装（旁路由 + 完整路由，跳过首次启动在线下载）
if [[ "$RUN_TYPE" == "bypass" || "$RUN_TYPE" == "full" ]]; then
    chmod +x "$SCRIPT_DIR/scripts/upgrade-openclash-core.sh"
    "$SCRIPT_DIR/scripts/upgrade-openclash-core.sh" "$SCRIPT_DIR"
fi
# AdGuardHome 官方预编译二进制注入（旁路由 + 完整路由；full-noadgh 不注入）。
# 构建期免 Go 编译，保证最新版；二进制写入 $SCRIPT_DIR/files/usr/bin/AdGuardHome 后随 files/ 打包。
if [[ "$RUN_TYPE" == "bypass" || ("$RUN_TYPE" == "full" && "$NO_ADGH" != "true") ]]; then
    chmod +x "$SCRIPT_DIR/scripts/upgrade-adgh-binary.sh"
    "$SCRIPT_DIR/scripts/upgrade-adgh-binary.sh" "$SCRIPT_DIR"
fi
[[ -d "$SCRIPT_DIR/files" ]] && { rm -rf "$OPENWRT_DIR/files"; cp -rf "$SCRIPT_DIR/files" "$OPENWRT_DIR/"; }
# 文件清理：按 profile 删除不需要的静态文件（在 openwrt 副本上操作，不修改源树）
case "$RUN_TYPE" in
  main)
    rm -rf "$OPENWRT_DIR/files/etc/adguardhome"
    rm -rf "$OPENWRT_DIR/files/etc/openclash"
    rm -f "$OPENWRT_DIR/files/usr/bin/AdGuardHome"
    rm -f "$OPENWRT_DIR/files/etc/init.d/adguardhome"
    rm -f "$OPENWRT_DIR/files/etc/config/adguardhome"
    ;;
  bypass)
    rm -f "$OPENWRT_DIR/files/usr/sbin/dns-hijack"
    ;;
  full)
    if [ "$NO_ADGH" = "true" ]; then
      rm -rf "$OPENWRT_DIR/files/etc/adguardhome"
      rm -f "$OPENWRT_DIR/files/usr/bin/AdGuardHome"
      rm -f "$OPENWRT_DIR/files/etc/init.d/adguardhome"
      rm -f "$OPENWRT_DIR/files/etc/config/adguardhome"
    fi
    ;;
esac
BXPLUG_VER="${MAIN_VER%%.*}"
case "$BXPLUG_VER" in
  25) rm -f "$OPENWRT_DIR/files/etc/bxplug.ipk";;
  24) rm -f "$OPENWRT_DIR/files/etc/bxplug.apk";;
  *)  rm -f "$OPENWRT_DIR/files/etc/bxplug.ipk" "$OPENWRT_DIR/files/etc/bxplug.apk";;
esac
# 确保脚本可执行（Windows 无 Unix x 位，按路径/扩展名匹配）
find "$OPENWRT_DIR/files" -type f \( -path "*/sbin/*" -o -path "*/init.d/*" -o -path "*/hotplug.d/*" -o -path "*/uci-defaults/*" -o -name "*.sh" \) -exec chmod 755 {} + 2>/dev/null || true
make defconfig && make download && make clean
success "完成"

# 7. 编译
echo -e "\n${YELLOW}[7/7] 编译固件...${NC}"
make -j$(nproc) || make -j1 V=s

echo -e "\n${GREEN}========================================  编译完成!  ========================================${NC}"
echo "固件位置: $OPENWRT_DIR/bin/targets/x86/64/"
ls -la "$OPENWRT_DIR/bin/targets/x86/64/"*combined*.img.gz 2>/dev/null || true
