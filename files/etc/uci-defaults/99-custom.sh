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
uci set dhcp.lan.sequential_ip='1'
uci set dhcp.lan.start='8'
uci set dhcp.lan.limit='150'
uci -q set dhcp.@dnsmasq[0].rebind_protection='0' || true
uci -q del_list dhcp.@dnsmasq[0].server='10.10.10.2' || true
uci add_list dhcp.@dnsmasq[0].server='10.10.10.2'
uci add_list dhcp.@dnsmasq[0].server='1.1.1.1'
uci add_list dhcp.@dnsmasq[0].server='223.5.5.5'
uci set dhcp.@dnsmasq[0].strictorder='1'
uci set dhcp.@dnsmasq[0].querytimeout='2'
uci set dhcp.@dnsmasq[0].retries='1'
uci commit dhcp

LAN_FW=$(uci show firewall | grep "\.name='lan'" | cut -d. -f1-2)
WAN_FW=$(uci show firewall | grep "\.name='wan'" | cut -d. -f1-2)
[ -n "$LAN_FW" ] && uci set ${LAN_FW}.forward='ACCEPT'
[ -n "$WAN_FW" ] && uci set ${WAN_FW}.forward='ACCEPT'
uci commit firewall

# DNS 劫持：53 端口重定向到 dnsmasq（排除旁路由自身避免死循环）
cat > /etc/dns-hijack.sh << 'HIJACK'
#!/bin/sh
iptables -t nat -S PREROUTING 2>/dev/null | grep "dport 53 .* REDIRECT" | sed 's/^-A //' | while read -r rule; do
    iptables -t nat -D $rule 2>/dev/null
done
HIJACK
cat >> /etc/dns-hijack.sh << HIEOF
iptables -t nat -A PREROUTING ! -s 10.10.10.2 -p udp --dport 53 -j REDIRECT --to-ports 53
iptables -t nat -A PREROUTING ! -s 10.10.10.2 -p tcp --dport 53 -j REDIRECT --to-ports 53
HIEOF
chmod 755 /etc/dns-hijack.sh
/etc/dns-hijack.sh
uci add firewall include
uci set firewall.@include[-1].path='/etc/dns-hijack.sh'
uci set firewall.@include[-1].reload='1'
uci commit firewall
uci set system.@system[0].hostname='Router-main'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci -q delete system.ntp.server
uci set system.ntp.enable_server='1'
uci add_list system.ntp.server='ntp.aliyun.com'
uci add_list system.ntp.server='ntp.tencent.com'
uci add_list system.ntp.server='ntsc.ac.cn'
uci add_list system.ntp.server='cn.pool.ntp.org'
uci commit system
logger -t uci-defaults "配置应用完成"
