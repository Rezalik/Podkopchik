#!/bin/sh
# Only the NIC-free disposable OpenWrt guest may execute this scenario.
set -eu
umask 077
fail() { echo "FAIL: $*" >&2; exit 1; }
. /mnt/lab/native-vm-only.sh
[ "$(uname -r)" = 6.12.112 ] || fail 'unexpected guest kernel'
[ -z "$(ip route show default)$(ip -6 route show default)" ] || fail 'guest has a default route'
lib=/mnt/lab/source
bin=/mnt/lab/native-dns.test
daemon=/mnt/lab/podkopchik-native-dns
xray=/mnt/lab/xray
work=$(mktemp -d /tmp/native-dns-vm.XXXXXX)
r="pkc-router-$$"; l="pkc-client-$$"; w="pkc-wan-$$"
pids=""; caps=""; namespaces=""
dns_service="pkc-vm-dns-$$"; guard_service="pkc-vm-watchdog-$$"
stock_service="pkc-vm-stock-$$"; xray_server="pkc-vm-xray-server-$$"; xray_client="pkc-vm-xray-client-$$"
initscript="$0"
service_triggers() { :; }
set +eu
. /lib/functions/procd.sh
set -eu
. /mnt/lab/procd-dns.sh
stop_service() { ubus call service delete "{\"name\":\"$1\"}" >/dev/null 2>&1 || true; }
vm_process() (
	set +eu
	name="$1"; shift
	procd_open_service "$name"
	native_dns_instance "$@"
	procd_close_service >/dev/null
)
service_pid() { ubus call service list "{\"name\":\"$1\"}" | jsonfilter -q -e '@.*.instances.main.pid'; }
wait_pid() {
	old="${2:-0}"
	for i in 1 2 3 4 5 6 7 8 9 10; do
		pid=$(service_pid "$1" || true)
		if [ -n "$pid" ] && [ "$pid" != "$old" ] && kill -0 "$pid" 2>/dev/null; then printf '%s\n' "$pid"; return; fi
		sleep 1
	done
	return 1
}
cleanup() {
	stop_service "$guard_service"
	stop_service "$dns_service"
	stop_service "$xray_client"
	stop_service "$xray_server"
	stop_service "$stock_service"
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
for mode in gate edge release forward primary backup down restore dns resources; do
	ucode -L "$lib" "$lib/native_dns_vm_plan.uc" "$mode" > "$work/$mode"
done
rn nft -f "$work/gate"
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
i=0
while read -r dev mark table prio; do
	i=$((i+1)); peer="tunnel$((i-1))"
	ip -n "$r" addr add "198.51.$i.1/24" dev "$dev"
	ip -n "$w" addr add "198.51.$i.2/24" dev "$peer"
	ip -n "$r" -6 addr add "2001:db8:$i::1/64" dev "$dev" nodad
	ip -n "$w" -6 addr add "2001:db8:$i::2/64" dev "$peer" nodad
	# These Ethernet stand-ins need neighbours; an AWG L3 device does not.
	peer_mac=$(ip -n "$w" link show "$peer" | awk '/link\/ether/ {print $2}')
	local_mac=$(ip -n "$r" link show "$dev" | awk '/link\/ether/ {print $2}')
	ip -n "$r" -6 neigh replace "2001:db8:$i::2" lladdr "$peer_mac" nud permanent dev "$dev"
	ip -n "$w" -6 neigh replace "2001:db8:$i::1" lladdr "$local_mac" nud permanent dev "$peer"
	ip -n "$r" rule add fwmark "$mark" table "$table" priority "$prio"
	ip -n "$r" -6 rule add fwmark "$mark" table "$table" priority "$prio"
	ip -n "$r" route add default via "198.51.$i.2" dev "$dev" table "$table" metric 100
	ip -n "$r" -6 route add default via "2001:db8:$i::2" dev "$dev" table "$table" metric 100
	ip -n "$r" route add unreachable default table "$table" metric 42760
	ip -n "$r" -6 route add unreachable default table "$table" metric 42760
done < "$work/resources"
cat > "$work/firewall" <<'EOF'
config defaults
	option input 'REJECT'
	option output 'ACCEPT'
	option forward 'REJECT'
	option flow_offloading '0'
	option flow_offloading_hw '0'
config zone
	option name 'lan'
	list device 'br-lan'
	option input 'ACCEPT'
	option output 'ACCEPT'
	option forward 'REJECT'
config zone
	option name 'wan'
	list device 'wan'
	option input 'REJECT'
	option output 'ACCEPT'
	option forward 'REJECT'
config forwarding
	option src 'lan'
	option dest 'wan'
config rule
	option name 'WAN IPv6 neighbor discovery'
	option src 'wan'
	option family 'ipv6'
	option proto 'icmp'
	list icmp_type 'neighbour-solicitation'
	list icmp_type 'neighbour-advertisement'
	option target 'ACCEPT'
EOF
cp "$work/firewall" "$work/firewall-base"
cat >> "$work/firewall" <<EOF
config include
	option type 'nftables'
	option path '$work/forward'
	option position 'chain-append'
	option chain 'forward'
EOF
cp "$work/firewall" "$work/firewall-deny"
cat >> "$work/firewall-deny" <<'EOF'
config rule
	option name 'Existing LAN deny takes precedence'
	option src 'lan'
	option dest '*'
	option dest_ip '203.0.113.81'
	option proto 'tcp'
	option dest_port '18081'
	option target 'REJECT'
EOF
load_fw4() {
	rn sh -c 'mount --bind "$1" /etc/config/firewall && fw4 print' fw4 "$1" > "$work/fw4.nft"
	rn nft -c -f "$work/fw4.nft"
	rn nft -f "$work/fw4.nft"
}
load_fw4 "$work/firewall-base"
cp "$work/fw4.nft" "$work/old-fw4.nft"
offload_check() {
	rn sh -c 'mount --bind "$1" /etc/config/firewall && sh /mnt/lab/check-offload.sh' preflight "$1"
}
offload_check "$work/firewall-base"
sed "s/option flow_offloading '0'/option flow_offloading '1'/" "$work/firewall-base" > "$work/firewall-sw"
sed "s/option flow_offloading_hw '0'/option flow_offloading_hw '1'/" "$work/firewall-base" > "$work/firewall-hw"
for config in "$work/firewall-sw" "$work/firewall-hw"; do
	if offload_check "$config" > "$work/offload.log" 2>&1; then fail 'configured offload passed preflight'; fi
	grep -q 'offloading must be disabled' "$work/offload.log"
done
rn nft add table inet pkc_test_offload
rn nft 'add flowtable inet pkc_test_offload ft { hook ingress priority 0; devices = { br-lan, wan }; }'
if offload_check "$work/firewall-base" > "$work/offload.log" 2>&1; then fail 'live software flowtable passed preflight'; fi
grep -q 'live flowtable' "$work/offload.log"
rn nft delete table inet pkc_test_offload
offload_check "$work/firewall-base"
echo 'PASS: read-only preflight rejects configured software/hardware offload and a real software flowtable'
rn nft -c -f "$work/primary"
rn nft -f "$work/primary"

for net in udp tcp; do
	PKC_NATIVE_LAB=dns ip netns exec "$r" "$bin" -test.run='^TestGuestFixture$' -- 127.0.0.1:1059 "$net" >"$work/dns-$net.log" 2>&1 & pids="$pids $!"
done
for addr in 192.0.2.2:53 '[2001:db8::2]:53'; do
	for net in udp tcp; do
		PKC_NATIVE_LAB=dns ip netns exec "$w" "$bin" -test.run='^TestGuestFixture$' -- "$addr" "$net" >"$work/external-$addr-$net.log" 2>&1 & pids="$pids $!"
	done
done
vm_process "$stock_service" /sbin/ip netns exec "$r" /usr/sbin/dnsmasq --no-daemon --conf-file=/dev/null --no-hosts --no-resolv --bind-interfaces \
	--listen-address=127.0.0.1,10.19.0.1 --server=127.0.0.1#1059 --pid-file="$work/dnsmasq.pid" \
	|| fail 'could not register stock dnsmasq with procd'
for addr in '203.0.113.80:18080' '203.0.113.80:18081' '203.0.113.81:18081' '[2001:db8:80::1]:18081'; do
	PKC_NATIVE_LAB=serve ip netns exec "$w" "$bin" -test.run='^TestGuestFixture$' -- "$addr" >"$work/peer-$addr.log" 2>&1 & pids="$pids $!"
done
ledger="$work/ledger"
if [ -n "${PKC_VM_PERSIST:-}" ]; then
	[ "$PKC_VM_PERSIST" = /etc/pkc-native-vm-state ] || fail 'unexpected persistent fixture path'
	ledger="$PKC_VM_PERSIST/ledger"
fi
[ -f "$ledger" ] || rn "$daemon" -config "$work/dns" -ledger "$ledger" -init-ledger
start_dns() {
	vm_process "$dns_service" /sbin/ip netns exec "$r" "$daemon" -config "$work/dns" -ledger "$ledger"
}
query_at() { PKC_NATIVE_LAB=query ln "$bin" -test.run='^TestGuestFixture$' -- "$@"; }
no_dns() { PKC_NATIVE_LAB=no-dns ln "$bin" -test.run='^TestGuestFixture$' -- "$@"; }
sleep 1
ip netns exec "$w" tcpdump --immediate-mode -U -i external0 -Q in -nn -s 96 -w "$work/boot-wan.pcap" \
	'net 198.18.0.0/15 or net 2001:2::/48 or port 53' >"$work/boot-cap.log" 2>&1 &
bootcap=$!; caps="$bootcap"
sleep 1
old4=198.19.255.254; old6=2001:2::dead
if [ "${PKC_VM_REBOOTED:-0}" = 1 ]; then read -r old4 old6 < "$PKC_VM_PERSIST/last-fake"; fi
if ln wget -q -T 1 -O - "http://$old4:18081/" || ln wget -q -T 1 -O - "http://[$old6]:18081/"; then
	fail 'old synthetic IP escaped before DNS activation'
fi
# Positive control before interception: these resolvers really return real IPs.
for addr in 10.19.0.1:53 192.0.2.2:53 '[2001:db8::2]:53'; do
	answer=$(query_at "$addr" udp probe.protected.example. A NOERROR 1) || fail "initial resolver unavailable at $addr: $answer"
	printf '%s\n' "$answer" | grep -qx 'address=203.0.113.80'
done
kill -INT "$bootcap"; wait "$bootcap" || true
caps=""
grep -q '^0 packets dropped by kernel' "$work/boot-cap.log"
boot_leak=$(tcpdump -nn -r "$work/boot-wan.pcap" 'net 198.18.0.0/15 or net 2001:2::/48' 2>/dev/null | wc -l)
boot_dns=$(tcpdump -nn -r "$work/boot-wan.pcap" 'dst port 53' 2>/dev/null | wc -l)
echo "Early WAN capture: synthetic=$boot_leak direct_dns=$boot_dns"
[ "$boot_leak" -eq 0 ] && [ "$boot_dns" -gt 0 ] || fail 'early WAN capture did not establish quarantine'
echo 'PASS: early pool guard blocks stale/unknown IPv4 and IPv6 before managed DNS activation'
rn nft -f "$work/edge"
start_dns
dnspid=$(wait_pid "$dns_service") || fail 'procd did not start DNS'
echo 'PASS: stock DNS, fw4 and transport policy are ready before managed procd listener'
for iface in external0 tunnel0 tunnel1; do
	ip netns exec "$w" tcpdump -i "$iface" -Q in -nn -s 96 -c 1024 -w "$work/$iface.pcap" \
		'net 198.18.0.0/15 or net 2001:2::/48 or port 53 or port 18080 or port 18081 or port 18443' >"$work/cap-$iface.log" 2>&1 &
	caps="$caps $!"
done
sleep 1
kill -0 "$dnspid"
query() { query_at 10.19.0.1:53 "$@"; }
answer() { query "$@" | sed -n 's/^address=//p'; }
http() { "$1" wget -q -T 2 -O - "$2"; }
ok() { [ "$(http "$1" "$2")" = isolated-http-ok ]; }
blocked() { if http "$1" "$2" >/dev/null 2>&1; then fail 'protected HTTP succeeded unexpectedly'; fi; }
udp() { PKC_NATIVE_LAB=udp "$1" "$bin" -test.run='^TestGuestFixture$' -- "$2"; }

v4=$(answer udp protected.example. A NOERROR 1); case "$v4" in 198.18.*) ;; *) fail 'no synthetic IPv4 answer' ;; esac
v6=$(answer tcp protected.example. AAAA NOERROR 1); case "$v6" in 2001:2:*) ;; *) fail 'no synthetic IPv6 answer' ;; esac
if [ -n "${PKC_VM_PERSIST:-}" ]; then
	if [ "${PKC_VM_REBOOTED:-0}" = 1 ]; then
		read -r previous4 previous6 < "$PKC_VM_PERSIST/last-fake"
		[ "$v4" != "$previous4" ] && [ "$v6" != "$previous6" ] || fail 'synthetic address reused after reboot'
		blocked ln "http://$previous4:18081/"
		blocked ln "http://[$previous6]:18081/"
		echo 'PASS: pre-reboot synthetic addresses are blocked after procd boot'
	else
		printf '%s %s\n' "$v4" "$v6" > "$PKC_VM_PERSIST/last-fake"
	fi
