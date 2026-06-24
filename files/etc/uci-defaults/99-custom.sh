#!/bin/sh
set -e
trap 'logger -t uci-defaults "ERROR: line $LINENO, exit $?"' ERR
logger -t uci-defaults "开始应用bypass配置"
echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
uci set network.lan.proto='static'
uci set network.lan.ipaddr='10.10.10.2'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='10.10.10.1'
uci set network.wan.proto='none'
uci set network.wan6.proto='none'
uci -q delete network.lan6 || true
uci set network.lan6.proto='none'
uci -q delete network.lan.dns || true
uci add_list network.lan.dns='10.10.10.1'
uci set dhcp.lan.ignore='1'
uci set dhcp.lan6.ignore='1'
uci -q set dhcp.@dnsmasq[0].port='5453' || true
uci -q set dhcp.@dnsmasq[0].rebind_protection='0' || true
uci commit network dhcp
uci set firewall.@zone[lan].input='ACCEPT'
uci set firewall.@zone[lan].output='ACCEPT'
uci set firewall.@zone[lan].forward='ACCEPT'
uci set firewall.@zone[lan].masq='1'
uci set firewall.@zone[lan].mtu_fix='1'
uci set firewall.@zone[wan].network=''
while uci -q delete firewall.@forwarding[0]; do :; done
uci commit firewall
uci set system.@system[0].hostname='Router-bypass'
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
exit 0
