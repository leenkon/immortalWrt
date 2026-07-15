# 项目长期记忆 - immortalWrt 编译项目

## 项目概述
- GitHub Actions 编译 immortalWrt x86_64 固件（主 workflow: `.github/workflows/ImmortalWrtBuilder_x86_64.yml`，本地: `build.sh`）
- 双阶段生成器 `scripts/diy.sh`：before=处理 feeds/golang；after=**重新生成** `files/etc/uci-defaults/99-custom.sh`（先 `rm -f` 再写，故该路径下的静态 99-custom.sh 是死文件，已被删除）
- profile type：`main`(主路由) / `bypass`(旁路由) / `full`(完整路由)
- workflow profile 选项：`default-main` / `mini-bypass` / `full-main` / `full-noadgh`（full 不带 AdGuardHome）
- `full-noadgh`：`--type full --no-adgh`，OAF+OpenClash 但无 ADGH；dnsmasq 占 53，OC 用 `enable_redirect_dns='1'` 自行劫持 DNS；不跑自定义 dns-hijack、不装 adguardhome 包/文件

## noadgh 的 ADGH 剔除机制
- **单一构建期机制（权威）**：build.sh/workflow 在 `cp .config` 后、`make defconfig` 前对 `noadgh` 执行 `sed -i '/CONFIG_PACKAGE_.*adguardhome/d' .config`，剔除 adguardhome/luci-app-adguardhome/i18n 三行；同时 `WITH_ADGH=false`（不再跑 `upgrade-adgh.sh`，省编译/升级）。
- 设计变更（2026-07-12）：**推翻此前“不修改 .config”原则**——noadgh 改为构建期从 .config 剔除 ADGH（可行：所有 full/mini config 的 ADGH 包均为 `=y` 形态，sed 删除精确且无副作用；普通 full 不受影响，因其 `NO_ADGH!=true`）。首启 apk/opkg 移除块已于 2026-07-13 复审清理删除（与构建期 sed 双重来源、冗余），构建期 sed 现为唯一权威机制。

## 网络拓扑与 DNS
- **main**(10.10.10.1)：DHCP 下发 DNS=旁路IP+公网；dnsmasq:53；dns-hijack 排除旁路IP
- **bypass**(10.10.10.2)：删 wan/wan6+静态默认路由；ADGH:53+OC(redir-host,关劫持)；dnsmasq→5453 让位；自身 DNS 用公网防环路；删 dns-hijack
- **full**(10.10.10.1)：OAF+ADGH:53+OC(redir-host)；dnsmasq:5453；**ADGH 上游→OC DNS(`[/./]127.0.0.1:7874`) 使 OC 域名分流生效；不再用 nftables 端口劫持(dns-hijack)，dns-hijack 仅 main 保留**

## diy.sh / build 约定
- `--type` main/bypass/full；`--no-adgh` 仅 full 生效；`--bypass-ip` 仅本地交互，workflow 不传→回退 10.10.10.2
- 文件清理在 openwrt 副本上做（build.sh/workflow），源树不被破坏
- ADGH YAML 预置 `files/etc/adguardhome/adguardhome.yaml`(bind 0.0.0.0+"::")；OC meta 核心由 `upgrade-openclash-core.sh` 下到 `files/etc/openclash/core/clash_meta`；OC sniffer 预置 `files/etc/openclash/custom/openclash_custom_overwrite.yaml`(enable_custom_overwrite=1)
- `upgrade-adgh.sh` 在 feeds update 后、install 前跑（patch Makefile 版本/hash）；仅 bypass/full（非 noadgh）需要
- fix_line_endings 覆盖脚本+yaml（CRLF 在路由器 ash 报错）
- 公共配置块变量：`LAN_WAN_COMMON_BLK` / `ADGH_BLK`(ADGH:53+redirect=0) / `OC_CORE_BLK`(OC公共) / `LAN_FORWARD_BLK` / `DNS_HIJACK_BLK`(仅 main) / `DHCP_COMMON_BLK` / `WAN_BLK`(full/main) / `IP_FORWARD_LN`。⚠️ 定义名与使用名必须一致：`ADGH_BLK` 曾在定义处误写为 `ADGH_OC_BLK` 致 bypass/full 丢失 ADGH UCI 配置，已于 2026-07-15 修正。

## 关键坑（避免回归）
- ash 不支持 `trap ERR`/`exit 0`(source 杀父 shell)/99-custom.sh 用 set -eu
- DNS 劫持用 nftables `REDIRECT --to-ports 53`（iptables-nft 不支持）；IPv4 `ip saddr != 旁路IP` 排除旁路由；IPv6 `ip6 daddr ::/0`；禁用 `meta l4proto`(No symbol) 与 `counter`(加载失败)
- ADGH 上游（`adguardhome.yaml`）用 **domain-specific 形式 `[/./]127.0.0.1:7874`**（OC DNS，redir-host 默认端口），把全部常规查询路由到 OC，使 OC 在解析期拿到域名、域名分流**真正生效**。裸 `127.0.0.1` 会被 ADGH 视为私有上游、仅作 PTR，必须用 `[/./]` 形式绕过。**兜底 `fallback_dns`=国内 DoT**（`tls://223.5.5.5`/`tls://223.6.6.6`），OC 不可达时才启用；`parallel_requests: false` 防止国内上游抢答绕过 OC。**严禁境外解析器**（原 `94.140.14.14`/`1.1.1.1` 已移）。ADGH→OC 单向链，无回环。
- `dns_redirect='0'` 主/旁/全分支都要（防 dnsmasq init 注入 53→5453 干扰 ADGH）
- UCI `adguardhome.config.port='53'`+`redirect='0'` 必须设（UCI 覆盖 YAML）
- ADGH YAML：`filters`/`whitelist_filters`/`user_rules` 顶层项，不嵌套 `filtering:`
- nft chain `{}` 须单引号；firewall include 无 reload、需 enabled='1'
- dnsmasq server 重建用 `delete`+`add_list`（防重复）
- diy.sh 的 `<<EOT`（未加引号）heredoc 会在**生成期**展开 `$(...)`/`$var`；想在首启才执行的命令（如 `opkg list-installed` 兜底移除）必须把 `$` 转义为 `\$`，否则被提前展开成空，到路由器上失效
- OC `enable_redirect_dns`：有 ADGH 时 '0'（ADGH 占 53），无 ADGH 时 '1'（OC 自行劫持）

