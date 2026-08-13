#!/bin/bash
# ImmortalWrt / FanchmWrt 本地编译脚本（Debian/Ubuntu）
# 双核心由 cores/<core>.conf 驱动：immortalwrt(默认, OAF/OC/ADGH 全功能) / fanchmwrt(OpenWrt fork, 原生 fwx)。
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORE_CONF_DIR="$SCRIPT_DIR/cores"

# ========== 1. 核心选择 ==========
echo "========================================"
echo "    路由固件本地编译脚本"
echo "========================================"
echo -e "\n请选择核心（编译源）："
echo "  1) immortalwrt (默认)  2) fanchmwrt (OpenWrt fork / fwx)"
read -p "请输入选择 [1-2，默认 1]: " c
c=${c:-1}
case "$c" in 1) CORE="immortalwrt";; 2) CORE="fanchmwrt";; *) error_exit "无效选择";; esac

# source 核心描述文件
CORE_CONF="$CORE_CONF_DIR/$CORE.conf"
[ -f "$CORE_CONF" ] || error_exit "缺失核心描述: $CORE_CONF"
# shellcheck disable=SC1090
source "$CORE_CONF"
success "核心: $CORE ($REPO_URL)"

# ========== 2. 版本选择（来自核心描述 VERSION_OPTIONS） ==========
echo -e "\n请选择 $CORE 版本："
i=1
for v in $VERSION_OPTIONS; do echo "  $i) $v"; i=$((i+1)); done
read -p "请输入选择 [1-$(($i-1))，默认 1]: " vsel
vsel=${vsel:-1}
VERSION=$(echo $VERSION_OPTIONS | awk -v n="$vsel" '{print $n}')
[ -n "$VERSION" ] || error_exit "无效选择"
success "版本: $VERSION"

# ========== 3. 配置选择 ==========
echo -e "\n请选择编译配置："
if [ "$CORE" = "fanchmwrt" ]; then
  echo "  1) Main (主路由)  2) Mini (旁路由)"
  read -p "请输入选择 [1-2，默认 1]: " p
  p=${p:-1}
  case "$p" in 1) PROFILE="Main";; 2) PROFILE="Mini";; *) error_exit "无效选择";; esac
else
  echo "  1) Main (主路由)  2) Mini (旁路由)  3) Full (完整路由)  4) Full-noadgh (完整路由无ADGH)"
  read -p "请输入选择 [1-4，默认 1]: " p
  p=${p:-1}
  case "$p" in 1) PROFILE="Main";; 2) PROFILE="Mini";; 3) PROFILE="Full";; 4) PROFILE="Full-noadgh";; *) error_exit "无效选择";; esac
fi

# 解析配置（显式映射，避免按 '-' 拆分带来的歧义）
case "$PROFILE" in
  Main)        CFG_PREFIX=default; RUN_TYPE=main;;
  Mini)        CFG_PREFIX=mini;    RUN_TYPE=bypass;;
  Full)        CFG_PREFIX=full;    RUN_TYPE=full;;
  Full-noadgh) CFG_PREFIX=full;    RUN_TYPE=full; NO_ADGH="true";;
  *) error_exit "无效配置: $PROFILE";;
esac
NO_ADGH=${NO_ADGH:-false}
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

# WAN 物理口：x86 多网口约定"最前口=WAN、其余口(含最后口)桥接=LAN"。
# FanchmWrt 首启自动识别（留空即最前口=WAN，其余口桥接）；immortalWrt 留空则默认 eth0。仅需强制覆盖时才填。
read -p "WAN 物理口(留空=FanchmWrt 自动最前口 / immortalWrt 默认 eth0) [默认: 自动]: " wanif; WAN_IFACE="$wanif"

# OAF / OC / ADGH：仅 immortalwrt 需要；fanchmwrt 关闭（原生编译，包由 apps/lists 装）
USE_OAF="false"; WITH_OC="false"; WITH_ADGH="false"
if [ "$CORE" = "immortalwrt" ]; then
  if [[ "$RUN_TYPE" == "full" ]]; then
    USE_OAF="true"
    success "完整路由: OAF 始终安装"
  elif [[ "$RUN_TYPE" == "main" ]]; then
    read -p "安装OAF? [y/N]: " oaf; [[ "$oaf" =~ ^[Yy]$ ]] && USE_OAF="true" && success "将安装OAF"
  fi
  [[ "$RUN_TYPE" == "bypass" || "$RUN_TYPE" == "full" ]] && WITH_OC=true
  [[ "$RUN_TYPE" == "bypass" || ("$RUN_TYPE" == "full" && "$NO_ADGH" != "true") ]] && WITH_ADGH=true
