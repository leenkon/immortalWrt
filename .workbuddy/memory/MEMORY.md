# 项目长期记忆 - immortalWrt 编译项目

## 项目概述
- GitHub Actions 编译 immortalWrt x86_64 固件（主 workflow: `.github/workflows/ImmortalWrtBuilder_x86_64.yml`，本地: `build.sh`）
- 双阶段生成器 `scripts/diy.sh`：before=处理 feeds/golang；after=生成 `files/etc/uci-defaults/99-custom.sh`
- profile type：`main`(主路由) / `bypass`(旁路由) / `full`(完整路由)
- workflow profile 选项：`default-main` / `mini-bypass` / `full-main` / `full-noadgh`（full 不带 AdGuardHome）
- `full-noadgh`：`--type full --no-adgh`，OAF+OpenClash 但无 ADGH；dnsmasq 占 53，OC 用 `enable_redirect_dns='1'` 自行劫持 DNS；不跑自定义 dns-hijack、不装 adguardhome 包/文件
- noadgh 的 ADGH 剔除**双层机制**：① **构建期（主）**：build.sh/workflow 在 `cp .config` 后、`make defconfig` 前对 `noadgh` 执行 `sed -i '/CONFIG_PACKAGE_.*adguardhome/d' .config`，剔除 adguardhome/luci-app-adguardhome/i18n 三行；同时 `WITH_ADGH=false`（不再跑 `upgrade-adgh.sh`，省编译/升级）② **首启兜底（防御）**：`99-custom.sh` 仍保留按版本分流的移除逻辑（25.x `apk del` / 24.x `opkg remove --force-remove`），仅当固件因依赖/配置遗漏仍残留 ADGH 时静默移除，避免其抢占 :53 与 noadgh 的 dnsmasq 冲突。正常构建此块为 no-op。
- 设计变更（2026-07-12）：**推翻此前“不修改 .config”原则**——noadgh 改为构建期从 .config 剔除 ADGH（可行：所有 full/mini config 的 ADGH 包均为 `=y` 形态，sed 删除精确且无副作用；普通 full 不受影响，因其 `NO_ADGH!=true`）。此前首启移除方案已降级为防御性保险。

## 网络拓扑与 DNS
- **main**(10.10.10.1)：DHCP 下发 DNS=旁路IP+公网；dnsmasq:53；dns-hijack 排除旁路IP
- **bypass**(10.10.10.2)：删 wan/wan6+静态默认路由；ADGH:53+OC(redir-host,关劫持)；dnsmasq→5453 让位；自身 DNS 用公网防环路；删 dns-hijack
- **full**(10.10.10.1)：OAF+ADGH:53+OC(redir-host)；dnsmasq:5453；ADGH 上游 DoT:853 绕开 OC 对 53 劫持；dns-hijack 全劫持

## diy.sh / build 约定
- `--type` main/bypass/full；`--no-adgh` 仅 full 生效；`--bypass-ip` 仅本地交互，workflow 不传→回退 10.10.10.2
- 文件清理在 openwrt 副本上做（build.sh/workflow），源树不被破坏
- ADGH YAML 预置 `files/etc/adguardhome/adguardhome.yaml`(bind 0.0.0.0+"::")；OC meta 核心由 `upgrade-openclash-core.sh` 下到 `files/etc/openclash/core/clash_meta`；OC sniffer 预置 `files/etc/openclash/custom/openclash_custom_overwrite.yaml`(enable_custom_overwrite=1)
- `upgrade-adgh.sh` 在 feeds update 后、install 前跑（patch Makefile 版本/hash）；仅 bypass/full（非 noadgh）需要
- fix_line_endings 覆盖脚本+yaml（CRLF 在路由器 ash 报错）

## 关键坑（避免回归）
- ash 不支持 `trap ERR`/`exit 0`(source 杀父 shell)/99-custom.sh 用 set -eu
- DNS 劫持用 nftables `REDIRECT --to-ports 53`（iptables-nft 不支持）；IPv4 `ip saddr != 旁路IP` 排除旁路由；IPv6 `ip6 daddr ::/0`；禁用 `meta l4proto`(No symbol) 与 `counter`(加载失败)
- ADGH 上游只用国内 DoT（`tls://223.5.5.5` / `tls://223.6.6.6`）+ 兜底 `udp://223.5.5.5`；**严禁境外解析器**（原 `94.140.14.14` / `1.1.1.1` 在大陆常超时/被阻断，是 full 断流头号嫌疑，已移）。DoT 走 853 且 dns-hijack 只匹配 dport 53，不会回环
- `dns_redirect='0'` 主/旁/全分支都要（防 dnsmasq init 注入 53→5453 干扰 ADGH）
- UCI `adguardhome.config.port='53'`+`redirect='0'` 必须设（UCI 覆盖 YAML）
- ADGH YAML：`filters`/`whitelist_filters`/`user_rules` 顶层项，不嵌套 `filtering:`
- nft chain `{}` 须单引号；firewall include 无 reload、需 enabled='1'
- dnsmasq server 重建用 `delete`+`add_list`（防重复）
- diy.sh 的 `<<EOT`（未加引号）heredoc 会在**生成期**展开 `$(...)`/`$var`；想在首启才执行的命令（如 `opkg list-installed` 兜底移除）必须把 `$` 转义为 `\$`，否则被提前展开成空，到路由器上失效
- OC `enable_redirect_dns`：有 ADGH 时 '0'（ADGH 占 53），无 ADGH 时 '1'（OC 自行劫持）

## full 分支断流排查 (2026-07-13)
- 现象：编译出的 full 固件跑一段后出现间歇性断流；main 分支稳定（ADGH 在旁路盒、主路由只转发）。
- 已落地修复（代码级、低风险）：
  1. `adguardhome.yaml` 上游去掉境外解析器，改国内 DoT（223.5.5.5/223.6.6.6）+ 兜底 udp；`cache_size` 4194304→500000（防 OOM）。
  2. `diy.sh` 末尾注入 `net.netfilter.nf_conntrack_max=262144`（防 DNS 重定向+OAF 打满 conntrack）。
- 仍需上机验证的嫌疑（按优先级）：① ADGH 上游超时/OOM（看 logread OOM、free、ADGH 日志）② conntrack 满（`nf_conntrack_count` vs `max`）③ **Block-QUIC 规则（full 独有，REJECT udp/443）** 导致 QUIC 回退抖动 → 临时删此规则看是否消失 ④ OAF 网关模式 CPU/稳定性 → 临时禁 OAF 验证 ⑤ flow_offloading 与重定向偶发冲突（非差异点）。
- 诊断命令见对话；结论：断流大概率是 ADGH 配置（境外上游+超大缓存）所致，非网络拓扑本身。

## 已知待确认
- （无）
