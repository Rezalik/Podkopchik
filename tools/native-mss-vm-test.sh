#!/bin/sh
# Exercise the production MSS rules with real forwarding, only in the NIC-free VM.
set -eu
. /mnt/lab/native-vm-only.sh
base=/mnt/lab/permanent/usr/libexec/podkopchik
work=$(mktemp -d /tmp/pkc-mss.XXXXXX)
r=pkc-mss-router-$$ l=pkc-mss-client-$$ w=pkc-mss-peer-$$
cleanup() {
	[ -z "${cap:-}" ] || kill "$cap" 2>/dev/null || true
	for n in "$l" "$r" "$w"; do ip netns del "$n" 2>/dev/null || true; done
}
trap cleanup EXIT HUP INT TERM
for n in "$l" "$r" "$w"; do ip netns add "$n"; ip -n "$n" link set lo up; done
ip link add ml type veth peer name mr
ip link set ml netns "$l"; ip link set mr netns "$r"
ip -n "$l" link set ml name eth0; ip -n "$r" link set mr name br-lan
ip link add mt type veth peer name mw
ip link set mt netns "$r"; ip link set mw netns "$w"
ip -n "$r" link set mt name paw111111111111
ip -n "$w" link set mw name eth0
ip -n "$l" addr add 10.19.0.2/24 dev eth0
ip -n "$r" addr add 10.19.0.1/24 dev br-lan
ip -n "$r" addr add 203.0.113.1/24 dev paw111111111111
ip -n "$w" addr add 203.0.113.80/24 dev eth0
for n in "$l" "$w"; do ip -n "$n" link set eth0 up; done
ip -n "$r" link set br-lan up
ip -n "$r" link set paw111111111111 mtu 1280 up
ip -n "$l" route add default via 10.19.0.1
ip netns exec "$r" sysctl -qw net.ipv4.ip_forward=1
ucode -L "$base" -e 'const n=require("universal_plan");let p=n.compile({lan:"br-lan",automatic:"awg_11111111111111111111111111111111",classification:{mode:"compatible"},adapters:[{id:"11111111111111111111111111111111",type:"amneziawg",usable:true,ipv4:true,ipv6:false}],fake_pools:[],bypass:[],domains:[],clients:[],ips:[{cidr:"203.0.113.80",target:"auto_proxy_group"}]});print(n.batch(p));' > "$work/rules.nft"
ip netns exec "$r" nft -c -f "$work/rules.nft"
ip netns exec "$r" nft -f "$work/rules.nft"
ip netns exec "$w" tcpdump -nn -s 128 -c 1 -i eth0 'tcp[tcpflags] & tcp-syn != 0' > "$work/syn.txt" 2>&1 & cap=$!
sleep 1
# No listener is required: the outgoing SYN is the measurement.
ip netns exec "$l" wget -q -T 2 -O - http://203.0.113.80:18081/ >/dev/null 2>&1 || true
sleep 1
kill "$cap" 2>/dev/null || true
wait "$cap" || true; cap=
grep -q 'mss 1240' "$work/syn.txt" || { cat "$work/syn.txt"; exit 1; }
echo 'PASS: production AWG Native forwarding clamps LAN MSS 1460 to 1240 for tunnel MTU 1280'