fi

# 旁路 IP (仅 immortalwrt 主路由，用于 DNS 劫持排除规则和 DHCP DNS 选项)
BYPASS_IP=""
if [[ "$RUN_TYPE" == "main" && "$CORE" = "immortalwrt" ]]; then
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
echo "  核心: $CORE | 版本: $VERSION | 配置: $PROFILE | IP: $ROUTER_IP | 类型: $RUN_TYPE"
[[ -n "$GATEWAY_IP" ]] && echo "  网关: $GATEWAY_IP"
[[ -n "$PPPOE_USER" ]] && echo "  PPPoE: $PPPOE_USER"
[[ "$USE_OAF" == "true" ]] && echo "  OAF: 是"
[[ -n "$BYPASS_IP" ]] && echo "  旁路IP: $BYPASS_IP"
echo "==================================================================================="
read -p "确认开始? [Y/n]: " c; [[ "$c" =~ ^[Nn]$ ]] && exit 0

# ========== 编译 ==========
OPENWRT_DIR="$SCRIPT_DIR/openwrt"
DIY="$SCRIPT_DIR/scripts/diy.sh"
FEEDS_FILE_ABS="$SCRIPT_DIR/$FEEDS_FILE"
FILES_DIR_ABS="$SCRIPT_DIR/$FILES_DIR"

# 1. 换行符（路由器 ash 不兼容 CRLF）：统一修复 scripts/ 与 files/ 下所有脚本、YAML 及 init.d
echo -e "\n${YELLOW}[1/7] 检查换行符和权限...${NC}"
find "$SCRIPT_DIR/scripts" "$SCRIPT_DIR/$FILES_DIR" "$SCRIPT_DIR/files/common" -type f \
  \( -name "*.sh" -o -name "*.yaml" -o -name "dns-hijack" -o -name "99-adgh-filters" -o -path "*/init.d/*" \) \
  -exec sed -i 's/\r$//' {} + 2>/dev/null || true
chmod +x "$DIY" "$SCRIPT_DIR/build.sh" "$SCRIPT_DIR/scripts/upgrade-adgh-binary.sh" "$SCRIPT_DIR/scripts/upgrade-openclash-core.sh" "$SCRIPT_DIR/scripts/upgrade-openclash-luci.sh"
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
# 取源引用：immortalwrt 用 tag（v${VERSION}）；fanchmwrt 的 fwx 内核栈(kmod-fwx/fwxd) 仅在其
# 主仓库【分支】fanchmwrt-${VERSION}，所有 v25.12.x tag 均不含，故 FanchmWrt 改用分支取源。
if [[ "$CORE" = "fanchmwrt" ]]; then
    SRC_REF="fanchmwrt-${VERSION}"
else
    SRC_REF="${REF_PREFIX}${VERSION}"
fi
if [[ -d "$OPENWRT_DIR" ]]; then
    read -p "删除现有目录? [y/N]: " r
    [[ "$r" =~ ^[Yy]$ ]] && rm -rf "$OPENWRT_DIR" || { error_exit "请先删除 $OPENWRT_DIR"; }
fi
if [[ ! -d "$OPENWRT_DIR" ]]; then
    # 直接按 SRC_REF（tag/分支）克隆检出，避免浅克隆 fetch 后无本地 ref 致 checkout 失败
    git clone --depth 1 --single-branch --branch "$SRC_REF" "$REPO_URL" "$OPENWRT_DIR" || error_exit "源码克隆失败"
fi
success "完成（取源引用: $SRC_REF）"

# 4. 配置
echo -e "\n${YELLOW}[4/7] 准备配置...${NC}"
cd "$OPENWRT_DIR"
"$DIY" -v "$MAIN_VER" -p before -t "$RUN_TYPE" --core "$CORE" --feeds "$FEEDS_FILE_ABS"
./scripts/feeds update -a

