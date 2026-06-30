# 项目长期记忆 - immortalWrt 编译项目

## 项目概述
- immortalWrt GitHub Action 编译项目
- 核心文件：`scripts/diy.sh`（双阶段配置生成器）、`build.sh`（7步编译流程）
- 生成目标：`files/etc/uci-defaults/99-custom.sh`（主路由/旁路由/完整路由三套配置）

## 网络拓扑
- **双路由拓扑**（main + bypass）：
  - 主路由：10.10.10.1（DHCP/PPPoE 上网，OpenAppFilter，防火墙，DHCP DNS 下发）
  - 旁路由：10.10.10.2（AdGuardHome 全屋去广告 + OpenClash 科学上网）
  - DHCP 下发 DNS：10.10.10.2, 1.1.1.1, 223.5.5.5（旁路宕机自动 fallback）
- **完整路由拓扑**（full）：
  - 单设备集成 OAF + ADGH(53) + OpenClash(redir-host)
  - DNS 链路：客户端 → ADGH(53) → Public DoT；DNS 劫持强制所有客户端走 ADGH
  - ADGH 端口 53（直接面对客户端，可见真实客户端 IP），bind 0.0.0.0 + "::"（IPv6 双栈）
  - dnsmasq port=5453 + listen=127.0.0.1（不对外提供 DNS，仅 DHCP）
  - DNS 劫持：nftables redirect :53（dns-hijack 脚本自动检测：有旁路 IP→排除，无→全劫持）
  - OAF 网关模式 + 防火墙阻断 UDP 443（QUIC 防逃逸）+ 不关闭 forward 链
  - OpenClash redir-host 模式 + 关闭 DNS 劫持（ADGH 占用 53）
  - OpenClash 域名识别靠 sniffer（TLS SNI / HTTP Host），clash config 须启用 sniffer section

## 关键技术决策（已实现）
- dnsmasq server= 列表 + strictorder=1（旁路宕机 fallback；querytimeout/retries 不是有效 UCI option，已删除）
- DNS 劫持：nftables redirect :53（fw4/nftables 后端，iptables-nft 不支持 REDIRECT/DNAT）+ `ip saddr != 旁路IP`（排除旁路由自身出站，防止 AdGuardHome 上游被劫持回环）
- 旁路由 lan.dns 设为外部 DNS（1.1.1.1, 223.5.5.5），不指向主路由（避免环路）；127.0.0.1 在 AdGuardHome 未启动时空端口导致旁路由自身无 DNS。
- dnsmasq 在旁路由让出 :53，监听 5453（AdGuardHome 占用 53）
- 删除 exit 0（uci-defaults 是 source 执行，exit 会杀死父 shell）
- 删除 trap ERR（ash 不支持 bash 扩展）
- uci commit 分 network/dhcp/firewall 三行分开
- firewall zone 动态查找（避免索引硬编码）
- SYSCTL 合并进 99-custom.sh，grep -q 守卫避免重复追加
- `files/` 放在源码根目录会被构建系统自动打包进固件，不需要 CONFIG_FILES（已删除无效配置）
- AdGuardHome YAML 预置在 `files/etc/adguardhome/adguardhome.yaml`（小写目录，静态文件），主路由构建时 diy.sh 删除，旁路由保留；bind_hosts 包含 `0.0.0.0` 和 `"::"`（IPv6 双栈）；**`filters`/`whitelist_filters`/`user_rules` 是顶层配置项，不能嵌套在 `filtering` 下**
- 旁路由 `wan` 和 `wan6` network section 完全删除（不是 proto=none），防止物理 WAN 口干扰
- diy.sh `--bypass-ip` 参数：仅 build.sh 本地编译使用（交互式输入）；workflow 不传此参数，diy.sh 自动回退 `DEF_BYPASS_IP=10.10.10.2`
- DNS 劫持 nft 规则：IPv4 用 `ip saddr != $BYPASS_IP udp dport 53` 排除旁路由；IPv6 用 `ip6 daddr ::/0 udp dport 53`（不排除旁路由，因 AdGuardHome 走 DoT:853；不能用 `meta l4proto` 会导致 `No symbol type information`）
- dns-hijack 脚本路径：`/usr/sbin/dns-hijack`（无 .sh 后缀，静态放在 `files/usr/sbin/dns-hijack`），主路由+完整路由保留（build.sh/workflow 清理在 openwrt 副本上操作），旁路由删除
- AdGuardHome 版本升级：`scripts/upgrade-adgh.sh` 在 feeds update 后、feeds install 前执行，自动获取 GitHub 最新版本并 patch feeds Makefile（PKG_VERSION/PKG_HASH/FRONTEND_HASH）
- OpenClash Meta 核心预装：`scripts/upgrade-openclash-core.sh` 在 diy.sh after 后、files 复制前执行，下载最新 mihomo 二进制到 `files/etc/openclash/core/clash_meta`，旁路由+完整路由构建
- diy.sh 旁路由分支设置 `openclash.config.core_type='Meta'` 和 `openclash.config.core_version='linux-amd64'`
- ADGH UCI 配置（bypass + full 均需）：`adguardhome.config.port='53'` + `redirect='0'`（UCI 会覆盖 YAML 端口，必须显式设置）
- ADGH YAML 过滤规则：旁路由与完整路由模板统一为同一套（Anti-AD-CHN / EasyList China / AdGuard DNS / Anti-AD），避免不同分支行为不一致
- build.sh 与两个 workflow 均加入 `fix_line_endings` / 等价 CRLF 清理，防止 Windows 提交导致路由器 ash 执行失败
- ADGH YAML 模板：bypass 用 `files/etc/adguardhome/adguardhome.yaml`，full 用 `adguardhome-full.yaml`（内容一致：port 53, bind 0.0.0.0+"::"），build.sh/workflow 在 openwrt 副本上覆盖为 `adguardhome.yaml`
- 完整路由需要 dns-hijack（防止客户端自定义 DNS 绕过 ADGH）；dns-hijack 脚本自动检测旁路 IP，无则全劫持
- 完整路由不需要 BYPASS_IP（单设备，无旁路）
- diy.sh 支持 `full` profile type：`--type main/bypass/full`
- 完整路由专用 workflow：`ImmortalWrtBuilder_FullRouter_x86_64.yml`（简化输入，固定 OAF+ADGH+OpenClash）
- OpenClash sniffer 预置：`files/etc/openclash/custom/openclash_custom_overwrite.yaml`（bypass+full 共用），UCI `enable_custom_overwrite='1'` 启用，与订阅配置合并

