#!/bin/sh
# Only the NIC-free disposable OpenWrt guest may execute this scenario.
set -eu
umask 077
fail() { echo "FAIL: $*" >&2; exit 1; }
[ "$(tr -d '\000' </proc/device-tree/model)" = 'linux,dummy-virt' ] || fail 'not the QEMU virt lab'
[ "$(ls /sys/class/net)" = lo ] || fail 'unexpected guest network device'
[ "$(uname -r)" = 6.12.112 ] || fail 'unexpected guest kernel'
[ -z "$(ip route show default)$(ip -6 route show default)" ] || fail 'guest has a default route'
lib=/mnt/lab/source
bin=/mnt/lab/native-dns.test
daemon=/mnt/lab/podkopchik-native-dns
xray=/mnt/lab/xray
work=$(mktemp -d /tmp/native-dns-vm.XXXXXX)
r="pkc-router-$$"; l="pkc-client-$$"; w="pkc-wan-$$"
pids=""; caps=""; namespaces=""
cleanup() {
	for pid in $pids $caps; do kill -TERM "$pid" 2>/dev/null || true; done
	for pid in $pids $caps; do wait "$pid" 2>/dev/null || true; done
	for ns in $namespaces; do ip netns del "$ns"; done
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
rn() { ip netns exec "$r" "$@"; }
ln() { ip netns exec "$l" "$@"; }
wn() { ip netns exec "$w" "$@"; }
for ns in "$r" "$l" "$w"; do
	ip netns add "$ns"; namespaces="$namespaces $ns"; ip -n "$ns" link set lo up
done
pair() {
	ip -n "$r" link add "$1" type veth peer name "$2"
	ip -n "$r" link set "$2" netns "$3"
	ip -n "$r" link set "$1" up
	ip -n "$3" link set "$2" up
}
pair br-lan client0 "$l"
pair wan external0 "$w"
pair paw111111111111 tunnel0 "$w"
pair paw222222222222 tunnel1 "$w"
ip -n "$l" addr add 10.19.0.2/24 dev client0
ip -n "$l" addr add 10.19.0.3/24 dev client0
ip -n "$r" addr add 10.19.0.1/24 dev br-lan
ip -n "$l" -6 addr add fd19::2/64 dev client0 nodad
ip -n "$r" -6 addr add fd19::1/64 dev br-lan nodad
ip -n "$l" route add default via 10.19.0.1
ip -n "$l" -6 route add default via fd19::1
ip -n "$r" addr add 192.0.2.1/24 dev wan
ip -n "$w" addr add 192.0.2.2/24 dev external0
ip -n "$r" -6 addr add 2001:db8:0::1/64 dev wan nodad
ip -n "$w" -6 addr add 2001:db8:0::2/64 dev external0 nodad
ip -n "$r" route add default via 192.0.2.2
ip -n "$r" -6 route add default via 2001:db8:0::2
ip -n "$w" route add 10.19.0.0/24 via 192.0.2.1
ip -n "$w" -6 route add fd19::/64 via 2001:db8:0::1
ip -n "$w" addr add 203.0.113.80/32 dev lo
ip -n "$w" addr add 203.0.113.81/32 dev lo
ip -n "$w" -6 addr add 2001:db8:80::1/128 dev lo nodad
rn sysctl -w net.ipv4.ip_forward=1 >/dev/null
rn sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
for mode in gate primary backup down restore dns resources; do
	ucode -L "$lib" "$lib/native_dns_vm_plan.uc" "$mode" > "$work/$mode"
done
i=0
while read -r dev mark table prio; do
	i=$((i+1)); peer="tunnel$((i-1))"
	ip -n "$r" addr add "198.51.$i.1/24" dev "$dev"
	ip -n "$w" addr add "198.51.$i.2/24" dev "$peer"
	ip -n "$r" -6 addr add "2001:db8:$i::1/64" dev "$dev" nodad
	ip -n "$w" -6 addr add "2001:db8:$i::2/64" dev "$peer" nodad
	ip -n "$r" rule add fwmark "$mark" table "$table" priority "$prio"
	ip -n "$r" -6 rule add fwmark "$mark" table "$table" priority "$prio"
	ip -n "$r" route add default via "198.51.$i.2" dev "$dev" table "$table" metric 100
	ip -n "$r" -6 route add default via "2001:db8:$i::2" dev "$dev" table "$table" metric 100
	ip -n "$r" route add unreachable default table "$table" metric 42760
	ip -n "$r" -6 route add unreachable default table "$table" metric 42760
done < "$work/resources"
rn nft -f "$work/gate"
rn nft -c -f "$work/primary"
rn nft -f "$work/primary"

for net in udp tcp; do
	PKC_NATIVE_LAB=dns ip netns exec "$r" "$bin" -test.run='^TestGuestFixture$' -- 127.0.0.1:1059 "$net" >"$work/dns-$net.log" 2>&1 & pids="$pids $!"
done
for addr in '203.0.113.80:18080' '203.0.113.80:18081' '203.0.113.81:18081' '[2001:db8:80::1]:18081'; do
	PKC_NATIVE_LAB=serve ip netns exec "$w" "$bin" -test.run='^TestGuestFixture$' -- "$addr" >"$work/peer-$addr.log" 2>&1 & pids="$pids $!"
done
rn "$daemon" -config "$work/dns" -ledger "$work/ledger" -init-ledger
ip netns exec "$r" "$daemon" -config "$work/dns" -ledger "$work/ledger" >"$work/classifier.log" 2>&1 &
dnspid=$!; pids="$pids $dnspid"
for iface in external0 tunnel0 tunnel1; do
	ip netns exec "$w" tcpdump -i "$iface" -Q in -nn -s 96 -c 1024 -w "$work/$iface.pcap" \
		'net 198.18.0.0/15 or net 2001:2::/48 or port 18080 or port 18081 or port 18443' >"$work/cap-$iface.log" 2>&1 &
	caps="$caps $!"
done
sleep 1
kill -0 "$dnspid"
query() { PKC_NATIVE_LAB=query ln "$bin" -test.run='^TestGuestFixture$' -- 10.19.0.1:1058 "$@"; }
answer() { query "$@" | sed -n 's/^address=//p'; }
http() { "$1" wget -q -T 2 -O - "$2"; }
ok() { [ "$(http "$1" "$2")" = isolated-http-ok ]; }
blocked() { if http "$1" "$2" >/dev/null 2>&1; then fail 'protected HTTP succeeded unexpectedly'; fi; }
udp() { PKC_NATIVE_LAB=udp "$1" "$bin" -test.run='^TestGuestFixture$' -- "$2"; }

v4=$(answer udp protected.example. A NOERROR 1); case "$v4" in 198.18.*) ;; *) fail 'no synthetic IPv4 answer' ;; esac
v6=$(answer tcp protected.example. AAAA NOERROR 1); case "$v6" in 2001:2:*) ;; *) fail 'no synthetic IPv6 answer' ;; esac
[ "$(answer tcp protected.example. A NOERROR 1)" = "$v4" ]
[ "$(answer udp direct.example. A NOERROR 1)" = 203.0.113.80 ]
clients=""
for i in 1 2 3 4 5 6 7 8; do
	net=udp; [ "$((i % 2))" != 0 ] || net=tcp
	PKC_NATIVE_LAB=query ip netns exec "$l" "$bin" -test.run='^TestGuestFixture$' -- 10.19.0.1:1058 "$net" \
		protected.example. A NOERROR 1 >"$work/concurrent-$i.log" 2>&1 & clients="$clients $!"