# OAF 处理 (仅 immortalwrt；主路由可选，完整路由必需) - feeds update 之后，feeds install 之前
if [[ "$USE_OAF" == "true" ]]; then
  rm -rf package/{luci-app-oaf,open-app-filter,oaf} feeds/packages/{net/open-app-filter,luci/luci-app-oaf,kernel/oaf}
  rm -rf package/OpenAppFilter
  timeout 120 git clone --depth 1 https://github.com/destan19/OpenAppFilter package/OpenAppFilter
  [[ -f "$SCRIPT_DIR/appfilter-assets/feature.cfg" ]] && cp -f "$SCRIPT_DIR/appfilter-assets/feature.cfg" package/OpenAppFilter/open-app-filter/files/
  [[ -d "$SCRIPT_DIR/appfilter-assets/oaf-icons" ]] && cp -rf "$SCRIPT_DIR/appfilter-assets/oaf-icons" package/OpenAppFilter/luci-app-oaf/htdocs/luci-static/resources/
fi

# OpenClash LuCI 替换（仅 immortalwrt 旁路由 / 完整路由）
if [[ "$WITH_OC" == "true" ]]; then
  chmod +x "$SCRIPT_DIR/scripts/upgrade-openclash-luci.sh"
  "$SCRIPT_DIR/scripts/upgrade-openclash-luci.sh" "$OPENWRT_DIR"
fi

# AdGuardHome LuCI 壳去除对引擎包(adguardhome)的硬依赖（仅 immortalwrt 25.12；引擎走二进制注入）
if [[ "$CORE" = "immortalwrt" && "$MAIN_VER" = "25.12" ]]; then
  ADGH_LUCI_MK="$OPENWRT_DIR/feeds/luci/applications/luci-app-adguardhome/Makefile"
  if [ -f "$ADGH_LUCI_MK" ]; then
    sed -i -e 's/+adguardhome //g' -e '/LUCI_EXTRA_DEPENDS:=adguardhome/d' "$ADGH_LUCI_MK"
    echo "[build] 已去除 luci-app-adguardhome 对 adguardhome 的硬依赖（引擎走二进制注入）"
  else
    echo "[build] 警告: 未找到 luci-app-adguardhome Makefile，跳过依赖去除"
  fi
fi

./scripts/feeds install -a -f

# FanchmWrt：内联最小 target + 必要 kmod + apk（不依赖本地 .config 种子），镜像格式/分区大小引用 immortalWrt 默认配置以保持输出一致；
# Web 后台(luci + fwx 仪表盘 + kmod-fwx/fwxd) 随下方 .config 编入镜像，其余 userspace 包(ddns/upnp/wol/udpxy/vlan 等)走首启安装。
if [[ "$CORE" = "fanchmwrt" ]]; then
  cat > .config <<'EOF'