fi
[ "$(answer tcp protected.example. A NOERROR 1)" = "$v4" ]
[ "$(answer udp direct.example. A NOERROR 1)" = 203.0.113.80 ]
for addr in 192.0.2.2:53 '[fd19::1]:53' '[2001:db8::2]:53'; do
	for net in udp tcp; do query_at "$addr" "$net" protected.example. A NOERROR 1 | grep -qx "address=$v4"; done
done
no_dns 10.19.0.1:1058 udp protected.example.
no_dns '[fd19::1]:1058' tcp protected.example.
blocked ln "http://$v4:18081/"
ok ln 'http://203.0.113.80:18080/'
load_fw4 "$work/firewall"
ok ln "http://$v4:18081/"
load_fw4 "$work/firewall"
rn nft get element inet podkopchik_native s_0011223344556677_m4 "{ $v4 }" >/dev/null
ok ln "http://$v4:18081/"
echo 'PASS: managed LAN DNS on port 53, listener isolation, real fw4 default policy and include reload'
clients=""
for i in 1 2 3 4 5 6 7 8; do
	net=udp; [ "$((i % 2))" != 0 ] || net=tcp
	PKC_NATIVE_LAB=query ip netns exec "$l" "$bin" -test.run='^TestGuestFixture$' -- 10.19.0.1:53 "$net" \
		protected.example. A NOERROR 1 >"$work/concurrent-$i.log" 2>&1 & clients="$clients $!"