done
client_error=0
for pid in $clients; do wait "$pid" || client_error=1; done
[ "$client_error" = 0 ] || fail 'concurrent protected DNS query failed'
for i in 1 2 3 4 5 6 7 8; do grep -qx "address=$v4" "$work/concurrent-$i.log"; done
ok ln "http://$v4:18081/"
ok ln "http://[$v6]:18081/"
ok ln 'http://203.0.113.81:18081/'
ok ln 'http://203.0.113.80:18080/'
udp ln "$v4:18081"
udp ln "[$v6]:18081"
echo 'PASS: committed DNS UDP/TCP, native IPv4/IPv6 TCP/UDP, protected CIDR and ordinary direct'

rn nft -f "$work/backup"
[ "$(answer udp protected.example. A NOERROR 1)" = "$v4" ]
ok ln "http://$v4:18081/"
ok ln "http://[$v6]:18081/"
rn nft -f "$work/down"
blocked ln "http://$v4:18081/"
blocked ln "http://[$v6]:18081/"
ok ln 'http://203.0.113.80:18080/'
echo 'PASS: existing lease survives failover; all-down fails closed while direct works'

cat >"$work/xray-server.json" <<'EOF'
{"log":{"loglevel":"warning"},"inbounds":[{"listen":"192.0.2.2","port":18443,"protocol":"vless","settings":{"decryption":"none","clients":[{"id":"11111111-2222-4333-8444-555555555555"}]}}],"outbounds":[{"protocol":"freedom"}]}
EOF
cat >"$work/xray-client.json" <<'EOF'
{"log":{"loglevel":"warning"},"inbounds":[{"listen":"127.0.0.1","port":1080,"protocol":"socks"}],"outbounds":[{"sendThrough":"10.19.0.3","protocol":"vless","settings":{"vnext":[{"address":"192.0.2.2","port":18443,"users":[{"id":"11111111-2222-4333-8444-555555555555","encryption":"none"}]}]}}]}
EOF
wn "$xray" run -test -config "$work/xray-server.json"
ln "$xray" run -test -config "$work/xray-client.json"
ip netns exec "$w" "$xray" run -config "$work/xray-server.json" >"$work/xray-server.log" 2>&1 & serverpid=$!; pids="$pids $serverpid"
ip netns exec "$l" "$xray" run -config "$work/xray-client.json" >"$work/xray-client.log" 2>&1 & clientpid=$!; pids="$pids $clientpid"
i=0
until grep -q 'Xray .* started' "$work/xray-server.log" && grep -q 'Xray .* started' "$work/xray-client.log"; do
	kill -0 "$serverpid" "$clientpid" && [ "$i" -lt 10 ] || { cat "$work/xray-server.log" "$work/xray-client.log"; fail 'Xray fixture not ready'; }
	sleep 1; i=$((i+1))