CONFIG_TARGET_x86=y
CONFIG_TARGET_x86_64=y
CONFIG_USE_APK=y
CONFIG_PACKAGE_kmod-e1000=y
CONFIG_PACKAGE_kmod-e1000e=y
CONFIG_PACKAGE_kmod-igb=y
CONFIG_PACKAGE_kmod-igc=y
CONFIG_PACKAGE_kmod-vmxnet3=y
CONFIG_PACKAGE_kmod-r8169=y
CONFIG_PACKAGE_kmod-ixgbe=y
CONFIG_PACKAGE_kmod-ppp=y
CONFIG_PACKAGE_kmod-pppoe=y
CONFIG_PACKAGE_kmod-pppox=y
CONFIG_PACKAGE_kmod-nft-offload=y
CONFIG_PACKAGE_wget-ssl=y
# FanchmWrt 后台/主题：标准 luci + fwx 仪表盘皮肤 + kmod-fwx/fwxd（源码在主仓库 package/fcm/，随 clone 编入镜像；dashboard 硬依赖二者，一并选上）。
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-compat=y
CONFIG_PACKAGE_luci-i18n-base-zh-cn=y
CONFIG_PACKAGE_kmod-fwx=y
CONFIG_PACKAGE_fwxd=y
CONFIG_PACKAGE_luci-app-fwx-dashboard=y
CONFIG_PACKAGE_luci-app-fwx-resources=y
CONFIG_PACKAGE_luci-app-fwx-dashboard-setting=y
CONFIG_PACKAGE_luci-app-fwx-appfilter=y
CONFIG_PACKAGE_luci-app-fwx-system=y
CONFIG_PACKAGE_luci-app-fwx-network=y
CONFIG_PACKAGE_luci-app-fwx-app-center=y
CONFIG_PACKAGE_luci-app-fwx-feature=y
CONFIG_PACKAGE_luci-app-fwx-macfilter=y
CONFIG_PACKAGE_luci-app-fwx-mac-blacklist=y
CONFIG_PACKAGE_luci-app-fwx-record=y
CONFIG_PACKAGE_luci-app-fwx-record-whitelist=y
CONFIG_PACKAGE_luci-app-fwx-session-stat=y
CONFIG_PACKAGE_luci-app-fwx-user=y
CONFIG_PACKAGE_luci-app-fwx-user-record=y
EOF
  # 镜像格式 / 磁盘分区大小 直接参考 immortalWrt 默认配置，避免依赖 make defconfig 默认值
  IW_CONF="$SCRIPT_DIR/cores/immortalwrt.conf"
  [[ -f "$IW_CONF" ]] || error_exit "缺失 immortalwrt 核心描述: $IW_CONF"
  # shellcheck disable=SC1090
  source "$IW_CONF"
  REF_CFG="$SCRIPT_DIR/configs/${CONFIG_PREFIX}-default.config"
  [[ -f "$REF_CFG" ]] || error_exit "参考配置不存在: $REF_CFG（FanchmWrt 镜像格式/分区大小依赖它）"
  grep -E '^(CONFIG_(GRUB_IMAGES|GRUB_EFI_IMAGES|TARGET_ROOTFS_(SQUASHFS|EXT4)|TARGET_IMAGES_GZIP|TARGET_(KERNEL|ROOTFS)_PARTSIZE|ISO_IMAGES|VDI_IMAGES|VMDK_IMAGES|QCOW2_IMAGES|VHDX_IMAGES))=' "$REF_CFG" >> .config
  sed -i 's/\r$//' .config
  echo "[build] FanchmWrt: 已写入最小 .config（target+kmod）+ 引用 immortalWrt 镜像格式/分区大小，make defconfig 将展开"

  # FanchmWrt：用本项目定制 feature.cfg 覆盖 fwxd 自带应用特征库。
  # fwxd 的 Makefile 把 package/fcm/fwxd/files/*.cfg 安装到固件 /etc/fwxd/feature.cfg，
  # 本自定义库与 fwxd 同为 #format v3.0 应用特征库（仅版本号更新），可直接替换。
  FWXD_CFG="$OPENWRT_DIR/package/fcm/fwxd/files/feature.cfg"
  if [[ -f "$SCRIPT_DIR/appfilter-assets/feature.cfg" && -f "$FWXD_CFG" ]]; then
    cp -f "$SCRIPT_DIR/appfilter-assets/feature.cfg" "$FWXD_CFG"
    echo "[build] FanchmWrt: 已用 appfilter-assets/feature.cfg 覆盖 fwxd 应用特征库 (-> /etc/fwxd/feature.cfg)"
  elif [[ -f "$SCRIPT_DIR/appfilter-assets/feature.cfg" ]]; then
    echo "[build] 警告: 未找到 fwxd feature.cfg（package/fcm/fwxd/files/feature.cfg），跳过覆盖"
  fi
else
  cp "$SCRIPT_DIR/configs/${CONFIG_PREFIX}-${CFG_PREFIX}.config" .config || error_exit "配置文件不存在: configs/${CONFIG_PREFIX}-${CFG_PREFIX}.config"
  sed -i 's/\r$//' .config
  # Full-noadgh：本 profile 不注入 ADGH 引擎，移除 LuCI 壳避免“有菜单无服务”（仅 immortalwrt）
  if [[ "$RUN_TYPE" = "full" && "$NO_ADGH" = "true" ]]; then
    sed -i 's/^CONFIG_PACKAGE_luci-app-adguardhome=y/# &/' .config
    sed -i 's/^CONFIG_PACKAGE_luci-i18n-adguardhome-zh-cn=y/# &/' .config
    echo "[build] Full-noadgh: 已禁用 luci-app-adguardhome（无引擎）"
  fi