done
rn nft -f "$work/backup"
rn nft -f "$work/backup"
rn nft -f "$work/restore"
client_error=0
for pid in $clients; do wait "$pid" || client_error=1; done
[ "$client_error" = 0 ] || fail 'concurrent protected DNS query failed'
for i in 1 2 3 4 5 6 7 8; do grep -qx "address=$v4" "$work/concurrent-$i.log"; done
ok ln "http://$v4:18081/"
ok ln "http://[$v6]:18081/"
ok ln 'http://203.0.113.81:18081/'
load_fw4 "$work/firewall-deny"
blocked ln 'http://203.0.113.81:18081/'
ok ln "http://$v4:18081/"
load_fw4 "$work/firewall"
ok ln 'http://203.0.113.81:18081/'
echo 'PASS: an existing firewall4 deny still takes precedence over the native include'
ok ln 'http://203.0.113.80:18080/'
udp ln "$v4:18081"
udp ln "[$v6]:18081"
echo 'PASS: committed DNS UDP/TCP, native IPv4/IPv6 TCP/UDP, protected CIDR and ordinary direct'

kill -KILL "$dnspid"
dnspid=$(wait_pid "$dns_service" "$dnspid") || fail 'procd did not respawn DNS'
sleep 1
new4=$(answer tcp protected.example. A NOERROR 1)
new6=$(answer udp protected.example. AAAA NOERROR 1)
[ -n "$new4" ] && [ "$new4" != "$v4" ] && [ -n "$new6" ] && [ "$new6" != "$v6" ] || fail 'bad DNS recovery or recycled address'
v4="$new4"; v6="$new6"
ok ln "http://$v4:18081/"
stop_service "$dns_service"
no_dns 10.19.0.1:53 tcp protected.example.
start_dns
dnspid=$(wait_pid "$dns_service") || fail 'procd restart failed'
sleep 1
new4=$(answer udp protected.example. A NOERROR 1)
[ -n "$new4" ] && [ "$new4" != "$v4" ] || fail 'restart reused a synthetic address'
v4="$new4"
echo 'PASS: procd stop/start and SIGKILL recovery without DNS fallback or address reuse'

