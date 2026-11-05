#!/bin/sh
# AX6000-only lab. All addresses, routes, listeners and nft tables are private.
set -eu
umask 077
[ "$(cat /tmp/sysinfo/board_name)" = xiaomi,redmi-router-ax6000-stock ]
root="${1:?private lab directory required}"
case "$root" in /tmp/podkopchik-universal-lab-*) ;; *) exit 2 ;; esac
case "$root" in *[!A-Za-z0-9_./-]*) exit 2 ;; esac
lib="$root/source"
work="$root/kernel-$$"
mkdir "$work" "$work/conf" "$work/run" "$work/www"
export PODKOPCHIK_LIB="$lib" PODKOPCHIK_CONFIG_DIR="$work/conf" PODKOPCHIK_TMP_DIR="$work/run"
export LD_LIBRARY_PATH="$root/sandbox/usr/lib:$root/sandbox/lib"
dump="$root/sandbox/usr/bin/tcpdump"
full="$root/sandbox/usr/sbin/dnsmasq"
core=/usr/bin/xray
if [ -n "${LAB_XRAY_SHA256:-}" ]; then
	core="$root/xray-candidate"
	[ "$(sha256sum "$core" | awk '{print $1}')" = "$LAB_XRAY_SHA256" ]
fi
r="pkc-r-$$"; l="pkc-l-$$"; w="pkc-w-$$"
names=""; pids=""; xpid=""; cap=""
cleanup() {
	for pid in $pids $xpid $cap; do kill -TERM "$pid" 2>/dev/null || true; done
	for pid in $pids $xpid $cap; do wait "$pid" 2>/dev/null || true; done
	for ns in $names; do ip netns del "$ns" 2>/dev/null || true; done
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
rn() { ip netns exec "$r" "$@"; }
ln() { ip netns exec "$l" "$@"; }
http() { ns="$1"; shift; ip netns exec "$ns" curl --noproxy '*' --silent --show-error --fail --connect-timeout 2 --max-time 4 "$@"; }
for ns in "$r" "$l" "$w"; do
	ip netns add "$ns"; names="$names $ns"
	ip -n "$ns" link set lo up
done
ip -n "$r" link add br-lan type veth peer name client0
ip -n "$r" link set client0 netns "$l"
ip -n "$r" link add wan type veth peer name external0
ip -n "$r" link set external0 netns "$w"
ip -n "$r" link add paw111111111111 type veth peer name tunnel0
ip -n "$r" link set tunnel0 netns "$w"
for dev in br-lan wan paw111111111111; do ip -n "$r" link set "$dev" up; done
ip -n "$l" link set client0 up
for dev in external0 tunnel0; do ip -n "$w" link set "$dev" up; done
ip -n "$r" address add 10.19.0.1/24 dev br-lan
ip -n "$l" address add 10.19.0.2/24 dev client0
ip -n "$r" address add 192.0.2.1/24 dev wan
ip -n "$w" address add 192.0.2.2/24 dev external0
ip -n "$r" address add 198.51.100.1/24 dev paw111111111111
ip -n "$w" address add 198.51.100.2/24 dev tunnel0
ip -n "$w" address add 203.0.113.80/32 dev lo
ip -n "$r" -6 address add fd00:19::1/64 dev br-lan nodad
ip -n "$l" -6 address add fd00:19::2/64 dev client0 nodad
ip -n "$r" -6 address add 2001:db8:2::1/64 dev wan nodad
ip -n "$w" -6 address add 2001:db8:2::2/64 dev external0 nodad
ip -n "$r" route add default via 192.0.2.2 dev wan
ip -n "$l" route add default via 10.19.0.1 dev client0
ip -n "$w" route add 10.19.0.0/24 via 192.0.2.1 dev external0
ip -n "$r" -6 route add default via 2001:db8:2::2 dev wan
ip -n "$l" -6 route add default via fd00:19::1 dev client0
ip -n "$w" -6 route add fd00:19::/64 via 2001:db8:2::1 dev external0
rn sysctl -w net.ipv4.ip_forward=1 >/dev/null
rn sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
for family in -4 -6; do
	ip -n "$r" "$family" rule add fwmark 0x100000 table 10991 priority 10991
	ip -n "$r" "$family" route add local default dev lo table 10991
done
printf '%s\n' podkopchik-routing-v1 > "$work/run/routing.env"
printf '%s\n' podkopchik-routing6-v1 > "$work/run/routing6.env"
ip -n "$r" -4 rule add fwmark 536918082 table 47170 priority 20000 protocol 186
ip -n "$r" -4 route add default via 198.51.100.2 dev paw111111111111 table 47170 metric 100
ip -n "$r" -4 route add unreachable default table 47170 metric 42760 protocol 186
printf '%s\n' 'isolated-payload-ok' > "$work/www/index.html"
chmod 644 "$work/www/index.html"
ip netns exec "$w" uhttpd -f -p 192.0.2.2:18080 -p 203.0.113.80:18081 -h "$work/www" >"$work/http.log" 2>&1 & pids="$pids $!"
ip netns exec "$r" /usr/sbin/dnsmasq --no-daemon --no-hosts --no-resolv --port=1056 --listen-address=127.0.0.1 --bind-interfaces \
	--pid-file="$work/dns.pid" --host-record=known.pkc.invalid,203.0.113.80 --local-ttl=15 >"$work/dns.log" 2>&1 & pids="$pids $!"
ip netns exec "$w" /usr/sbin/dnsmasq --no-daemon --no-hosts --no-resolv --port=1056 --listen-address=203.0.113.80 --bind-interfaces \
	--pid-file="$work/udp.pid" --host-record=udp.pkc.invalid,203.0.113.80 >"$work/udp.log" 2>&1 & pids="$pids $!"
cat > "$work/tproxy.nft" <<'EOF'
add table inet podkopchik
add chain inet podkopchik prerouting { type filter hook prerouting priority mangle; policy accept; }
add rule inet podkopchik prerouting iifname "br-lan" ip daddr 198.18.0.0/15 meta l4proto { tcp, udp } meta mark set 0x100000 tproxy ip to :12345 accept
add rule inet podkopchik prerouting iifname "br-lan" ip6 daddr 2001:2::/48 meta l4proto { tcp, udp } meta mark set 0x100000 tproxy ip6 to :12345 accept
EOF
rn nft -f "$work/tproxy.nft"
cat > "$work/conf/config.json" <<'EOF'
{
  "log":{"loglevel":"debug"},
  "inbounds":[
    {"tag":"transparent","protocol":"dokodemo-door","port":12345,"settings":{"network":"tcp,udp","followRedirect":true},"streamSettings":{"sockopt":{"tproxy":"tproxy"}},"sniffing":{"enabled":true,"metadataOnly":true,"destOverride":["fakedns"],"routeOnly":false}},
    {"tag":"dns-in","protocol":"dokodemo-door","listen":"0.0.0.0","port":1053,"settings":{"network":"tcp,udp","address":"127.0.0.1","port":1056}}
  ],
  "outbounds":[
    {"tag":"direct","protocol":"freedom"},
    {"tag":"blocked","protocol":"blackhole"},
    {"tag":"dns-out","protocol":"dns"},
    {"tag":"awg","protocol":"freedom","streamSettings":{"sockopt":{"interface":"paw111111111111","mark":536918082,"domainStrategy":"ForceIPv4"}}}
  ],
  "dns":{"queryStrategy":"UseIPv4","servers":["fakedns",{"address":"127.0.0.1","port":1056}]},
  "fakedns":[{"ipPool":"198.18.0.0/15","poolSize":1024},{"ipPool":"2001:2::/48","poolSize":1024}],
  "routing":{"domainStrategy":"AsIs","rules":[
    {"type":"field","inboundTag":["dns-in"],"outboundTag":"dns-out"},
    {"type":"field","ip":["198.18.0.0/15","2001:2::/48"],"outboundTag":"blocked"},
    {"type":"field","domain":["domain:known.pkc.invalid"],"outboundTag":"awg"}
  ]}
}
EOF
cp "$work/conf/config.json" "$work/working.json"
rn sh "$lib/fakedns_guard.sh" sync
rn sh "$lib/fakedns_guard.sh" sync
rn sh "$lib/fakedns_guard.sh" status | grep -qx 'state=active'
rn sh "$lib/routing_safety.sh" save
ip netns exec "$w" "$dump" -i external0 -Q in -nn -s 64 -c 512 -w "$work/wan.pcap" \
	'dst net 198.18.0.0/15 or dst net 2001:2::/48 or (dst host 192.0.2.2 and tcp dst port 18080)' >"$work/wan.log" 2>&1 & cap=$!
ip netns exec "$w" "$dump" -i tunnel0 -Q in -nn -s 64 -c 512 -w "$work/awg.pcap" \
	'dst host 203.0.113.80 and (tcp dst port 18081 or udp dst port 1056)' >"$work/awg.log" 2>&1 & pids="$pids $!"; awgcap=$!
start_xray() {
	rn "$core" run -test -config "$work/conf/config.json" >"$work/xray-validate.log" 2>&1
	ip netns exec "$r" "$core" run -config "$work/conf/config.json" >"$work/xray.log" 2>&1 & xpid=$!
	sleep 1
	kill -0 "$xpid"
}
stop_xray() { kill -TERM "$xpid"; wait "$xpid" || true; xpid=""; }
lookup() { ln nslookup -type=A -timeout=2 -retry=1 -port=1053 known.pkc.invalid 10.19.0.1 | awk '/^Address: 198\.(18|19)\./ {print $2; exit}'; }
bad_http() { if "$@" >/dev/null 2>&1; then echo 'unexpected fake-address HTTP success' >&2; exit 1; fi; }
probe_unknown() {
	bad_http http "$l" 'http://198.19.255.254:18080/'
	bad_http http "$r" 'http://198.19.255.253:18080/'
	bad_http http "$l" -g 'http://[2001:2::dead]:18080/'
	bad_http http "$r" -g 'http://[2001:2::beef]:18080/'
	ln nslookup -timeout=1 -retry=1 -port=9 synthetic.invalid 198.19.255.254 >/dev/null 2>&1 || true
	rn nslookup -timeout=1 -retry=1 -port=9 synthetic.invalid 198.19.255.253 >/dev/null 2>&1 || true
	ln nslookup -timeout=1 -retry=1 -port=9 synthetic.invalid 2001:2::dead >/dev/null 2>&1 || true
	rn nslookup -timeout=1 -retry=1 -port=9 synthetic.invalid 2001:2::beef >/dev/null 2>&1 || true
}
start_xray
fake=$(lookup)
[ -n "$fake" ]
http "$l" --resolve "known.pkc.invalid:18081:$fake" http://known.pkc.invalid:18081/index.html | grep -qx isolated-payload-ok
http "$l" http://192.0.2.2:18080/index.html | grep -qx isolated-payload-ok
ln nslookup -type=A -timeout=2 -retry=1 -port=1056 udp.pkc.invalid "$fake" | grep -q '203.0.113.80'
echo 'Known FakeDNS -> Xray -> isolated transport link TCP/UDP and ordinary direct: PASS'
probe_unknown
stop_xray
probe_unknown
bad_http http "$l" "http://$fake:18081/"
http "$l" http://192.0.2.2:18080/index.html | grep -qx isolated-payload-ok
echo 'Unknown IPv4/IPv6 and stopped Xray, LAN + router: DROP; direct remains available'

# Force the active target to blackhole without touching any live AWG profile.
sed 's/{"tag":"awg","protocol":"freedom".*}/{"tag":"awg","protocol":"blackhole"}/' "$work/working.json" > "$work/conf/config.json"
start_xray
newfake=$(lookup); [ -n "$newfake" ]
bad_http http "$l" "http://$newfake:18081/"
bad_http http "$l" "http://$fake:18081/"
stop_xray
echo 'All-down and stale fake cache: DROP'

# The failed transaction cannot remove the old interception or quarantine.
printf '%s\n' 'delete table inet podkopchik' 'invalid nft transaction' > "$work/bad.nft"
if rn nft -f "$work/bad.nft" >/dev/null 2>&1; then exit 1; fi
probe_unknown
rn sh "$lib/routing_safety.sh" restore
rn sh "$lib/routing_safety.sh" unguard
cmp "$work/working.json" "$work/conf/config.json"
probe_unknown
start_xray
fake=$(lookup); [ -n "$fake" ]
http "$l" --resolve "known.pkc.invalid:18081:$fake" http://known.pkc.invalid:18081/index.html | grep -qx isolated-payload-ok
echo 'Failed Apply batch and actual working-state restore: fake egress blocked, known transport restored'

# Stock dnsmasq-full is not a transactional classifier: the response can be
# handed to a client even when the destination nft set does not exist.
ip netns exec "$r" "$full" --no-daemon --no-hosts --no-resolv --port=1057 --listen-address=127.0.0.1 --bind-interfaces \
	--pid-file="$work/full.pid" --server=127.0.0.1#1056 --nftset=/known.pkc.invalid/4#inet#pkc_missing#v4 >"$work/full.log" 2>&1 & pids="$pids $!"
sleep 1
rn nslookup -type=A -timeout=2 -retry=1 -port=1057 known.pkc.invalid 127.0.0.1 | grep -q '203.0.113.80'
grep -q 'nftset' "$work/full.log"
echo 'Stock dnsmasq-full atomic classification: FAIL reproduced (answer despite missing set)'

kill -INT "$cap" "$awgcap"
wait "$cap" || true
wait "$awgcap" || true
cap=""
fake_frames=$("$dump" -nn -r "$work/wan.pcap" 'dst net 198.18.0.0/15 or dst net 2001:2::/48' 2>/dev/null | wc -l)
direct_frames=$("$dump" -nn -r "$work/wan.pcap" 'dst host 192.0.2.2 and tcp dst port 18080' 2>/dev/null | wc -l)
awg_tcp=$("$dump" -nn -r "$work/awg.pcap" 'tcp dst port 18081' 2>/dev/null | wc -l)
awg_udp=$("$dump" -nn -r "$work/awg.pcap" 'udp dst port 1056' 2>/dev/null | wc -l)
printf 'private WAN capture fake=%s direct=%s transport_tcp=%s transport_udp=%s\n' "$fake_frames" "$direct_frames" "$awg_tcp" "$awg_udp"
[ "$fake_frames" -eq 0 ] && [ "$direct_frames" -gt 0 ] && [ "$awg_tcp" -gt 0 ] && [ "$awg_udp" -gt 0 ]
grep -q '^0 packets dropped by kernel' "$work/wan.log"
echo 'Kernel FakeDNS laboratory PASS (transport stand-in, not live AWG failure injection)'

# Reuse the private links, but remove all Xray interception. Test real
# prerouting marks and forwarding with veth adapters, not AWG credentials.
stop_xray
rn nft delete table inet podkopchik
ip -n "$r" link add paw222222222222 type veth peer name tunnel1
ip -n "$r" link set tunnel1 netns "$w"
ip -n "$r" link set paw222222222222 up
ip -n "$w" link set tunnel1 up
ip -n "$r" address add 198.51.101.1/24 dev paw222222222222
ip -n "$w" address add 198.51.101.2/24 dev tunnel1
ip -n "$l" address add 10.19.0.3/24 dev client0
ip -n "$l" address add 10.19.0.4/24 dev client0
ip -n "$r" -4 route del default table 47170 metric 100
ip -n "$r" -4 rule del fwmark 536918082 table 47170 priority 20000 protocol 186
for pair in '11111111111111111111111111111111 198.51.100.2' '22222222222222222222222222222222 198.51.101.2'; do
	set -- $pair
	id="$1"; gateway="$2"
	set -- $(ucode -L "$lib" -e 'let r=require("awg_network").resources(ARGV[0]); printf("%d %d %d %s",r.mark,r.table,r.priority,r.interface);' -- "$id")
	ip -n "$r" -4 rule add fwmark "$1" table "$2" priority "$3" protocol 186
	ip -n "$r" -4 route add default via "$gateway" dev "$4" table "$2" metric 100
	ip -n "$r" -4 route add unreachable default table "$2" metric 42760 protocol 186
done
for step in initial failover down; do
	ucode -L "$lib" "$lib/universal_plan_smoke.uc" "$step" > "$work/native-$step.nft"
done
rn nft -c -f "$work/native-initial.nft"
rn nft -f "$work/native-initial.nft"
# Simulate a committed DNS answer, then verify it survives target switches.
rn nft add element inet podkopchik_native quarantine4 '{ 203.0.113.80 }'
rn nft add element inet podkopchik_native domain_0_4 '{ 203.0.113.80 timeout 90s }'
for iface in external0 tunnel0 tunnel1; do
	ip netns exec "$w" "$dump" -i "$iface" -Q in -nn -s 64 -c 512 -w "$work/native-$iface.pcap" \
		'tcp dst port 18080 or tcp dst port 18081' >"$work/native-$iface.log" 2>&1 &
	pids="$pids $!"; case "$iface" in external0) directcap=$! ;; tunnel0) maincap=$! ;; tunnel1) backupcap=$! ;; esac
