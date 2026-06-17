#!/bin/bash
# ImmortalWrt 本地编译脚本 - Debian/Ubuntu
# 用法: chmod +x build.sh && ./build.sh

set -e

# 颜色定义
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
error_exit() { echo -e "${RED}错误：$1${NC}" >&2; exit 1; }
success() { echo -e "${GREEN}[OK] $1${NC}"; }
warn() { echo -e "${YELLOW}[警告] $1${NC}"; }

# 默认配置
DEF_MAIN_IP="10.10.10.1"
DEF_BYPASS_IP="10.10.10.10"
DEF_GATEWAY="10.10.10.1"
ROOT_PASSWORD="password"

# 修复换行符
fix_line_endings() { [[ -f "$1" ]] && grep -q $'\r' "$1" 2>/dev/null && sed -i 's/\r$//' "$1"; }

# 交互式输入
echo "========================================"
echo "   ImmortalWrt x86_64 本地编译脚本"
echo "========================================"

# 版本选择
echo -e "\n请选择 ImmortalWrt 版本："
echo "  1) 25.12.0  2) 24.10.1  3) 24.10.2  4) 24.10.3"
echo "  5) 24.10.4  6) 24.10.5  7) 24.10.6"
read -p "请输入选择 [1-7，默认 1]: " v
v=${v:-1}
case "$v" in 1) VERSION="25.12.0";; 2) VERSION="24.10.1";; 3) VERSION="24.10.2";; 4) VERSION="24.10.3";; 5) VERSION="24.10.4";; 6) VERSION="24.10.5";; 7) VERSION="24.10.6";; *) error_exit "无效选择";; esac
success "版本: $VERSION"

# 配置选择
echo -e "\n请选择编译配置："
echo "  1) default-main (主路由)  2) mini-bypass (旁路由)  3) full-main (完整)"
read -p "请输入选择 [1-3，默认 1]: " p
p=${p:-1}
case "$p" in 1) PROFILE="default-main";; 2) PROFILE="mini-bypass";; 3) PROFILE="full-main";; *) error_exit "无效选择";; esac
success "配置: $PROFILE"

# 解析配置
IFS='-' read -r CFG_PREFIX RUN_TYPE <<< "$PROFILE"
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

# PPPoE (仅主路由)
PPPOE_USER="" PPPOE_PASS=""
[[ "$RUN_TYPE" == "main" ]] && { read -p "配置PPPoE? [y/N]: " pp; [[ "$pp" =~ ^[Yy]$ ]] && { read -p "用户名: " PPPOE_USER; read -p "密码: " PPPOE_PASS; success "PPPoE已配置"; } || success "使用DHCP"; }

# OAF (仅主路由)
USE_OAF="false"
[[ "$RUN_TYPE" == "main" ]] && { read -p "安装OAF? [y/N]: " oaf; [[ "$oaf" =~ ^[Yy]$ ]] && USE_OAF="true" && success "将安装OAF"; }

# Root密码
read -p "Root密码 [默认: password]: " rp
ROOT_PWD="${rp:-$ROOT_PASSWORD}"
success "密码已设置"

# 确认
echo -e "\n========================================  准备编译  ========================================  版本: $VERSION | 配置: $PROFILE | IP: $ROUTER_IP"
[[ -n "$GATEWAY_IP" ]] && echo "  网关: $GATEWAY_IP"
[[ -n "$PPPOE_USER" ]] && echo "  PPPoE: $PPPOE_USER"
[[ "$USE_OAF" == "true" ]] && echo "  OAF: 是"
echo "========================================"
read -p "确认开始? [Y/n]: " c; [[ "$c" =~ ^[Nn]$ ]] && exit 0

# ========== 编译 ==========
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENWRT_DIR="$SCRIPT_DIR/openwrt"
DIY="$SCRIPT_DIR/scripts/diy.sh"

# 1. 换行符
echo -e "\n${YELLOW}[1/6] 检查换行符...${NC}"
fix_line_endings "$DIY" "$SCRIPT_DIR/build.sh"
success "完成"

# 2. 依赖
echo -e "\n${YELLOW}[2/6] 安装依赖...${NC}"
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
echo -e "\n${YELLOW}[3/6] 拉取源码...${NC}"
[[ -d "$OPENWRT_DIR" ]] && { read -p "删除现有目录? [y/N]: " r; [[ "$r" =~ ^[Yy]$ ]] && rm -rf "$OPENWRT_DIR" || cd "$OPENWRT_DIR"; }
[[ ! -d "$OPENWRT_DIR" ]] && { git clone --depth 1 https://github.com/immortalwrt/immortalwrt "$OPENWRT_DIR"; cd "$OPENWRT_DIR"; git fetch origin tag "v$VERSION" --depth 1; git checkout "v$VERSION"; }
success "完成"

# 4. 配置
echo -e "\n${YELLOW}[4/6] 准备配置...${NC}"
cd "$OPENWRT_DIR"
chmod +x "$DIY"
"$DIY" -v "$MAIN_VER" -p before -t "$RUN_TYPE"
./scripts/feeds update -a

# OAF 处理 (仅主路由) - 在 feeds install 之前
if [[ "$USE_OAF" == "true" ]]; then
  rm -rf feeds/packages/{oaf,luci-app-oaf,open-app-filter} 2>/dev/null
  rm -rf package/OpenAppFilter
  git clone --depth 1 https://github.com/destan19/OpenAppFilter package/OpenAppFilter
  [[ -f "$SCRIPT_DIR/oaf_files/feature.cfg" ]] && cp -f "$SCRIPT_DIR/oaf_files/feature.cfg" package/OpenAppFilter/open-app-filter/files/
  [[ -d "$SCRIPT_DIR/oaf_files/app_icons" ]] && cp -rf "$SCRIPT_DIR/oaf_files/app_icons" package/OpenAppFilter/luci-app-oaf/htdocs/luci-static/resources/
fi

./scripts/feeds install -a
cp "$SCRIPT_DIR/configs/${MAIN_VER}-${CFG_PREFIX}.config" .config || error_exit "配置文件不存在"
sed -i 's/\r$//' .config
[[ "$USE_OAF" == "true" ]] && { echo "" >> .config; echo "CONFIG_PACKAGE_luci-app-oaf=y" >> .config; }
success "完成"

# 5. 网络配置
echo -e "\n${YELLOW}[5/6] 生成网络配置...${NC}"
"$DIY" -v "$MAIN_VER" -p after -t "$RUN_TYPE" \
  ${ROUTER_IP:+--ip "$ROUTER_IP"} ${GATEWAY_IP:+--gateway "$GATEWAY_IP"} \
  ${PPPOE_USER:+--pppoe-user "$PPPOE_USER"} ${PPPOE_PASS:+--pppoe-pass "$PPPOE_PASS"} \
  --root-pass "$ROOT_PWD"
success "完成"

# 6. 编译
echo -e "\n${YELLOW}[6/6] 编译固件...${NC}"
echo -e "\n${YELLOW}[DEBUG] .config 内容:${NC}"
cat .config
echo ""
make defconfig && make download -j$(nproc) && make -j$(nproc) || make -j1 V=s

echo -e "\n${GREEN}========================================  编译完成!  ========================================${NC}"
echo "固件位置: $OPENWRT_DIR/bin/targets/x86/64/"
ls -la "$OPENWRT_DIR/bin/targets/x86/64/"*combined*.img.gz 2>/dev/null || true
