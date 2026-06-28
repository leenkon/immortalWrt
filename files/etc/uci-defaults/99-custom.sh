#!/bin/sh
logger -t uci-defaults "开始应用bypass配置"
grep -q 'net.ipv4.ip_forward=1' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
uci set network.lan.proto='static'
uci set network.lan.ipaddr='10.10.10.2'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='10.10.10.1'
uci -q delete network.lan.dns || true
uci add_list network.lan.dns='1.1.1.1'
uci add_list network.lan.dns='223.5.5.5'
uci -q delete network.lan6 || true
uci -q delete network.default_route || true
uci set network.default_route=route
uci set network.default_route.interface='lan'
uci set network.default_route.target='0.0.0.0'
uci set network.default_route.netmask='0.0.0.0'
uci set network.default_route.gateway='10.10.10.1'
# 旁路场景：删除所有 WAN 接口（旁路由只有 LAN）
uci -q delete network.wan || true
uci -q delete network.wan6 || true
uci commit network

uci set dhcp.lan.ignore='1'
uci set dhcp.lan6.ignore='1'
uci -q set dhcp.@dnsmasq[0].port='5453' || true
uci -q set dhcp.@dnsmasq[0].rebind_protection='0' || true
uci -q delete dhcp.@dnsmasq[0].listen_address || true
uci add_list dhcp.@dnsmasq[0].listen_address='127.0.0.1'
uci set dhcp.@dnsmasq[0].dns_redirect='0'
uci commit dhcp
LAN_FW=$(uci show firewall | grep "\.name='lan'" | cut -d. -f1-2)
WAN_FW=$(uci show firewall | grep "\.name='wan'" | cut -d. -f1-2)
[ -n "$LAN_FW" ] && {
    uci set ${LAN_FW}.input='ACCEPT'
    uci set ${LAN_FW}.output='ACCEPT'
    uci set ${LAN_FW}.forward='ACCEPT'
}
[ -n "$WAN_FW" ] && {
    uci set ${WAN_FW}.network=''
    uci set ${WAN_FW}.masq='0'
}
while uci -q delete firewall.@forwarding[0]; do :; done
uci commit firewall

uci set adguardhome.config.enabled='1'
uci commit adguardhome

# OpenClash: 停用 DNS 劫持，避免与 AdGuardHome 冲突（旁路由场景）
# Fake-IP 模式依赖 DNS 劫持，改用 redir-host 兼容模式
uci set openclash.config.enable_redirect_dns='0'
uci set openclash.config.en_mode='redir-host'
uci set openclash.config.operation_mode='redir-host'
uci commit openclash
uci set system.@system[0].hostname='Router-bypass'
uci set system.@system[0].timezone='CST-8'
uci set system.@system[0].zonename='Asia/Shanghai'
uci -q delete system.ntp.server
uci add_list system.ntp.server='ntp.aliyun.com'
uci add_list system.ntp.server='cn.pool.ntp.org'
uci commit system
logger -t uci-defaults "配置应用完成"
