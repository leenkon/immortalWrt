#!/bin/bash
# ImmortalWrt 本地编译脚本 - Debian/Ubuntu
# 用法: chmod +x build.sh && ./build.sh

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 默认配置
DEF_MAIN_IP="10.10.10.1"
DEF_BYPASS_IP="10.10.10.10"
DEF_GATEWAY="10.10.10.1"
ROOT_PASSWORD="password"

# UCI 字符转义
_escape_uci() {
    local str="$1"
    str="${str//\\/\\\\}"
    str="${str//\"/\\\"}"
    str="${str//\'/\\\'}"
    printf '%s' "$str"
}

# 错误退出
error_exit() {
    echo -e "${RED}错误：$1${NC}" >&2
    exit 1
}

# 成功提示
success() {
    echo -e "${GREEN}[OK] $1${NC}"
}

# 警告提示
warn() {
    echo -e "${YELLOW}[警告] $1${NC}"
}

# 显示标题
show_header() {
    echo "========================================"
    echo "   ImmortalWrt x86_64 本地编译脚本"
    echo "========================================"
    echo ""
}

# 交互式输入
show_header

# 版本选择
echo "请选择 ImmortalWrt 版本："
echo "  1) 25.12.0"
echo "  2) 24.10.1"
echo "  3) 24.10.2"
echo "  4) 24.10.3"
echo "  5) 24.10.4"
echo "  6) 24.10.5"
echo "  7) 24.10.6"
read -p "请输入选择 [1-7，默认 1]: " version_choice
version_choice=${version_choice:-1}

case "$version_choice" in
    1) VERSION="25.12.0" ;;
    2) VERSION="24.10.1" ;;
    3) VERSION="24.10.2" ;;
    4) VERSION="24.10.3" ;;
    5) VERSION="24.10.4" ;;
    6) VERSION="24.10.5" ;;
    7) VERSION="24.10.6" ;;
    *) error_exit "无效的版本选择" ;;
esac
success "选择版本: $VERSION"

# 配置选择
echo ""
echo "请选择编译配置："
echo "  1) default-main   (主路由 - 完整功能)"
echo "  2) mini-bypass    (旁路由 - 精简代理)"
echo "  3) full-main     (主路由 - 全部功能)"
read -p "请输入选择 [1-3，默认 1]: " profile_choice
profile_choice=${profile_choice:-1}

case "$profile_choice" in
    1) PROFILE="default-main" ;;
    2) PROFILE="mini-bypass" ;;
    3) PROFILE="full-main" ;;
    *) error_exit "无效的配置选择" ;;
esac
success "选择配置: $PROFILE"

# 解析配置
IFS='-' read -r CFG_PREFIX RUN_TYPE <<< "$PROFILE"
MAIN_VER=${VERSION%.*}

# 自定义IP
echo ""
read -p "自定义LAN IP [默认主路由: $DEF_MAIN_IP，旁路由: $DEF_BYPASS_IP，回车跳过]: " custom_ip
if [[ -z "$custom_ip" ]]; then
    if [[ "$RUN_TYPE" == "bypass" ]]; then
        ROUTER_IP="$DEF_BYPASS_IP"
    else
        ROUTER_IP="$DEF_MAIN_IP"
    fi
else
    ROUTER_IP="$custom_ip"
fi
success "LAN IP: $ROUTER_IP"

# 网关(仅旁路由)
if [[ "$RUN_TYPE" == "bypass" ]]; then
    echo ""
    read -p "网关IP (主路由地址) [默认: $DEF_GATEWAY，回车跳过]: " custom_gateway
    GATEWAY_IP="${custom_gateway:-$DEF_GATEWAY}"
    success "网关: $GATEWAY_IP"
else
    GATEWAY_IP=""
fi