rn nft -f "$work/backup"
[ "$(answer udp protected.example. A NOERROR 1)" = "$v4" ]
ok ln "http://$v4:18081/"
ok ln "http://[$v6]:18081/"
rn nft -f "$work/down"
blocked ln "http://$v4:18081/"
blocked ln "http://[$v6]:18081/"
ok ln 'http://203.0.113.80:18080/'
echo 'PASS: existing lease survives failover; all-down fails closed while direct works'

ip -n "$r" link set wan down
blocked ln 'http://203.0.113.80:18080/'
ip -n "$r" link set wan up
ip -n "$r" addr replace 192.0.2.1/24 dev wan
ip -n "$r" -6 addr replace 2001:db8:0::1/64 dev wan nodad
ip -n "$r" route replace default via 192.0.2.2 dev wan
ip -n "$r" -6 route replace default via 2001:db8:0::2 dev wan
ok ln 'http://203.0.113.80:18080/'
echo 'PASS: isolated WAN link loss and route restoration'

cat >"$work/xray-server.json" <<'EOF'
{"log":{"loglevel":"warning"},"inbounds":[{"listen":"192.0.2.2","port":18443,"protocol":"vless","settings":{"decryption":"none","clients":[{"id":"11111111-2222-4333-8444-555555555555"}]}}],"outbounds":[{"protocol":"freedom"}]}
EOF
cat >"$work/xray-client.json" <<'EOF'
{"log":{"loglevel":"warning"},"inbounds":[{"listen":"127.0.0.1","port":1080,"protocol":"socks"}],"outbounds":[{"sendThrough":"10.19.0.3","protocol":"vless","settings":{"vnext":[{"address":"192.0.2.2","port":18443,"users":[{"id":"11111111-2222-4333-8444-555555555555","encryption":"none"}]}]}}]}
EOF
wn "$xray" run -test -config "$work/xray-server.json"
ln "$xray" run -test -config "$work/xray-client.json"
vm_xray() {
	vm_process "$1" /bin/sh -c 'log="$1"; shift; exec "$@" >"$log" 2>&1' xray "$work/$3.log" \
		/sbin/ip netns exec "$2" "$xray" run -config "$work/$3.json"
}
vm_xray "$xray_server" "$w" xray-server
vm_xray "$xray_client" "$l" xray-client
serverpid=$(wait_pid "$xray_server") || fail 'Xray server process not started'
clientpid=$(wait_pid "$xray_client") || fail 'Xray client process not started'
i=0
until grep -q 'Xray .* started' "$work/xray-server.log" && grep -q 'Xray .* started' "$work/xray-client.log"; do
	kill -0 "$serverpid" "$clientpid" && [ "$i" -lt 10 ] || { cat "$work/xray-server.log" "$work/xray-client.log"; fail 'Xray fixture not ready'; }
	sleep 1; i=$((i+1))
