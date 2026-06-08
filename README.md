# ImmortalWrt 多版本编译配置

支持 24.10、25.12 及未来多版本的 ImmortalWrt 编译配置，按版本区分 feeds 和配置，自动设置路由 IP。

## 项目结构

```
immortalwrt/
├── feeds/                    # 按版本区分的 feeds 配置
│   ├── 24.10.conf
│   └── 25.12.conf
├── configs/                  # 按版本和配置类型区分的配置文件
│   ├── 24.10-mini.config    # 旁路由配置
│   ├── 24.10-default.config # 主路由配置
│   ├── 24.10-full.config    # 完整配置
│   ├── 25.12-mini.config
│   ├── 25.12-default.config
│   └── 25.12-full.config
├── scripts/                  # 统一的脚本目录
│   └── diy.sh               # 多版本统一 DIY 脚本
└── .github/workflows/       # GitHub Actions 配置
    └── ImmortalWrt x86_64.yml
```

## 配置类型说明

| 配置类型 | 用途 | 主要功能 |
|---------|------|---------|
| **mini** | 旁路由 | 广告过滤 (adblock-fast)、OpenClash、基础网络功能 |
| **default** | 主路由 | Full-NAT、DDNS、UPnP、WOL、多拨、VLAN、IPTV、USB 支持 |
| **full** | 完整功能 | 包含所有功能（mini + default），额外包含 SQM、nlbwmon、watchcat |

## 路由类型

| 路由类型 | 默认 IP | 主机名 |
|---------|---------|--------|
| **main (主路由)** | 10.10.10.1 | Router-Main |
| **bypass (旁路由)** | 10.10.10.99 | Router-Bypass |

## GitHub Actions 使用

1. 进入 Actions 页面，选择 "ImmortalWrt x86_64" workflow
2. 点击 "Run workflow"
3. 选择：
   - 版本（例如 24.10.1）
   - 配置文件：
     - **mini-bypass**：旁路由（广告过滤、OpenClash）
     - **default-main**：主路由（完整网络功能）
     - **full-main**：完整主路由（所有功能）
   - 自定义 IP（可选，留空使用默认: 主路由10.10.10.1 / 旁路由10.10.10.99）
   - PPPoE 账号密码（可选，设置后自动配置 PPPoE 拨号）
   - 安装 OpenAppFilter(OAF)（主路由和旁路由均可选，旁路由需注意与流量转发软件的冲突）
   - 设置 root 密码（可选，不设置则首次登录无需密码）
4. 点击 "Run workflow"

## 本地编译使用

### 准备

```bash
# 克隆源码
git clone https://github.com/immortalwrt/immortalwrt openwrt
cd openwrt

# 检查版本并切换到目标版本
git checkout v24.10.1  # 或其他目标版本
```

### 使用 diy.sh 脚本

```bash
# 第一步：应用 feeds 配置
../scripts/diy.sh -v 24.10 -p before

# 第二步：应用配置文件
# 主路由
cp ../configs/24.10-default.config .config

# 旁路由
cp ../configs/24.10-mini.config .config

# 第三步：更新 feeds
./scripts/feeds update -a

# 第四步：处理 OAF（删除自带的，条件安装官方的）
# 不安装 OAF
../scripts/diy.sh -v 24.10 -p oaf -t main
# 或安装 OAF（主路由和旁路由均可选）
../scripts/diy.sh -v 24.10 -p oaf -t main --install-oaf

# 第五步：安装 feeds
./scripts/feeds install -a

# 第六步：配置系统
# 主路由（使用默认 IP）
../scripts/diy.sh -v 24.10 -p after -t main

# 主路由（设置 PPPoE 和密码）
../scripts/diy.sh -v 24.10 -p after -t main --pppoe-user "your_username" --pppoe-pass "your_password" --root-pass "your_root_password"

# 旁路由（使用自定义 IP 和密码）
../scripts/diy.sh -v 24.10 -p after -t bypass --ip 192.168.1.2 --root-pass "your_root_password"

# 第七步：编译
make defconfig
make -j$(nproc)
```

## 脚本参数说明

```
用法: scripts/diy.sh -v <版本> -p <阶段> [-t <类型>] [选项]

选项:
  -v, --version    版本号 (例如: 24.10, 25.12)
  -p, --phase      执行阶段: before (更新 feeds 前)、oaf (处理 OAF) 或 after (更新 feeds 后)
  -t, --type       路由类型: main (主路由, IP: 10.10.10.1) 或 bypass (旁路由, IP: 10.10.10.99)
  --ip             自定义 IP 地址 (可选，不指定则使用默认)
  --pppoe-user     PPPoE 账号
  --pppoe-pass     PPPoE 密码
  --root-pass      设置 root 密码 (可选，不设置则首次登录无需密码)
  --install-oaf    安装官方 OpenAppFilter (主路由和旁路由均可选，旁路由需注意与流量转发软件的冲突)
```

## OAF (OpenAppFilter) 支持

OAF 是基于 DPI 的应用过滤软件，支持识别 TikTok、YouTube、Facebook 等流行应用。

**启用条件**：
- 主路由：可选安装
- 旁路由：可选安装（可能与流量转发软件产生冲突，请谨慎使用）

**包含的包**：
- `oaf` - 内核模块
- `open-app-filter` - 服务守护进程
- `luci-app-oaf` - LuCI 控制界面

## 添加新版本

如需添加新版本（例如 26.06），请按以下步骤操作：

1. 在 `feeds/` 目录下添加 `26.06.conf`
2. 在 `configs/` 目录下添加对应版本的配置文件
3. 在 GitHub Actions workflow 中添加版本选项
4. 在 README 中更新文档

## 注意事项

- 默认时区已设置为中国时区 (Asia/Shanghai, CST-8)
- 旁路由编译后建议：
  - 关闭 DHCP 服务器
  - 网关指向主路由
  - DNS 指向主路由或公共 DNS
