#!/bin/sh
logger -t uci-defaults "开始应用main配置"
uci set network.wan.proto='dhcp'
uci -q delete network.wan6 || true
uci set network.wan6.proto='dhcpv6'
uci -q delete network.lan6 || true
uci set network.lan.ip6assign='64'
uci set network.lan.proto='static'
uci set network.lan.ipaddr='10.10.10.1'
uci set network.lan.netmask='255.255.255.0'
uci set network.wan.peerdns='0'
uci -q delete network.wan.dns || true
uci add_list network.wan.dns='1.1.1.1'
uci add_list network.wan.dns='223.5.5.5'
uci commit network

uci -q delete dhcp.lan.dhcp_option || true
uci add_list dhcp.lan.dhcp_option='6,10.10.10.2,1.1.1.1,223.5.5.5'
uci set dhcp.lan.start='6'
uci set dhcp.lan.limit='150'
uci -q set dhcp.@dnsmasq[0].rebind_protection='0' || true
uci set dhcp.@dnsmasq[0].sequential_ip='1'
uci -q del_list dhcp.@dnsmasq[0].server='10.10.10.2' || true
uci add_list dhcp.@dnsmasq[0].server='10.10.10.2'
uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'
uci add_list dhcp.@dnsmasq[0].server='223.5.5.5'
uci set dhcp.@dnsmasq[0].strictorder='1'
uci set dhcp.@dnsmasq[0].dns_redirect='0'
uci commit dhcp

# 主路由不需要 AdGuardHome，显式禁用（防包意外包含）
uci -q set adguardhome.config.enabled='0'
uci -q commit adguardhome

LAN_FW=$(uci show firewall | grep "\.name='lan'" | cut -d. -f1-2)
[ -n "$LAN_FW" ] && uci set ${LAN_FW}.forward='ACCEPT'
while uci -q delete firewall.@forwarding[0]; do :; done
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='wan'

# DNS 劫持（IPv4 排除旁路由防死循环，IPv6 不排除因 AdGuardHome 走 DoT:853）
cat > /etc/dns-hijack.sh << HIJACK
#!/bin/sh
nft delete table inet dns_hijack 2>/dev/null
if command -v nft >/dev/null 2>&1; then
    nft add table inet dns_hijack
    nft add chain inet dns_hijack prerouting '{ type nat hook prerouting priority -100; }'
    nft add rule inet dns_hijack prerouting ip saddr != 10.10.10.2 meta l4proto udp dport 53 redirect to :53
    nft add rule inet dns_hijack prerouting ip saddr != 10.10.10.2 meta l4proto tcp dport 53 redirect to :53
    nft add rule inet dns_hijack prerouting ip6 daddr '::/0' meta l4proto udp dport 53 redirect to :53
    nft add rule inet dns_hijack prerouting ip6 daddr '::/0' meta l4proto tcp dport 53 redirect to :53
    logger -t dns-hijack "nftables DNS hijack applied (IPv4+IPv6)"
else
    logger -t dns-hijack "ERROR: nft not found"
fi
HIJACK
chmod 755 /etc/dns-hijack.sh
/etc/dns-hijack.sh
uci set firewall.dns_hijack_include=include
uci set firewall.dns_hijack_include.path='/etc/dns-hijack.sh'
uci set firewall.dns_hijack_include.enabled='1'
uci commit firewall

uci set system.@system[0].hostname='Router-main'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci -q delete system.ntp.server
uci add_list system.ntp.server='ntp.aliyun.com'
uci add_list system.ntp.server='cn.pool.ntp.org'
uci commit system
logger -t uci-defaults "配置应用完成"