fi
[[ "$USE_OAF" == "true" ]] && echo -e "\nCONFIG_PACKAGE_luci-app-oaf=y" >> .config
success "完成"

# 5. 网络配置
echo -e "\n${YELLOW}[5/7] 生成网络配置...${NC}"
# --no-adgh 仅在 NO_ADGH=true 时传入（immortalwrt Full-noadgh）
NOADGH_ARG=""
[ "$NO_ADGH" = "true" ] && NOADGH_ARG="--no-adgh"
"$DIY" -v "$MAIN_VER" -p after -t "$RUN_TYPE" --core "$CORE" --files-dir "$FILES_DIR_ABS" \
  ${ROUTER_IP:+--ip "$ROUTER_IP"} \
  ${GATEWAY_IP:+--gateway "$GATEWAY_IP"} \
  ${BYPASS_IP:+--bypass-ip "$BYPASS_IP"} \
  ${PPPOE_USER:+--pppoe-user "$PPPOE_USER"} ${PPPOE_PASS:+--pppoe-pass "$PPPOE_PASS"} \
  ${NOADGH_ARG:+"$NOADGH_ARG"} \
  ${WAN_IFACE:+--wan-iface "$WAN_IFACE"} \
  --root-pass "$ROOT_PWD"
success "完成"

# 6. 预装核心 + 打包 files
echo -e "\n${YELLOW}[6/7] 预装核心与打包文件...${NC}"
# OpenClash Meta 核心预装（仅 immortalwrt 旁路由 + 完整路由）
if [[ "$WITH_OC" == "true" ]]; then
    chmod +x "$SCRIPT_DIR/scripts/upgrade-openclash-core.sh"
    "$SCRIPT_DIR/scripts/upgrade-openclash-core.sh" "$SCRIPT_DIR" --files-dir "$FILES_DIR_ABS"
fi
# AdGuardHome 官方预编译二进制注入（仅 immortalwrt 旁路由 + 完整路由；Full-noadgh 不注入）
if [[ "$WITH_ADGH" == "true" ]]; then
    chmod +x "$SCRIPT_DIR/scripts/upgrade-adgh-binary.sh"
    "$SCRIPT_DIR/scripts/upgrade-adgh-binary.sh" "$SCRIPT_DIR" --files-dir "$FILES_DIR_ABS"
fi
[[ -d "$FILES_DIR_ABS" ]] && { rm -rf "$OPENWRT_DIR/files"; cp -rf "$FILES_DIR_ABS" "$OPENWRT_DIR/files"; }
# 共享静态文件层（双核通用，如 cpufreq-perf）：覆盖到核专属 files 之上
[[ -d "$SCRIPT_DIR/files/common" ]] && { cp -rf "$SCRIPT_DIR/files/common/." "$OPENWRT_DIR/files/"; }

# 离线 .apk：双核都拷入镜像首启安装目录 /etc/firstboot-pkgs/apps/（由各自 firstboot-pkgs 用 --allow-untrusted 安装）
mkdir -p "$OPENWRT_DIR/files/etc/firstboot-pkgs/apps"
cp -f "$SCRIPT_DIR/apps/"*.apk "$OPENWRT_DIR/files/etc/firstboot-pkgs/apps/" 2>/dev/null || true
# lists/(官方源包名)：仅 FanchmWrt 需要（首启在线安装）
if [[ "$CORE" = "fanchmwrt" ]]; then
  mkdir -p "$OPENWRT_DIR/files/etc/firstboot-pkgs/lists"
  cp -f "$SCRIPT_DIR/lists/"*.txt "$OPENWRT_DIR/files/etc/firstboot-pkgs/lists/" 2>/dev/null || true
fi

# 文件清理：按 profile 删除不需要的静态文件（仅 immortalwrt；在 openwrt 副本上操作，不修改源树）
if [[ "$CORE" = "immortalwrt" ]]; then
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
fi
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