done
PKC_NATIVE_LAB=socks ln "$bin" -test.run='^TestGuestFixture$' -- 127.0.0.1:1080 203.0.113.80:18081
echo 'PASS: separate Xray/VLESS connection and endpoint bypass with native selection all-down'

rn nft -f "$work/restore"
stop_service "$xray_client"
ok ln "http://$v4:18081/"
vm_xray "$xray_client" "$l" xray-client
wait_pid "$xray_client" "$clientpid" >/dev/null || fail 'Xray client restart failed'
ok ln "http://$v4:18081/"
echo 'PASS: Xray procd stop/start did not interrupt native forwarding'
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

(cd "$work" && sha256sum old-fw4.nft release > backup.sha256)
mkdir -m 700 "$work/confirm-trial"
ucode /mnt/lab/trial-state.uc arm "$work/confirm-trial" 30
if ucode /mnt/lab/trial-state.uc confirm "$work/confirm-trial" >/dev/null 2>&1; then fail 'unverified trial confirmed'; fi
ucode /mnt/lab/trial-state.uc verify "$work/confirm-trial"
ucode /mnt/lab/trial-state.uc confirm "$work/confirm-trial"
[ "$(ucode /mnt/lab/trial-state.uc poll "$work/confirm-trial")" = confirmed ]
echo 'PASS: trial confirmation requires a separate verification transition'
ucode /mnt/lab/trial-state.uc arm "$work" 25
(
	set +eu
	procd_open_service "$guard_service"
	procd_open_instance main
	procd_set_param command /bin/sh /mnt/lab/native-vm-watchdog.sh "$r" "$work" "$dns_service"
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
	procd_close_service >/dev/null
)
wait_pid "$guard_service" >/dev/null || fail 'independent watchdog not running'
stop_service "$dns_service"
for addr in 10.19.0.1:53 192.0.2.2:53 '[2001:db8::2]:53'; do
	for net in udp tcp; do no_dns "$addr" "$net" protected.example.; done
