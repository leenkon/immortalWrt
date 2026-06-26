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
- DNS 劫持：iptables REDIRECT --to-ports 53 + `! -s 旁路IP ! -d 旁路IP`（防止 AdGuardHome 上游查询死循环 + 客户端直连旁路优化）
- 旁路由 lan.dns 设为 127.0.0.1（走本机 AdGuardHome，避免 DNS 环路）
- dnsmasq 在旁路由让出 :53，监听 5453（AdGuardHome 占用 53）
- 删除 exit 0（uci-defaults 是 source 执行，exit 会杀死父 shell）
- 删除 trap ERR（ash 不支持 bash 扩展）
- uci commit 分 network/dhcp/firewall 三行分开
- firewall zone 动态查找（避免索引硬编码）
- SYSCTL 合并进 99-custom.sh，grep -q 守卫避免重复追加
- build.sh 与 GitHub Actions 均需 `CONFIG_FILES=$(TOPDIR)/files` 确保 files/ 覆盖层打包进固件

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
| 旁路由 lan.dns 设主路由 IP → DNS 环路 | 改为 127.0.0.1 |
| SYSCTL 独立文件残留 | 合并进99-custom.sh |
| noresolv=1 阻断 fallback | 删除 |
| DNS 劫持无旁路由白名单 → 死循环 | 添加 `! -s IP ! -d IP` exclusion |
| network.lan6 空 interface 残留 | 删掉 `set lan6.proto=static`，只保留 delete |
| build.sh 缺少 CONFIG_FILES 配置 | 添加 `echo 'CONFIG_FILES=$(TOPDIR)/files'` 到 .config |
| files/etc/uci-defaults/99-custom.sh 陈旧输出 | 删除（diy.sh 每次构建重新生成）|
