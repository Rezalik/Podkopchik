#!/bin/sh
# Regression for admitted synthetic sessions; execute only in the NIC-free VM.
set -eu
. /mnt/lab/native-vm-only.sh
. /mnt/lab/native-vm-binaries.sh
work=$(mktemp -d /tmp/pkc-video-ttl.XXXXXX)
r=pkc-video-router-$$ l=pkc-video-client-$$ w=pkc-video-peer-$$
pids= caps=
cleanup() {
 for p in $pids $caps; do kill "$p" 2>/dev/null || true; done
 for p in $pids $caps; do wait "$p" 2>/dev/null || true; done
 for n in "$l" "$r" "$w"; do ip netns del "$n" 2>/dev/null || true; done
}
trap cleanup EXIT HUP INT TERM
for n in "$r" "$l" "$w"; do ip netns add "$n"; ip -n "$n" link set lo up; done
ip -n "$r" link add br-lan type veth peer name vc
ip -n "$r" link set vc netns "$l"
ip -n "$r" link add paw111111111111 type veth peer name va
ip -n "$r" link set va netns "$w"
ip -n "$r" link add wan type veth peer name vw
ip -n "$r" link set vw netns "$w"
for d in br-lan paw111111111111 wan; do ip -n "$r" link set "$d" up; done
ip -n "$l" link set vc up
ip -n "$w" link set va up
ip -n "$w" link set vw up
ip -n "$l" addr add 10.19.0.2/24 dev vc
ip -n "$r" addr add 10.19.0.1/24 dev br-lan
ip -n "$r" addr add 198.51.1.1/24 dev paw111111111111
ip -n "$w" addr add 198.51.1.2/24 dev va
ip -n "$r" addr add 198.51.9.1/24 dev wan
ip -n "$w" addr add 198.51.9.2/24 dev vw
ip -n "$w" addr add 203.0.113.80/32 dev lo
ip -n "$l" addr add fd19::2/64 dev vc
ip -n "$r" addr add fd19::1/64 dev br-lan
ip -n "$r" addr add 2001:db8:1::1/64 dev paw111111111111
ip -n "$w" addr add 2001:db8:1::2/64 dev va
ip -n "$r" addr add 2001:db8:9::1/64 dev wan
ip -n "$w" addr add 2001:db8:9::2/64 dev vw
ip -n "$w" addr add 2001:db8:80::1/128 dev lo
ip -n "$l" route add default via 10.19.0.1
ip -n "$r" route add default via 198.51.9.2
ip -n "$l" -6 route add default via fd19::1
ip -n "$r" -6 route add default via 2001:db8:9::2
ip netns exec "$r" sysctl -qw net.ipv4.ip_forward=1
ip netns exec "$r" sysctl -qw net.ipv6.conf.all.forwarding=1
lib=/mnt/lab/source
ucode -L "$lib" -e '
 import {writefile} from "fs";
 const n=require("universal_plan"),a=require("awg_network").resources("11111111111111111111111111111111");
 let p=n.compile({lan:"br-lan",automatic:a.tag,classification:{mode:"compatible"},
 adapters:[{id:a.id,type:"amneziawg",usable:true,ipv4:true,ipv6:true,source_ips:["198.51.1.1","2001:db8:1::1"]}],
 fake_pools:["198.18.0.0/15"],bypass:[],clients:[],ips:[],domains:[{names:["video.example"],target:"auto_proxy_group"}],
 synthetic:{epoch:"aabbccddeeff0011",private_pool:"172.31.253.0/24",pools:["172.31.253.0/24","2001:2::/48"],
 inventory:{addresses:[{addr_info:[{local:"10.19.0.1",prefixlen:24},{local:"fd19::1",prefixlen:64}]}],routes:[{dst:"198.51.1.0/24"},{dst:"198.51.9.0/24"},{dst:"203.0.113.80/32"},{dst:"2001:db8::/32"}],issued:["198.18.0.0/15"]},
 dns:{port:1058,ipv4:"10.19.0.1",ipv6:"fd19::1"}}});
 print(n.dns_gate(p));print(n.batch(p));
 let down={...p,adapters:{...p.adapters},automatic:"blocked"};down.adapters[a.tag]={...p.adapters[a.tag],usable:false};
 writefile(ARGV[0],n.switch_batch(p,down));writefile(ARGV[1],n.switch_batch(down,p));' "$work/down.nft" "$work/restore.nft" > "$work/rules.nft"