## 2025-06-27 修复：旁路由无法上网
- 根因：`wan.proto='none'` 导致旁路由无默认路由，`opkg update` 失败
- 修复方案（diy.sh 旁路由分支）：
  1. 删除 `wan` 和 `wan6` network section（`uci -q delete`）
  2. 添加静态默认路由：`uci set network.default_route=route`，interface='lan'，gateway='10.10.10.1'
  3. 旁路由自身 DNS（network.lan.dns）改为 1.1.1.1 / 223.5.5.5，不指向主路由（避免环路）
- AdGuardHome 初始配置预置在 `files/etc/adguardhome/adguardhome.yaml`（小写目录，schema_version: 34，DoT 上游 tls://1.1.1.1 / tls://223.5.5.5）
- AdGuardHome 上游必须用 DoT（端口 853），不能用 plain DNS（端口 53），因为 OpenClash 会劫持旁路由出站 UDP 53 导致上游超时

## 已知潜在问题（待确认）
- set -eu 在 diy.sh（编译机）正常，99-custom.sh 无 set -eu（正确，ash source 执行）

## 已修复的错误清单
| 错误 | 修复 |
|------|------|
| trap ERR（ash不支持）| 删除 |
| exit 0（source执行杀父shell）| 删除 |
| uci commit network dhcp（只commit network）| 拆为两行 |
| querytimeout='2000'（单位秒）| 改为 '2' |
| @zone[lan]/@zone[wan] 硬编码索引 | 动态查找 zone name |
| DNAT --to-destination 127.0.0.1:53 | 改为 REDIRECT --to-ports 53 |
| 旁路由 lan.dns=127.0.0.1 → AdGuardHome 未启动时空端口 | 改为 10.10.10.1（主路由 dnsmasq 转发至 AdGuardHome，排除规则已防止环路）|
| SYSCTL 独立文件残留 | 合并进99-custom.sh |
| noresolv=1 阻断 fallback | 删除 |
| DNS 劫持无旁路由白名单 → 死循环 | 添加 `! -s IP` exclusion |
| network.lan6 空 interface 残留 | 删掉 `set lan6.proto=static`，只保留 delete |
| build.sh 缺少 CONFIG_FILES 配置 | 添加 `echo 'CONFIG_FILES=$(TOPDIR)/files'` 到 .config |
| files/etc/uci-defaults/99-custom.sh 陈旧输出 | 删除（diy.sh 每次构建重新生成）|
| heredoc 嵌套变量展开：`$rule` 被 `set -eu` 报 unbound | `$rule` → `\$rule`（外层 <<EOT 展开时会误吞内层 `'HIJACK'` heredoc 中的 `$`）|
| 旁路由 wan.proto=none 无默认路由，opkg 无法更新 | 删除 wan.proto=none，添加 static default_route；lan.dns 改为外部 DNS |
| 主路由 listen_address=127.0.0.1 → dnsmasq 不监听 LAN，全屋 DNS 瘫痪 | 删除主路由 listen_address（仅旁路由保留） |
| sequential_ip 写在 dhcp.lan（pool section）不生效 | 移到 dhcp.@dnsmasq[0]（全局 dnsmasq section） |
| AdGuardHome.yaml heredoc 嵌套乱码 | 改为独立文件 files/etc/adguardhome/adguardhome.yaml |
| diy.sh UTF-8 BOM 导致 shebang 报错 | sed 移除 BOM |
| firewall include 每次启动累加 | 添加前先按 path 查找删除已有 include |
| DNS 劫持清理 grep 不精确 | 改为 `grep "dport 53.*REDIRECT --to-ports 53"` |
| 主路由缺 LAN→WAN forwarding 规则 | 添加 firewall forwarding section |
| 旁路由 dnsmasq 禁用会影响 OpenClash 增强模式 | 改为监听 127.0.0.1:5453（保留给 OpenClash，不对外服务） |
| AdGuardHome YAML filtering 嵌套结构错误（`filters`/`whitelist_filters`/`user_rules` 嵌套在 `filtering:` 下）| 改为顶层独立配置项（官方文档明确 `filters` 是顶层项）；`protection_enabled`/`filtering_enabled`/`blocked_services` 等从 `dns:` 移到 `filtering:` |
| dns-hijack grep 用 ERE `+` 但无 `-E` flag | 简化为 `grep -m1 'list server'`（BRE 兼容） |
| AdGuardHome bind_hosts 缺 IPv6 | 补充 `"::"`（IPv6 DNS 劫持需要 AdGuardHome 监听 IPv6） |
| nft add chain `{}` 未引号 → shell 语法错误 | 加单引号 `'{ type nat hook prerouting priority -100; }'` |
| firewall include reload='1' → fw4 不支持 | 删除 reload 选项 |
| nft 规则 `counter` 位置导致加载失败 | 删除 counter |
| AdGuardHome 上游 UDP 53 被 OpenClash 劫持 → i/o timeout | upstream_dns 改用 DoT `tls://1.1.1.1` / `tls://223.5.5.5`（端口 853 绕过劫持） |
| DNS 劫持仅覆盖 IPv4，IPv6 DNS 可绕过 AdGuardHome | IPv4 用 `ip saddr != $BYPASS_IP udp dport 53` 排除旁路由；IPv6 用 `ip6 daddr ::/0 udp dport 53`（`meta l4proto` 导致 `No symbol type information`，已修复） |
| 主路由 WAN_FW.forward='ACCEPT' 不必要且有安全风险 | 删除（WAN forward 默认 DROP 是正确姿态，DDNS 走 output 不受影响） |
| firewall include 缺 enabled='1' | 补上 `uci set firewall.dns_hijack_include.enabled='1'` |
| `option dns_redirect '1'` 导致 dnsmasq init 注入 nft 规则 UDP 53→5453，旁路由 AdGuardHome 收不到外部 DNS 查询 | diy.sh 主路由+旁路由+完整路由分支均加 `uci set dhcp.@dnsmasq[0].dns_redirect='0'` |
| upgrade-adgh.sh `cut -d: -f3` 对 `PKG_VERSION:=value` 提取为空 | 改为 `sed -n 's/^PKG_VERSION:=//p'`；补充 FRONTEND_PKG_VERSION patch |
| upgrade-openclash-core.sh 注释"仅旁路由"过时 + tar `-o` 冗余 | 注释改为"旁路由+完整路由"；`tar zxvfo` → `tar zxf` |
| workflow 文件名含空格 `ImmortalWrtBuilder_ x86_64.yml` | 重命名为 `ImmortalWrtBuilder_x86_64.yml` |
| build.sh fix_line_endings 未覆盖 files/ 脚本（CRLF 在 ash 上报错） | 扩展覆盖 dns-hijack、update_aliyun_com.sh、adguardhome.yaml、adguardhome-full.yaml |
| diy.sh 文件清理在源树上操作 → 本地编译后源树被破坏（需 git checkout 恢复） | 文件清理（rm/cp）从 diy.sh 移至 build.sh/workflow，在 openwrt 副本上操作，源树不再被破坏 |
| dnsmasq server list 只有首条 del_list+add_list，其余直接 add_list（潜在重复） | 改为 `uci delete dhcp.@dnsmasq[0].server` 整体重建 + add_list（与 network.dns 模式一致） |
| workflow cp 源路径带尾斜杠 `$GITHUB_WORKSPACE/files/`（语义不清晰） | 去除尾斜杠，与 build.sh 统一 |
| bypass 分支缺少 ADGH UCI `port='53'` + `redirect='0'`，UCI 默认值覆盖 YAML | 补齐（与 full 分支一致） |
| hotplug 脚本 `sleep 10` 阻塞 hotplug 链 | 改为 `(sleep 10; ...) &` 后台执行 |
| hotplug 脚本缺 `adguardhome.yaml` 存在性检查，主路由误触发 | 添加 `[ -f ... ] || exit 0` |
| `find -type f -executable` 对 Windows git 创建的文件不生效（无 x 位） | 改为按路径/扩展名匹配 `\( -path "*/sbin/*" -o -path "*/hotplug.d/*" -o -path "*/uci-defaults/*" -o -name "*.sh" \)` |
| adguardhome.yaml (bypass) bootstraps 顺序与 upstream_dns 不一致 | 统一为 `[223.5.5.5, 1.1.1.1]` |
