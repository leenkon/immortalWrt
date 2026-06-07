# ImmortalWrt x86-64 多版本编译模板

基于 GitHub Actions 的 ImmortalWrt x86-64 多版本固件编译模板，支持 24.10、25.12 及未来版本的灵活配置。

## 特性

- ✅ 专为 x86-64 架构优化
- ✅ 支持多版本 ImmortalWrt 编译（24.10、25.12）
- ✅ 按版本独立配置 feeds 源
- ✅ 三种配置类型可选：mini（旁路由）、default（主路由）、full（完整版）
- ✅ 统一存储空间：960MB 根分区 + 64MB 内核分区
- ✅ 统一的 DIY 脚本，便于维护
- ✅ 使用 mold 链接器加速编译
- ✅ O2 优化级别，平衡性能与体积
- ✅ 自动发布固件到 GitHub Release

## 配置说明

### 三种配置类型

| 配置类型 | 用途 | 主要功能 |
|---------|------|---------|
| **mini（旁路由）** | 作为旁路由/网关使用 | 广告过滤、OpenClash、基础网络功能 |
| **default（主路由）** | 作为主路由使用 | Full-NAT、DDNS、UPnP、WOL、多拨、VLAN、IPTV、USB 支持 |
| **full（完整）** | 功能最完整的版本 | 包含所有功能，更多网卡驱动、文件系统支持等 |

### mini 配置（旁路由）详细功能

- ✅ 广告过滤 (adblock-fast)
- ✅ OpenClash
- ✅ Argon 主题
- ✅ 中文语言
- ✅ 常用网卡驱动 (e1000/e1000e/igb/igc/vmxnet3/r8169)
- ✅ dnsmasq（精简版）

### default 配置（主路由）详细功能

- ✅ Full-NAT
- ✅ DDNS 动态域名 (含阿里云/Cloudflare)
- ✅ UPnP 端口映射
- ✅ WOL 网络唤醒
- ✅ 多拨负载均衡 (mwan3)
- ✅ VLAN 支持
- ✅ IPTV 支持 (udpxy)
- ✅ USB 支持
- ✅ VFAT/F2FS 文件系统
- ✅ Argon 主题
- ✅ 中文语言
- ✅ dnsmasq-full（完整版）

### 所有配置共同特性

- 内核版本：Linux 6.6
- 目标架构：x86-64
- 根分区大小：960MB
- 内核分区大小：64MB
- CPU 优化类型：x86-64
- 编译优化：-O2
- 链接器：mold
- IPv6 支持

## 使用说明

1. 点击右上角 **Use this template** 创建新仓库
2. 根据需要修改 `feeds/` 目录下的对应版本 feeds 配置
3. 自定义 `configs/` 目录下的配置文件（可选）
4. 进入 Actions 页面，选择 `ImmortalWrt x86_64`
5. 选择版本、配置类型，点击 `Run workflow` 开始编译

## 主路由与旁路由使用建议

### 主路由（使用 default 配置）

主路由负责：
- PPPoE 拨号上网
- DHCP 服务器
- NAT 转发
- 防火墙

### 旁路由（使用 mini 配置）

旁路由负责：
- 广告过滤
- 科学上网
- 其他增强功能

旁路由配置要点：
1. 关闭 DHCP 服务器
2. 网关指向主路由
3. DNS 指向主路由或公共 DNS

## 目录结构

```
immortalWrt-main/
├── feeds/                    # 按版本区分的 feeds 配置
│   ├── 24.10.conf
│   └── 25.12.conf
├── configs/                  # 按版本和配置类型区分的配置文件
│   ├── 24.10-mini.config     # 旁路由配置
│   ├── 24.10-default.config  # 主路由配置
│   ├── 24.10-full.config     # 完整配置
│   ├── 25.12-mini.config
│   ├── 25.12-default.config
│   └── 25.12-full.config
├── scripts/                  # 脚本目录
│   └── diy.sh               # 统一 DIY 脚本
├── .github/workflows/       # GitHub Actions 配置
├── LICENSE
└── README.md
```

##### DIY 脚本使用

> **重要提示**：如果需要启用 OAF (OpenAppFilter)，必须在编译时启用 `--custom-feeds` 选项！

### 基本用法

```bash
# 更新 feeds 前（应用对应版本的 feeds 配置）
./scripts/diy.sh -v 24.10 -p before [--custom-feeds]

# 更新 feeds 后（修改默认配置，设置路由 IP）
./scripts/diy.sh -v 24.10 -p after -t main
```

### 路由 IP 地址设置

脚本支持在编译时自动设置路由 IP 地址：

| 路由类型 | 参数 | 默认 IP 地址 | 主机名 |
|---------|------|-------------|--------|
| 主路由 | `-t main` | `10.10.10.1` | Router-Main |
| 旁路由 | `-t bypass` | `10.10.10.99` | Router-Bypass |

### 使用示例

```bash
# 编译主路由固件（24.10 版本）
./scripts/diy.sh -v 24.10 -p before
./scripts/diy.sh -v 24.10 -p after -t main

# 编译旁路由固件（24.10 版本，不含 OAF）
./scripts/diy.sh -v 24.10 -p before
./scripts/diy.sh -v 24.10 -p after -t bypass

# 编译旁路由固件（25.12 版本，含 OAF 应用过滤）
./scripts/diy.sh -v 25.12 -p before --custom-feeds
./scripts/diy.sh -v 25.12 -p after -t bypass
```

### OAF (OpenAppFilter) 支持

OAF 是基于 DPI 的应用过滤软件，支持识别 TikTok、YouTube、Facebook 等流行应用。

**启用条件**：
- 使用 `--custom-feeds` 选项
- 编译 mini 配置（旁路由）

**包含的包**：
- `oaf` - 内核模块
- `open-app-filter` - 服务守护进程
- `luci-app-oaf` - LuCI 控制界面

## 添加新版本

1. 在 `feeds/` 目录下创建 `x.y.conf`
2. 在 `configs/` 目录下创建三个配置文件：`x.y-mini.config`、`x.y-default.config`、`x.y-full.config`
3. 在 `.github/workflows/ImmortalWrt x86_64.yml` 中添加新版本选项

## 致谢

- [ImmortalWrt](https://github.com/immortalwrt/immortalwrt)
- [GitHub Actions](https://github.com/features/actions)
- [P3TERX/Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt)

## License

[MIT](LICENSE)
