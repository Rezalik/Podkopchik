#!/bin/sh
# Exercise the actual persistent guard on an isolated OpenWrt kernel.
set -eu
umask 077
. /mnt/lab/native-vm-only.sh
work=$(mktemp -d /tmp/fake-egress.XXXXXX)
r=pkc-gr-$$; l=pkc-gl-$$; w=pkc-gw-$$
names=""; cap=""; pids=""
cleanup() {
	if [ -n "$cap" ]; then kill -INT "$cap" 2>/dev/null || true; wait "$cap" || true; fi
	for p in $pids; do kill "$p" 2>/dev/null || true; wait "$p" || true; done
	for ns in $names; do ip netns del "$ns"; done
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
rn() { ip netns exec "$r" "$@"; }
ln() { ip netns exec "$l" "$@"; }
for ns in "$r" "$l" "$w"; do
	ip netns add "$ns"; names="$names $ns"; ip -n "$ns" link set lo up
done
pair() {
	ip -n "$r" link add "$1" type veth peer name "$2"
	ip -n "$r" link set "$2" netns "$3"
	ip -n "$r" link set "$1" up
	ip -n "$3" link set "$2" up
}
pair br-lan client0 "$l"
pair wan external0 "$w"
ip -n "$r" addr add 192.168.88.1/24 dev br-lan
ip -n "$l" addr add 192.168.88.2/24 dev client0
ip -n "$r" addr add 192.0.2.1/24 dev wan
ip -n "$w" addr add 192.0.2.2/24 dev external0
ip -n "$r" route add default via 192.0.2.2
ip -n "$l" route add default via 192.168.88.1
rn sysctl -w net.ipv4.ip_forward=1 >/dev/null
cat > "$work/firewall" <<'EOF'
config defaults
	option input 'ACCEPT'
	option output 'ACCEPT'
	option forward 'REJECT'
config zone
	option name 'lan'
	list device 'br-lan'
	option input 'ACCEPT'
	option output 'ACCEPT'
	option forward 'REJECT'
config zone
	option name 'wan'
	list device 'wan'
	option input 'ACCEPT'
	option output 'ACCEPT'
	option forward 'REJECT'
	option masq '1'
config forwarding
	option src 'lan'
	option dest 'wan'
EOF
load_fw4() {
	rn sh -c 'mount --bind "$1" /etc/config/firewall && fw4 print' fw4 "$work/firewall" > "$work/fw4.nft"
	rn nft -f "$work/fw4.nft"
}
load_fw4
capture() {
	ip netns exec "$w" tcpdump --immediate-mode -p -nn -U -Q in -i external0 -s 80 -w "$work/$1.pcap" icmp > "$work/$1.log" 2>&1 & cap=$!
	for i in 1 2 3; do grep -q 'listening on' "$work/$1.log" 2>/dev/null && return; sleep 1; done
	return 1
}
stop_capture() {
	sleep 1
	kill -INT "$cap"; wait "$cap" || true; cap=""
	grep -qx '0 packets dropped by kernel' "$work/$1.log"
}
count() { tcpdump -nn -r "$work/$1.pcap" "$2" 2>/dev/null | wc -l | tr -d ' '; }
try_ping() { "$1" ping -c1 -W1 "$2" >/dev/null 2>&1 || true; }

capture before
try_ping ln 198.19.28.7
try_ping rn 198.19.28.8
try_ping ln 172.31.253.254
stop_capture before
[ "$(count before 'src host 192.0.2.1 and dst net 198.18.0.0/15')" = 2 ]
[ "$(count before 'src host 192.0.2.1 and dst net 172.31.253.0/24')" = 1 ]
rn awk '/src=192.168.88.2 dst=198.19.28.7.*src=198.19.28.7 dst=192.0.2.1/ {ok=1} END {exit !ok}' /proc/net/nf_conntrack
echo 'PASS: reproduced forwarded/SNAT and router-originated ICMP on the virtual WAN'

mkdir "$work/conf" "$work/run"
export PODKOPCHIK_CONFIG_DIR="$work/conf" PODKOPCHIK_TMP_DIR="$work/run" PODKOPCHIK_LIB=/mnt/lab/source
printf '%s\n' '{"fakedns":{"ipPool":"198.18.0.0/15"}}' > "$work/conf/config.json"
guard() { rn sh "$PODKOPCHIK_LIB/fakedns_guard.sh" "$@"; }
guard sync
guard register-native 172.31.253.0/24
guard register-native 172.31.253.0/24
guard status | grep -qx 'state=active'
guard status | grep -qx 'native_pools=172.31.253.0/24'
rn nft -f - <<'EOF'
add table inet podkopchik
add chain inet podkopchik prerouting { type filter hook prerouting priority -150; policy accept; }
add rule inet podkopchik prerouting iifname "br-lan" ip daddr 198.18.0.0/15 meta l4proto tcp meta mark set 0x100000 tproxy ip to :12345 accept
EOF
rn ip -4 rule add fwmark 0x100000 table 10991 priority 10991
rn ip -4 route add local default dev lo table 10991
cat > "$work/xray.json" <<'EOF'
{
  "log":{"loglevel":"warning"},
  "inbounds":[
    {"tag":"transparent","protocol":"dokodemo-door","port":12345,"settings":{"network":"tcp","followRedirect":true},"streamSettings":{"sockopt":{"tproxy":"tproxy"}},"sniffing":{"enabled":true,"metadataOnly":true,"destOverride":["fakedns"]}},
    {"tag":"dns-in","protocol":"dokodemo-door","listen":"0.0.0.0","port":1053,"settings":{"network":"tcp,udp","address":"127.0.0.1","port":1056}}
  ],
  "outbounds":[{"tag":"blocked","protocol":"blackhole"},{"tag":"dns-out","protocol":"dns"},{"tag":"origin","protocol":"freedom","settings":{"redirect":"192.0.2.2:18081"}}],
  "dns":{"queryStrategy":"UseIPv4","servers":["fakedns"]},
  "fakedns":{"ipPool":"198.18.0.0/15","poolSize":1024},
  "routing":{"domainStrategy":"AsIs","rules":[
    {"type":"field","inboundTag":["dns-in"],"outboundTag":"dns-out"},
    {"type":"field","domain":["domain:known.pkc.invalid"],"outboundTag":"origin"}
  ]}
}
EOF
rn /mnt/lab/xray run -test -config "$work/xray.json" > "$work/xray-validate.log" 2>&1
PKC_NATIVE_LAB=serve ip netns exec "$w" /mnt/lab/native-dns.test -test.run='^TestGuestFixture$' -- 192.0.2.2:18081 > "$work/serve.log" 2>&1 & pids="$pids $!"
ip netns exec "$r" /mnt/lab/xray run -config "$work/xray.json" > "$work/xray.log" 2>&1 & xpid=$!; pids="$pids $xpid"
sleep 2
known=$(ln nslookup -type=A -timeout=2 -retry=1 -port=1053 known.pkc.invalid 192.168.88.1 | awk '/^Address: 198\.(18|19)\./ {print $2; exit}')
[ -n "$known" ]
ln wget -T 3 -qO- "http://$known:18081/" | grep -qx 'isolated-http-ok'
kill "$xpid"; wait "$xpid" || true
echo 'PASS: real Xray FakeDNS known address still reaches its origin through local TPROXY'
capture after
try_ping ln 198.19.28.7
try_ping rn 198.19.28.8
try_ping ln 172.31.253.254
try_ping rn 172.31.253.254
ln ping -c1 -W1 192.0.2.2 >/dev/null

# Firewall4 replacement and rollback to a config without FakeDNS must not
# forget either pool; the registry is independent from config.json.
load_fw4
printf '{}\n' > "$work/conf/config.json"
guard sync
guard status | grep -qx 'pools=198.18.0.0/15 172.31.253.0/24'
if printf '%s\n' 'delete table inet podkopchik_fake_guard' 'add rule inet missing-table missing-chain drop' | rn nft -f - >/dev/null 2>&1; then exit 1; fi
guard status | grep -qx 'state=active'
try_ping ln 198.19.28.7
try_ping rn 172.31.253.254

# Exercise nft independently of the RPDB. A stale NAT binding (real WAN
# destination) is also rejected; it cannot disguise its original destination.
for p in 198.18.0.0/15 172.31.253.0/24; do
	rn ip -4 rule del blackhole to "$p" priority 10992 protocol 187
done
rn nft -f - <<'EOF'
add table ip pkc_lab_nat
add chain ip pkc_lab_nat prerouting { type nat hook prerouting priority -104; policy accept; }
add chain ip pkc_lab_nat output { type nat hook output priority -100; policy accept; }
add rule ip pkc_lab_nat prerouting ip daddr 172.31.253.203 dnat to 192.0.2.2
add rule ip pkc_lab_nat output ip daddr 172.31.253.204 dnat to 192.0.2.2
EOF
try_ping ln 198.19.28.9
try_ping rn 172.31.253.202
try_ping ln 172.31.253.203
try_ping rn 172.31.253.204
rn nft list chain inet podkopchik_fake_guard native_original | grep -Eq 'counter packets [1-9][0-9]*'
rn nft list chain inet podkopchik_fake_guard output | grep -Eq '@native4 counter packets [1-9][0-9]*'
stop_capture after
[ "$(count after 'net 198.18.0.0/15 or net 172.31.253.0/24')" = 0 ]
[ "$(count after 'dst host 192.0.2.2 and icmp[icmptype] = icmp-echo')" = 1 ]
guard sync
guard status | grep -qx 'state=active'
echo 'PASS: zero synthetic egress, DNAT fallback dropped, direct survived; fw4 reload and rollback retained both pools'