done
rn nft flush chain inet podkopchik_native_gate dns_lan
for addr in 10.19.0.1:53 192.0.2.2:53 '[2001:db8::2]:53'; do
	for net in udp tcp; do no_dns "$addr" "$net" protected.example.; done
done
ok ln 'http://203.0.113.80:18080/'
echo 'PASS: stopped listener and lost redirect do not fall back to stock or WAN DNS'

for pid in $caps; do kill -INT "$pid"; wait "$pid" || true; done
caps=""
for iface in external0 tunnel0 tunnel1; do grep -q '^0 packets dropped by kernel' "$work/cap-$iface.log"; done
count() { tcpdump -nn -r "$work/$1.pcap" "$2" 2>/dev/null | wc -l; }
leak=$(count external0 'dst port 18081 or net 198.18.0.0/15 or net 2001:2::/48')
direct=$(count external0 'dst port 18080')
endpoint=$(count external0 'dst port 18443')
primary=$(count tunnel0 'dst port 18081')
backup=$(count tunnel1 'dst port 18081')
plaintext_dns=$(count external0 'port 53')
printf 'WAN capture: protected=%s plaintext_dns=%s direct=%s endpoint=%s primary=%s backup=%s\n' "$leak" "$plaintext_dns" "$direct" "$endpoint" "$primary" "$backup"
[ "$leak" -eq 0 ] && [ "$plaintext_dns" -eq 0 ] && [ "$direct" -gt 0 ] && [ "$endpoint" -gt 0 ] && [ "$primary" -gt 0 ] && [ "$backup" -gt 0 ]
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do
	[ ! -f "$work/rollback-done" ] || break
	sleep 1
done
[ -f "$work/rollback-done" ] || fail 'independent watchdog did not restore DNS'
[ "$(ucode /mnt/lab/trial-state.uc poll "$work")" = restored ]
if ucode /mnt/lab/trial-state.uc confirm "$work" >/dev/null 2>&1; then fail 'late confirmation after rollback'; fi
ip netns exec "$w" tcpdump --immediate-mode -U -i external0 -Q in -nn -s 96 -w "$work/rollback-wan.pcap" \
	'net 198.18.0.0/15 or net 2001:2::/48 or port 18080' >"$work/rollback-cap.log" 2>&1 &
rollbackcap=$!; caps="$rollbackcap"
sleep 1
query_at 10.19.0.1:53 tcp probe.protected.example. A NOERROR 1 | grep -qx 'address=203.0.113.80'
blocked ln "http://$v4:18081/"
blocked ln "http://[$newv6]:18081/"
blocked rn "http://$v4:18081/"
blocked rn "http://[$newv6]:18081/"
ok ln 'http://203.0.113.80:18080/'
kill -INT "$rollbackcap"; wait "$rollbackcap" || true
caps=""
grep -q '^0 packets dropped by kernel' "$work/rollback-cap.log"
rollback_leak=$(count rollback-wan 'net 198.18.0.0/15 or net 2001:2::/48')
rollback_direct=$(count rollback-wan 'dst port 18080')
echo "Rollback WAN capture: synthetic=$rollback_leak direct=$rollback_direct"
[ "$rollback_leak" -eq 0 ] && [ "$rollback_direct" -gt 0 ] || fail 'rollback WAN capture did not establish quarantine'
echo 'PASS: independent procd timeout restores stock DNS and preserves quarantine'
echo 'PASS: native DNS VM acceptance (veth stand-ins, synthetic VLESS; not a router rollout)'
