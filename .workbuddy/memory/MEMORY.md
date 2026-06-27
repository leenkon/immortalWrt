# 项目长期记忆 - immortalWrt 编译项目

## 项目概述
- immortalWrt GitHub Action 编译项目
- 核心文件：`scripts/diy.sh`（双阶段配置生成器）、`build.sh`（7步编译流程）
- 生成目标：`files/etc/uci-defaults/99-custom.sh`（主路由/旁路由两套配置）

## 网络拓扑
- 主路由：10.10.10.1（DHCP/PPPoE 上网，OpenAppFilter，防火墙，DHCP DNS 下发）
- 旁路由：10.10.10.2（AdGuardHome 全屋去广告 + OpenClash 科学上网）
- DHCP 下发 DNS：10.10.10.2, 1.1.1.1, 223.5.5.5（旁路宕机自动 fallback）

## 关键技术决策（已实现）
- dnsmasq server= 列表 + strictorder=1 + querytimeout=2 + retries=1（旁路宕机 fallback）
- DNS 劫持：iptables REDIRECT --to-ports 53 + `! -s 旁路IP`（仅排除旁路由自身出站，防止 AdGuardHome 上游被劫持回环）
- 旁路由 lan.dns 设为外部 DNS（1.1.1.1, 223.5.5.5），不指向主路由（避免环路）；127.0.0.1 在 AdGuardHome 未启动时空端口导致旁路由自身无 DNS。
- dnsmasq 在旁路由让出 :53，监听 5453（AdGuardHome 占用 53）
- 删除 exit 0（uci-defaults 是 source 执行，exit 会杀死父 shell）
- 删除 trap ERR（ash 不支持 bash 扩展）
- uci commit 分 network/dhcp/firewall 三行分开
- firewall zone 动态查找（避免索引硬编码）
- SYSCTL 合并进 99-custom.sh，grep -q 守卫避免重复追加
- build.sh 与 GitHub Actions 均需 `CONFIG_FILES=$(TOPDIR)/files` 确保 files/ 覆盖层打包进固件

## 2025-06-27 修复：旁路由无法上网
- 根因：`wan.proto='none'` 导致旁路由无默认路由，`opkg update` 失败
- 修复方案（diy.sh 旁路由分支）：
  1. 删除 `uci set network.wan.proto='none'` 和 `wan6.proto='none'`
  2. 添加静态默认路由：`uci set network.default_route=route`，interface='lan'，gateway='10.10.10.1'
  3. 旁路由自身 DNS（network.lan.dns）改为 1.1.1.1 / 223.5.5.5，不指向主路由（避免环路）
- AdGuardHome 初始配置已通过 `files/etc/AdGuardHome/AdGuardHome.yaml` 预置（upstream_dns: 1.1.1.1, 223.5.5.5），无需手动配置

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
| AdGuardHome.yaml heredoc 嵌套乱码 | 改为独立文件 files/etc/AdGuardHome/AdGuardHome.yaml |
| diy.sh UTF-8 BOM 导致 shebang 报错 | sed 移除 BOM |
| firewall include 每次启动累加 | 添加前先按 path 查找删除已有 include |
| DNS 劫持清理 grep 不精确 | 改为 `grep "dport 53.*REDIRECT --to-ports 53"` |
| 主路由缺 LAN→WAN forwarding 规则 | 添加 firewall forwarding section |
| 旁路由 dnsmasq 禁用会影响 OpenClash 增强模式 | 改为监听 127.0.0.1:5453（保留给 OpenClash，不对外服务） |