# PPPoE (仅主路由)
if [[ "$RUN_TYPE" == "main" ]]; then
    echo ""
    read -p "是否配置PPPoE? [y/N，默认 N]: " use_pppoe
    if [[ "$use_pppoe" =~ ^[Yy]$ ]]; then
        read -p "PPPoE 用户名: " pppoe_user
        read -p "PPPoE 密码: " pppoe_pass
        PPPOE_USER="$pppoe_user"
        PPPOE_PASS="$pppoe_pass"
        success "PPPoE 已配置"
    else
        PPPOE_USER=""
        PPPOE_PASS=""
        success "使用 DHCP 模式"
    fi
fi

# OAF (仅主路由)
if [[ "$RUN_TYPE" == "main" ]]; then
    echo ""
    read -p "是否安装 OpenAppFilter (OAF)? [y/N，默认 N]: " install_oaf
    if [[ "$install_oaf" =~ ^[Yy]$ ]]; then
        USE_OAF="true"
        success "将安装 OAF"
    else
        USE_OAF="false"
    fi
else
    USE_OAF="false"
fi

# Root密码
echo ""
read -p "Root 密码 [默认: password]: " root_pass
ROOT_PWD="${root_pass:-$ROOT_PASSWORD}"
success "Root 密码已设置"

# 确认开始编译
echo ""
echo "========================================"
echo "准备开始编译"
echo "========================================"
echo "  版本: $VERSION"
echo "  配置: $PROFILE ($RUN_TYPE)"
echo "  LAN IP: $ROUTER_IP"
[[ -n "$GATEWAY_IP" ]] && echo "  网关: $GATEWAY_IP"
[[ "$RUN_TYPE" == "main" ]] && [[ -n "$PPPOE_USER" ]] && echo "  PPPoE: $PPPOE_USER"
[[ "$USE_OAF" == "true" ]] && echo "  安装 OAF: 是"
echo "========================================"
read -p "确认开始编译? [Y/n]: " confirm
[[ "$confirm" =~ ^[Nn]$ ]] && exit 0

# ========== 开始编译 ==========

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENWRT_DIR="$SCRIPT_DIR/openwrt"
DIY_SCRIPT="$SCRIPT_DIR/scripts/diy.sh"
CONFIG_FILE="$SCRIPT_DIR/configs/${MAIN_VER}-${CFG_PREFIX}.config"

# 1. 安装依赖
echo ""
echo -e "${YELLOW}[1/6] 安装编译依赖...${NC}"
sudo apt update -y
sudo apt install -y ack antlr3 asciidoc autoconf automake autopoint binutils bison build-essential \
    bzip2 ccache clang cmake cpio curl device-tree-compiler ecj fastjar flex gawk gettext gcc-multilib \
    g++-multilib git gnutls-dev gperf haveged help2man intltool lib32gcc-s1 libc6-dev-i386 libelf-dev \
    libglib2.0-dev libgmp-dev libltdl-dev libmpc-dev libmpfr-dev libncurses-dev libpython3-dev \
    libreadline-dev libssl-dev libtool libyaml-dev libz-dev lld llvm lrzsz mkisofs msmtp nano \
    ninja-build p7zip-full patch pkgconf python3 python3-pip python3-ply python3-docutils \
    python3-pyelftools qemu-utils re2c rsync scons squashfs-tools subversion swig uglifyjs \
    upx-ucl unzip vim wget xmlto xxd zlib1g-dev
success "依赖安装完成"

# 2. 拉取源码
echo ""
echo -e "${YELLOW}[2/6] 拉取 ImmortalWrt 源码...${NC}"
TAG="v$VERSION"

if [[ -d "$OPENWRT_DIR" ]]; then
    warn "检测到已存在的 openwrt 目录，是否删除重新克隆? [y/N]: "
    read -r reuse
    if [[ "$reuse" =~ ^[Yy]$ ]]; then
        rm -rf "$OPENWRT_DIR"
    else
        cd "$OPENWRT_DIR"
        echo "保留现有源码目录"
    fi
fi

