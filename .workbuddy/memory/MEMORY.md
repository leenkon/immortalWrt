# 项目长期记忆 - immortalWrt 编译项目

## 项目概述
- GitHub Actions 编译 immortalWrt x86_64 固件（workflow: `.github/workflows/ImmortalWrtBuilder_x86_64.yml`；本地: `build.sh`）
- 双阶段生成器 `scripts/diy.sh`：before=处理 feeds；after=重新生成 `files/etc/uci-defaults/99-custom.sh`（先 rm 再写，故静态 99-custom.sh 是死文件，已删）
- profile type：`main`(主路由) / `bypass`(旁路由) / `full`(完整路由)
- workflow profile：`default-main` / `mini-bypass` / `full-main` / `full-noadgh`

## ADGH 方案（二进制注入，定稿）
- 放弃 feeds 编译（Go 工具链脆弱），改为构建期拉官方预编译静态二进制经 `files/` 注入。
- `scripts/upgrade-adgh-binary.sh`：拉 `AdGuardHome_linux_amd64.tar.gz`（latest 或 --version），校验 `checksums.txt` 本架构 sha256，解包到 `files/usr/bin/AdGuardHome`；主源+ghproxy 回退；幂等（版本匹配跳过）。
- `files/etc/init.d/adguardhome`（Procd）：`/usr/bin/AdGuardHome --config /etc/adguardhome/adguardhome.yaml --work-dir /var/lib/adguardhome --no-check-update --logfile syslog`；interface.up 触发器延后启动。
- `files/etc/config/adguardhome`：`enabled=1`。
- `99-custom.sh`（bypass/full）`enable`+`start` 该 init 确保首刷自启（files/ 注入的 init 不会自动 enable，S19 早于 99-custom）。
- 4 个 configs 注释 `adguardhome`/`luci-app-adguardhome`/`luci-i18n-adguardhome-zh-cn`。
- `build.sh`/`workflow`：`feeds install -a -f`（消除 core package 覆盖警告）；步骤6 注入二进制 + chmod init.d；main 清理删除 `files/usr/bin/AdGuardHome` 与 `files/etc/adguardhome`。

## 网络拓扑与 DNS
- main(10.10.10.1)：DHCP 下发 DNS=旁路IP+公网；dnsmasq:53；dns-hijack 排除旁路IP；删 ADGH/OC。
- bypass(10.10.10.2)：删 wan/wan6+静态默认路由；ADGH:53+OC(redir-host,关劫持)；dnsmasq→5453；自身DNS 用公网防环路；删 dns-hijack。
- full(10.10.10.1)：OAF+ADGH:53+OC(redir-host)；dnsmasq:5453；dns-hijack 全劫持（无旁路则全劫持）；dhcpv6/ra=server。

## 关键技术决策
- DNS 劫持：nftables REDIRECT :53（fw4/nftables 后端）；IPv4 `ip saddr != 旁路IP` 排除旁路由；IPv6 `ip6 daddr ::/0`（不加 meta l4proto 会 No symbol）。
- ADGH YAML（`files/etc/adguardhome/adguardhome.yaml`）：upstream=OC `127.0.0.1:7874`（主，裸IP非`[/./]`——后者会 crash loop）+ 国内 DoT/明文兜底（223.5.5.5/223.6.6.6）；`parallel_requests=false`（OC 在时分流不泄漏）；严禁境外解析器；querylog.file_enabled=false（防闪存写爆）。OC 停则自动直连兜底。
- dnsmasq：`dns_redirect='0'`（主/旁/全，防 init 注入 53→5453 干扰 ADGH）；server 列表整体重建 + strictorder=1。
- OC：有 ADGH 时 `enable_redirect_dns='0'`，无 ADGH(noadgh) 时 `'1'`；Meta 核心由 `upgrade-openclash-core.sh` 下到 `files/etc/openclash/core/clash_meta`；sniffer 预置 `files/etc/openclash/custom/openclash_custom_overwrite.yaml`(enable_custom_overwrite=1)。
- 跨分支加固（公共尾部，全部 4 档）：关硬件流卸载、conntrack 超时、cpufreq-perf(performance)、WAN mtu_fix=1。
- `fix_line_endings` 覆盖 scripts+yaml（防 Windows CRLF 在路由器 ash 报错）。
- 文件清理在 openwrt 副本上做（build.sh/workflow），源树不被破坏。

## 关键坑（避免回归）
- ash 不支持 `trap ERR` / `exit 0`（source 杀父 shell）。
- 99-custom.sh 用 `<<EOT`（未引号）heredoc 会在生成期展开 `$(...)`/`$var`；首启才执行的命令须 `\$` 转义。
- ADGH 上游 `127.0.0.1:7874` 必须裸 IP（`[/./]` 形式致 `bad domain name "."` crash loop）。
- `filters`/`whitelist_filters`/`user_rules` 是 YAML 顶层项，不嵌套 `filtering:`。
- firewall include 需 `enabled='1'`、无 `reload`（fw4 不支持）、链 `{}` 单引号、`counter` 删除。
- DNS 劫持 IPv6 禁用 `meta l4proto`。
- `feeds install -a -f` 解决 `Not overriding core package` 警告（自定义 feed 覆盖 core）。

## 已知待确认
- 断流排查仍可能项：软件流卸载、NIC 卸载、IRQ 均衡、IPv6 DNS 下发、OAF 网关 CPU。