## 跨分支断流排查（核心结论 2026-07-14，2026-07-15 落地到 diy.sh）
- 关键转折：用户反馈 main 分支（无 ADGH/OC/OAF）也断流 → 根因**不在分支差异组件**，而在**所有分支共享的底座配置**。据此重查，定位跨分支高危项并全部加固，已写入 diy.sh 公共尾部（作用于全部 4 档）：
  1. **关闭硬件流卸载** `flow_offloading_hw='0'`（保留软件流卸载 `flow_offloading='1'`）。硬件 offload 在多数 x86 网卡/虚拟化环境不稳定，会偶发丢包、并与 nft DNS 重定向冲突——是跨分支断流头号嫌疑。代价：大带宽 NAT 吞吐略降。
  2. **conntrack 超时**：sysctl 设 `nf_conntrack_max=262144` + `nf_conntrack_tcp_timeout_established=3600` + `nf_conntrack_udp_timeout=60`，防连接数暴涨时新连接被丢弃（卡死数秒后恢复）。
  3. **x86 CPU 性能调度**：`files/etc/init.d/cpufreq-perf`（START=89，定义 `start()` 写 `scaling_governor=performance`；非 procd，故必须用 `start()` 而非 `start_service()`），diy.sh 公共尾部首启 `start`+`enable`。避免降频/深空闲致网络延迟抖动。
  4. **WAN MSS 钳制**：公共尾部对存在的 wan 区设 `mtu_fix='1'`，防 PPPoE/大包 MTU 黑洞间歇断流。
- full/bypass 专属加固（`adguardhome.yaml`）：`querylog.file_enabled=false`（ADGH 数据目录在 overlay 闪存，长期写盘会撑爆分区致系统不稳）；`upstream_timeout: 3s`（单上游超时拖垮整条解析的兜底）。
- 仍待上机验证/取舍的嫌疑：① 若仍断流，进一步关软件流卸载 `flow_offloading='0'` ② NIC 卸载(ethtool GRO/LRO/TSO)、IRQ 均衡、virtio(若为 VM) ③ IPv6 DNS 下发（确认 RA/dhcpv6 只下发路由自身 IPv6，避免客户端直连 ISP IPv6 DNS 绕过 DNS 链）④ Block-QUIC（full 独有）⑤ OAF 网关模式 CPU。
- 诊断命令：ping 长测看 gaps；`cat /proc/sys/net/netfilter/nf_conntrack_count` vs `...nf_conntrack_max`；`logread | grep -iE 'offload|conntrack|dns|adguard|openclash|oaf'`；`cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor`；`ping -M do -s 1472 223.5.5.5`（PPPoE 用 1464）测 MTU 黑洞。

## AdGuardHome 编译关键约束（feeds golang 与 Go 版本耦合）
- **根因**：AdGuardHome >=0.107.70 全部要求 Go >= 1.25（0.107.70→Go1.25.5、0.107.77→Go1.26.3、0.107.78→Go1.26.5）。OpenWrt **25.12** feeds `lang/golang` 已自带 **Go 1.26.4**（按大版本拆包 `golang1.26`，`golang-values.mk` 的 `GO_DEFAULT_VERSION:=1.26`，`golang` 虚包→`golang1.26/host`，adguardhome 依赖 `golang/host`）；**24.10** 仅单一 `golang` 包 **1.23.12**，bootstrap 链(go1.4/1.17/1.20)过旧无法 bootstrap Go 1.26。
- **机制（2026-07-15 强制升级）**：`upgrade-adgh.sh` 默认不覆盖 feeds 自带版本；显式 `ADGH_VER`（版本号/`latest`）时才升级。升级时读目标版本 go.mod 的 `go X.Y` 作为 `req_go`，**调用 `scripts/upgrade-golang.sh --require-go "$req_go"` 强制把 feeds `lang/golang` 升到该 Go 版本**（25.12 改 `golang1.26/Makefile` 的 `GO_VERSION_PATCH`+`PKG_HASH`；当前→1.26.5 即满足 0.107.78），包名/大版本不变、依赖链自动跟随。下载 tarball 校验 gzip magic(`1f8b`) 防 404 HTML 错算 hash。
- **24.10 限制**：大版本不匹配时 `upgrade-golang.sh` 明确 ABORT 并指引改用 25.12（24.10 无法编最新 ADGH）。
- build.sh / workflow 均透传 `ADGH_VER`（workflow `adgh_version` 输入，留空=feeds 自带版；25.12 填 `latest` 即自动升 golang+ADGH 编最新）。
- 注：用更新 ADGH 必须喂够网络（下载 go<ver>.src.tar.gz 与 ADGH 源码/前端）；否则 golang 升级失败会 ABORT 编译。

## 已知待确认
- （无）