if [[ ! -d "$OPENWRT_DIR" ]]; then
    git clone --depth 1 https://github.com/immortalwrt/immortalwrt "$OPENWRT_DIR"
    cd "$OPENWRT_DIR"
    git fetch origin tag "$TAG" --depth 1
    git checkout "$TAG"
fi
success "源码准备完成"

# 3. 准备配置
echo ""
echo -e "${YELLOW}[3/6] 准备配置文件...${NC}"

cd "$OPENWRT_DIR"

# 执行 before 阶段
if [[ -x "$DIY_SCRIPT" ]]; then
    echo "执行 diy.sh before 阶段..."
    [[ "$USE_OAF" == "true" ]] && OAF_FLAG="--install-oaf" || OAF_FLAG=""
    "$DIY_SCRIPT" -v "$MAIN_VER" -p before -t "$RUN_TYPE" $OAF_FLAG
else
    # 手动处理 feeds
    rm -f feeds.conf feeds.conf.default
    if [[ -f "$SCRIPT_DIR/feeds/$MAIN_VER.conf" ]]; then
        cp "$SCRIPT_DIR/feeds/$MAIN_VER.conf" feeds.conf
    else
        error_exit "缺少 feeds 配置文件: feeds/$MAIN_VER.conf"
    fi
    # 注释 oaf 源
    sed -i '/src-git oaf/d' feeds.conf
fi

./scripts/feeds update -a

# 复制配置文件
if [[ -f "$CONFIG_FILE" ]]; then
    cp "$CONFIG_FILE" .config
else
    error_exit "配置文件不存在: $CONFIG_FILE"
fi
success "配置文件已应用"

# 4. OAF 处理 (仅主路由且选择安装)
echo ""
echo -e "${YELLOW}[4/6] 处理 OAF...${NC}"

if [[ "$USE_OAF" == "true" && "$RUN_TYPE" == "main" ]]; then
    echo "清理旧版 OAF..."
    rm -rf feeds/packages/oaf feeds/packages/luci-app-oaf feeds/packages/open-app-filter 2>/dev/null
    sed -i '/CONFIG_PACKAGE.*oaf/d' .config

    echo "克隆新版 OAF..."
    rm -rf package/OpenAppFilter
    git clone --depth 1 https://github.com/destan19/OpenAppFilter package/OpenAppFilter

    # 复制自定义配置
    if [[ -f "$SCRIPT_DIR/oaf_files/feature.cfg" ]]; then
        cp -f "$SCRIPT_DIR/oaf_files/feature.cfg" package/OpenAppFilter/open-app-filter/files/
    fi
    if [[ -d "$SCRIPT_DIR/oaf_files/app_icons" ]]; then
        cp -rf "$SCRIPT_DIR/oaf_files/app_icons" package/OpenAppFilter/luci-app-oaf/htdocs/luci-static/resources/
    fi

    echo "CONFIG_PACKAGE_luci-app-oaf=y" >> .config
    success "OAF 配置完成"
else
    success "跳过 OAF 安装"
fi

# 5. 执行 after 阶段 (网络配置)
echo ""
echo -e "${YELLOW}[5/6] 生成网络配置...${NC}"

if [[ -x "$DIY_SCRIPT" ]]; then
    echo "执行 diy.sh after 阶段..."
    "$DIY_SCRIPT" \
        -v "$MAIN_VER" -p after -t "$RUN_TYPE" \
        ${ROUTER_IP:+--ip "$ROUTER_IP"} \
        ${GATEWAY_IP:+--gateway "$GATEWAY_IP"} \
        ${PPPOE_USER:+--pppoe-user "$PPPOE_USER"} \
        ${PPPOE_PASS:+--pppoe-pass "$PPPOE_PASS"} \
        --root-pass "$ROOT_PWD"
else
    # 手动生成网络配置
    mkdir -p files/etc/uci-defaults

    if [[ "$RUN_TYPE" == "bypass" ]]; then
        GATEWAY_IP="${GATEWAY_IP:-$DEF_GATEWAY}"
        NETWORK_CONF="uci set network.lan.proto='static'