ucode -L "$lib" -e 'let a=require("awg_network").resources("11111111111111111111111111111111");printf("%d %d %d\n",a.mark,a.table,a.priority);' > "$work/resources"
read mark table priority < "$work/resources"
ip -n "$r" route add table "$table" default via 198.51.1.2 dev paw111111111111
ip -n "$r" rule add priority "$priority" fwmark "$mark" lookup "$table"
ip -n "$r" -6 route add table "$table" default via 2001:db8:1::2 dev paw111111111111
ip -n "$r" -6 rule add priority "$priority" fwmark "$mark" lookup "$table"
ip netns exec "$r" nft -c -f "$work/rules.nft"
ip netns exec "$r" nft -f "$work/rules.nft"
ip netns exec "$r" nft 'add table inet video_direct'
ip netns exec "$r" nft 'add chain inet video_direct post { type nat hook postrouting priority 100; policy accept; }'
ip netns exec "$r" nft 'add rule inet video_direct post oifname "wan" masquerade'
bin="$PKC_VM_BIN/native-dns.test"
PKC_NATIVE_LAB=serve ip netns exec "$w" "$bin" -test.run='^TestGuestFixture$' -- 203.0.113.80:18081 > "$work/server.log" 2>&1 &
server=$!;pids="$server"
PKC_NATIVE_LAB=serve ip netns exec "$w" "$bin" -test.run='^TestGuestFixture$' -- '[2001:db8:80::1]:18081' > "$work/server6.log" 2>&1 &
pids="$pids $!"
for endpoint in 203.0.113.80:18080 '[2001:db8:80::1]:18080'; do
 PKC_NATIVE_LAB=serve ip netns exec "$w" "$bin" -test.run='^TestGuestFixture$' -- "$endpoint" > "$work/direct-server-$!.log" 2>&1 &
 pids="$pids $!"
done
ip netns exec "$w" tcpdump --immediate-mode -U -nn -s 96 -c 1024 -i vw -Q in -w "$work/wan.pcap" \
 'net 172.31.253.0/24 or net 2001:2::/48 or host 203.0.113.80 or host 2001:db8:80::1' > "$work/wan.log" 2>&1 &
wan_cap=$!;caps="$wan_cap"
ip netns exec "$w" tcpdump --immediate-mode -U -nn -s 96 -c 1024 -i va -Q in -w "$work/tunnel.pcap" \
 'port 18081' > "$work/tunnel.log" 2>&1 &
tunnel_cap=$!;caps="$caps $tunnel_cap"
sleep 1
lease() {
 ip netns exec "$r" nft -f - <<EOF
destroy element inet podkopchik_native s_aabbccddeeff0011_m${1} { ${3} }
destroy element inet podkopchik_native s_aabbccddeeff0011_g0_${1} { ${3} }
create element inet podkopchik_native s_aabbccddeeff0011_m${1} { ${3} timeout ${2}s : ${4} }
create element inet podkopchik_native s_aabbccddeeff0011_g0_${1} { ${3} timeout ${2}s }
EOF
}
for family in 4 6; do
case "$family" in
 4) fake=172.31.253.1 real=203.0.113.80 endpoint=172.31.253.1:18081 direct=203.0.113.80 unknown=172.31.253.254;;
 6) fake=2001:2::1 real=2001:db8:80::1 endpoint='[2001:2::1]:18081' direct='[2001:db8:80::1]' unknown='[2001:2::fe]';;