done
sleep 1
http "$l" http://203.0.113.80:18081/index.html | grep -qx isolated-payload-ok
http "$l" http://192.0.2.2:18080/index.html | grep -qx isolated-payload-ok
# Force the marked traffic to fall back to main if the filter is ineffective.
main_mark=$(ucode -L "$lib" -e 'print(require("awg_network").resources("11111111111111111111111111111111").mark);')
ip -n "$r" route add 203.0.113.80/32 via 192.0.2.2 dev wan
ip -n "$r" rule del fwmark "$main_mark"
bad_http http "$l" http://203.0.113.80:18081/index.html
rn nft -f "$work/native-failover.nft"
rn nft get element inet podkopchik_native domain_0_4 '{ 203.0.113.80 }' >/dev/null
http "$l" http://203.0.113.80:18081/index.html | grep -qx isolated-payload-ok
http "$l" --interface 10.19.0.4 http://203.0.113.80:18081/index.html | grep -qx isolated-payload-ok
rn nft -f "$work/native-down.nft"
bad_http http "$l" http://203.0.113.80:18081/index.html
bad_http http "$l" --interface 10.19.0.4 http://203.0.113.80:18081/index.html
rn nft delete element inet podkopchik_native domain_0_4 '{ 203.0.113.80 }'
bad_http http "$l" http://203.0.113.80:18081/index.html
http "$l" http://192.0.2.2:18080/index.html | grep -qx isolated-payload-ok
for pid in "$directcap" "$maincap" "$backupcap"; do kill -INT "$pid"; wait "$pid" || true; done
for iface in external0 tunnel0 tunnel1; do grep -q '^0 packets dropped by kernel' "$work/native-$iface.log"; done
leak=$("$dump" -nn -r "$work/native-external0.pcap" 'tcp dst port 18081' 2>/dev/null | wc -l)
direct=$("$dump" -nn -r "$work/native-external0.pcap" 'tcp dst port 18080' 2>/dev/null | wc -l)
primary=$("$dump" -nn -r "$work/native-tunnel0.pcap" 'tcp dst port 18081' 2>/dev/null | wc -l)
backup=$("$dump" -nn -r "$work/native-tunnel1.pcap" 'tcp dst port 18081' 2>/dev/null | wc -l)
printf 'private native capture protected_wan=%s direct_wan=%s primary=%s backup=%s\n' "$leak" "$direct" "$primary" "$backup"
[ "$leak" -eq 0 ] && [ "$direct" -gt 0 ] && [ "$primary" -gt 0 ] && [ "$backup" -gt 0 ]
echo 'Native planner laboratory PASS: pre-transport classification, lost policy, failover, all-down, expired classification'