done
PKC_NATIVE_LAB=socks ln "$bin" -test.run='^TestGuestFixture$' -- 127.0.0.1:1080 203.0.113.80:18081
echo 'PASS: separate Xray/VLESS connection and endpoint bypass with native selection all-down'

rn nft -f "$work/restore"
ok ln "http://$v4:18081/"
read -r _ main_mark main_table main_prio < "$work/resources"
ip -n "$r" rule del fwmark "$main_mark" table "$main_table" priority "$main_prio"
blocked ln "http://$v4:18081/"
ip -n "$r" rule add fwmark "$main_mark" table "$main_table" priority "$main_prio"
ok ln "http://$v4:18081/"
blocked ln 'http://198.18.255.254:18081/'
blocked rn 'http://198.18.255.254:18081/'
blocked ln 'http://198.19.255.254:18081/'
blocked ln 'http://[2001:2::dead]:18081/'

# Kernel rejection of the final operation must also undo the first operation.
cat >"$work/rejected.nft" <<EOF
add element inet podkopchik_native s_0011223344556677_m4 { 198.18.255.250 timeout 90s : 203.0.113.80 }
create element inet podkopchik_native s_0011223344556677_g0_4 { $v4 timeout 90s }
EOF
if rn nft -f "$work/rejected.nft" >"$work/rejected.log" 2>&1; then fail 'duplicate element unexpectedly committed'; fi
grep -qi 'File exists' "$work/rejected.log"
if rn nft get element inet podkopchik_native s_0011223344556677_m4 '{ 198.18.255.250 }' >/dev/null 2>&1; then fail 'partial kernel commit'; fi
echo 'PASS: rejected real nft batch left no partial map entry'