esac
lease "$family" 8 "$fake" "$real"
PKC_NATIVE_LAB=udp ip netns exec "$l" "$bin" -test.run='^TestGuestFixture$' -- "$endpoint"
PKC_NATIVE_LAB=hold ip netns exec "$l" "$bin" -test.run='^TestGuestFixture$' -- "$endpoint" "$work/ready$family" "$work/send$family" apply > "$work/client$family.log" 2>&1 &
client=$!;pids="$pids $client"
for i in 1 2 3; do [ ! -e "$work/ready$family" ] || break; sleep 1; done
[ -f "$work/ready$family" ] || { cat "$work/client$family.log"; exit 1; }
echo "PASS IPv$family: admitted TCP keepalive and UDP use the selected native transport"
sleep 9
if ip netns exec "$r" nft get element inet podkopchik_native "s_aabbccddeeff0011_m$family" "{ $fake }" >/dev/null 2>&1; then exit 1; fi
touch "$work/send$family.again"
for i in 1 2 3 4; do [ ! -e "$work/send$family.replied" ] || break; sleep 1; done
[ -f "$work/send$family.replied" ] || { cat "$work/client$family.log"; exit 1; }
touch "$work/send$family"
wait "$client" || { cat "$work/client$family.log"; exit 1; }
echo "PASS IPv$family: admitted TCP survives DNS expiry on its pinned connection"
if ip netns exec "$l" wget -q -T 1 -O - "http://$endpoint/" >/dev/null 2>&1; then exit 1; fi
if PKC_NATIVE_LAB=udp ip netns exec "$l" "$bin" -test.run='^TestGuestFixture$' -- "$endpoint" > "$work/stale-udp$family.log" 2>&1; then exit 1; fi
if ip netns exec "$l" wget -q -T 1 -O - "http://$unknown:18081/" >/dev/null 2>&1; then exit 1; fi
echo "PASS IPv$family: new expired TCP/UDP and unknown synthetic addresses remain blocked"
[ "$(ip netns exec "$l" wget -q -T 2 -O - "http://$direct:18080/")" = isolated-http-ok ]
lease "$family" 60 "$fake" "$real"
[ "$(ip netns exec "$l" wget -q -T 2 -O - "http://$endpoint/")" = isolated-http-ok ]
PKC_NATIVE_LAB=udp ip netns exec "$l" "$bin" -test.run='^TestGuestFixture$' -- "$endpoint"
echo "PASS IPv$family: Direct and renewed mapping both work"
done
lease 4 60 172.31.253.1 203.0.113.80
PKC_NATIVE_LAB=hold ip netns exec "$l" "$bin" -test.run='^TestGuestFixture$' -- 172.31.253.1:18081 "$work/down-ready" "$work/down-send" > "$work/down-client.log" 2>&1 &
client=$!;pids="$pids $client"
for i in 1 2 3; do [ ! -e "$work/down-ready" ] || break; sleep 1; done
[ -f "$work/down-ready" ] || exit 1
ip netns exec "$r" nft -c -f "$work/down.nft"
ip netns exec "$r" nft -f "$work/down.nft"
touch "$work/down-send"
wait "$client" || { cat "$work/down-client.log"; exit 1; }
if ip netns exec "$l" wget -q -T 1 -O - http://172.31.253.1:18081/ >/dev/null 2>&1; then exit 1; fi
[ "$(ip netns exec "$l" wget -q -T 2 -O - http://203.0.113.80:18080/)" = isolated-http-ok ]
echo 'PASS: all-down blocks established and new protected traffic; Direct survives'
ip netns exec "$r" nft -f "$work/restore.nft"
PKC_NATIVE_LAB=hold ip netns exec "$l" "$bin" -test.run='^TestGuestFixture$' -- 172.31.253.1:18081 "$work/missing-ready" "$work/missing-send" > "$work/missing-client.log" 2>&1 &
client=$!;pids="$pids $client"
for i in 1 2 3; do [ ! -e "$work/missing-ready" ] || break; sleep 1; done
[ -f "$work/missing-ready" ] || exit 1
ip netns exec "$r" nft delete table inet podkopchik_native
touch "$work/missing-send"
wait "$client" || { cat "$work/missing-client.log"; exit 1; }
echo 'PASS: removing classification still revokes established traffic independently of DNS TTL'
for p in $caps; do kill -INT "$p" 2>/dev/null || true; done
for p in $caps; do wait "$p" 2>/dev/null || true; done
caps=
protected=$(tcpdump -nn -r "$work/wan.pcap" 'port 18081 or net 172.31.253.0/24 or net 2001:2::/48' 2>/dev/null | wc -l)
direct=$(tcpdump -nn -r "$work/wan.pcap" 'port 18080' 2>/dev/null | wc -l)
tunnel=$(tcpdump -nn -r "$work/tunnel.pcap" 2>/dev/null | wc -l)
[ "$protected" = 0 ] && [ "$direct" -gt 0 ] && [ "$tunnel" -gt 0 ]
printf 'PASS: VM WAN capture protected=%s direct-control=%s; selected tunnel=%s packets\n' "$protected" "$direct" "$tunnel"
echo 'VIDEO_TTL_FIXED_COMPLETE'