uci set network.lan.ipaddr='$ROUTER_IP'
uci set network.lan.netmask='255.255.0.0'
uci set network.lan.gateway='$GATEWAY_IP'
uci set network.lan.dns='$GATEWAY_IP 8.8.8.8 223.5.5.5'
uci set network.wan.proto='none'
uci set network.wan6.proto='none'
uci set network.lan6.proto='none'
uci set dhcp.lan.ignore='1'
uci set dhcp.lan6.ignore='1'"
    else
        if [[ -n "$PPPOE_USER" && -n "$PPPOE_PASS" ]]; then
            WAN_CONF="uci set network.wan.proto='pppoe'
uci set network.wan.username='$(_escape_uci "$PPPOE_USER")'
uci set network.wan.password='$(_escape_uci "$PPPOE_PASS")'
uci set network.wan.ipv6='auto'"
        else
            WAN_CONF="uci set network.wan.proto='dhcp'
uci set network.wan6.proto='dhcpv6'"
        fi
        NETWORK_CONF="uci set network.lan.proto='static'
uci set network.lan.ipaddr='$ROUTER_IP'
uci set network.lan.netmask='255.255.0.0'
${WAN_CONF}
uci set network.wan.dns='8.8.8.8 223.5.5.5'
uci -q delete dnsmasq.@dnsmasq[0].server && uci add_list dnsmasq.@dnsmasq[0].server='8.8.8.8' && uci add_list dnsmasq.@dnsmasq[0].server='223.5.5.5'
uci set dhcp.lan.start='11'
uci set dhcp.lan.limit='150'"
    fi

    cat > files/etc/uci-defaults/99-custom-config <<EOF
#!/bin/sh
$NETWORK_CONF
uci set system.@system[0].hostname='Router-${RUN_TYPE}'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci del_list system.ntp.server
uci set system.ntp.enable_server='1'
for server in ntp.aliyun.com ntp.tencent.com ntp.ntsc.ac.cn cn.pool.ntp.org
do
    uci add_list system.ntp.server="\$server"
done
uci commit
/etc/init.d/network reload
/etc/init.d/dnsmasq restart
/etc/init.d/sysntpd restart
/etc/init.d/system reload
exit 0
EOF
    chmod +x files/etc/uci-defaults/99-custom-config

    # Root 密码
    if [[ -n "$ROOT_PWD" ]]; then
        ENCRYPTED_PASS=$(printf '%s' "$ROOT_PWD" | openssl passwd -6 -stdin 2>/dev/null)
        if [[ -n "$ENCRYPTED_PASS" ]]; then
            mkdir -p files/etc
            if [[ -f "package/base-files/files/etc/shadow" ]]; then
                cp "package/base-files/files/etc/shadow" files/etc/shadow 2>/dev/null
            else
                echo 'root::0:0:99999:7:::' > files/etc/shadow
            fi
            awk -F: -v h="$ENCRYPTED_PASS" 'BEGIN{OFS=":"} $1=="root"{$2=h}1' files/etc/shadow > files/etc/shadow.tmp && mv files/etc/shadow.tmp files/etc/shadow
        fi
    fi
fi
success "网络配置生成完成"

# 6. 编译
echo ""
echo -e "${YELLOW}[6/6] 开始编译固件...${NC}"
echo "首次编译可能需要较长时间，请耐心等待..."
echo ""

make defconfig
make download -j$(nproc)
make -j$(nproc) || make -j1 V=s

# 输出结果
echo ""
echo "========================================"
echo -e "${GREEN}编译完成!${NC}"
echo "========================================"
echo "固件位置: $OPENWRT_DIR/bin/targets/x86/64/"
ls -la "$OPENWRT_DIR/bin/targets/x86/64/"*combined*.img.gz 2>/dev/null || true