# An untouched IPv6 lease expires after the DNS TTL plus grace in the kernel.
sleep 33
if rn nft get element inet podkopchik_native s_0011223344556677_m6 "{ $v6 }" >/dev/null 2>&1; then fail 'expired IPv6 lease still active'; fi
blocked ln "http://[$v6]:18081/"
newv6=$(answer tcp protected.example. AAAA NOERROR 1)
[ -n "$newv6" ] && [ "$newv6" != "$v6" ]
ok ln "http://[$newv6]:18081/"
v4=$(answer tcp protected.example. A NOERROR 1)
echo 'PASS: actual kernel TTL expiry blocks stale IP; fresh DNS allocates a different address'

PKC_NATIVE_LAB=hold ip netns exec "$l" "$bin" -test.run='^TestGuestFixture$' -- "$v4:18081" "$work/hold-ready" "$work/hold-send" >"$work/hold.log" 2>&1 &
holdpid=$!; pids="$pids $holdpid"
for i in 1 2 3 4; do [ ! -e "$work/hold-ready" ] || break; sleep 1; done
[ -e "$work/hold-ready" ] || fail 'test connection did not open'

# Missing set in a real kernel: protected replies (even cached) must fail,
# and the already-issued DNAT conntrack tuple must not fall back to WAN.
rn nft flush chain inet podkopchik_native classify
rn nft delete set inet podkopchik_native s_0011223344556677_g0_4
touch "$work/hold-send"
wait "$holdpid" || { cat "$work/hold.log"; fail 'conntrack fail-closed'; }
query udp protected.example. A SERVFAIL 0
query tcp multiple.protected.example. A SERVFAIL 0
rn nft list map inet podkopchik_native s_0011223344556677_m4 > "$work/failed-dns-map"
if grep -q '203\.0\.113\.9[01]' "$work/failed-dns-map"; then fail 'failed DNS transaction partially committed'; fi
query tcp direct.example. A NOERROR 1
blocked ln "http://$v4:18081/"
blocked ln "http://[$newv6]:18081/"
ok ln 'http://203.0.113.80:18080/'
rn nft delete table inet podkopchik_native
blocked ln "http://$v4:18081/"
blocked rn 'http://198.19.255.254:18081/'
echo 'PASS: missing nft set/table => SERVFAIL and stale addresses blocked; direct remains available'

for pid in $caps; do kill -INT "$pid"; wait "$pid" || true; done
caps=""
for iface in external0 tunnel0 tunnel1; do grep -q '^0 packets dropped by kernel' "$work/cap-$iface.log"; done
count() { tcpdump -nn -r "$work/$1.pcap" "$2" 2>/dev/null | wc -l; }
leak=$(count external0 'dst port 18081 or net 198.18.0.0/15 or net 2001:2::/48')
direct=$(count external0 'dst port 18080')
endpoint=$(count external0 'dst port 18443')
primary=$(count tunnel0 'dst port 18081')
backup=$(count tunnel1 'dst port 18081')
printf 'WAN capture: protected=%s direct=%s endpoint=%s primary=%s backup=%s\n' "$leak" "$direct" "$endpoint" "$primary" "$backup"
[ "$leak" -eq 0 ] && [ "$direct" -gt 0 ] && [ "$endpoint" -gt 0 ] && [ "$primary" -gt 0 ] && [ "$backup" -gt 0 ]
echo 'PASS: native DNS VM acceptance (veth stand-ins, synthetic VLESS; not a router rollout)'
