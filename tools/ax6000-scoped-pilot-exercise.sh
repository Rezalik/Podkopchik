#!/bin/sh
# Run only after the independently verified, still-down pilot has been armed.
set -eu
umask 077
[ "$(cat /tmp/sysinfo/board_name)" = xiaomi,redmi-router-ax6000-stock ] && [ "$(uname -r)" = 6.12.112 ] || exit 2
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$root"
sha256sum -c SHA256SUMS
get() { jsonfilter -i run.json -e "@.$1"; }
epoch=$(get epoch); port=$(get port); ns=$(get ns); owner=$(get owner)
awg=$(get awg); wan=$(get wan); outer=$(get outer); outerport=$(get outer_port)
https=$(get https); udp=$(get udp); udp_port=$(get udp_port); direct=$(get direct); awgsrc=$(get source)
[ -n "$udp" ] && [ "$udp" != "$https" ] && [ "$udp" != "$direct" ]
case "$udp_port" in ''|*[!0-9]*) exit 2 ;; esac
[ "$udp_port" -ge 1024 ] && [ "$udp_port" -le 65535 ]
obs="/tmp/pkc-observe-$epoch"
[ "$root" = "/tmp/pkc-vpilot.$epoch" ] && [ "$port" = "pv$(printf %.12s "$epoch")" ] &&
	[ "$owner" = "pkc-virtual-$epoch" ] && [ "$ns" = "pkcv-$epoch" ] && [ "$wan" = wan ] || exit 2
case "$epoch" in *[!0-9a-f]*) exit 2 ;; esac
(cd "$obs" && sha256sum -c SHA256SUMS)
trap 'ucode "$root/trial-state.uc" abort "$root" >/dev/null 2>&1 || true' EXIT
trap 'exit 1' HUP INT TERM
remaining() {
	local end now
	[ "$(ucode trial-state.uc poll "$root")" = waiting ] || return 1
	end=$(jsonfilter -i trial.json -e '@.deadline')
	now=$(cut -d. -f1 /proc/uptime)
	[ "$((end-now))" -ge "$1" ]
}
remaining 75
[ -f ledger ] && [ ! -L ledger ]
if netstat -lntu | grep -Eq '[:.](24053|24156)[[:space:]]'; then exit 1; fi
client() { ip netns exec "$ns" "$@"; }
status() { ubus call service list "{\"name\":\"$1\"}"; }

capture() {
	local payload capture_command wan_filter awg_filter
	capture_command='ulimit -f 2048; exec env LD_LIBRARY_PATH="$2" "$2/tcpdump" --immediate-mode -p -nn -U -Q "$3" -i "$4" -s 128 -w "$1/$5.pcap" "$6" >"$1/$5.log" 2>&1'
	wan_filter="ip and (net 172.31.253.0/24 or net 198.18.0.0/15 or src host $awgsrc or (dst host $https and port 443) or (dst host $udp and udp dst port $udp_port) or (dst host $direct and (port 53 or tcp port 443)) or (host $outer and udp port $outerport))"
	awg_filter="ip and ((host $https and port 443) or (host $udp and udp port $udp_port))"
	payload=$(ucode -e 'const a=ARGV;
		function instance(dir, dev, name, filter) {return {command:["/bin/sh","-c",a[1],"sh",a[2],a[3],dir,dev,name,filter]};}
		print(sprintf("%J",{name:a[0],instances:{wan:instance("out",a[4],"wan",a[6]),awg:instance("inout",a[5],"awg",a[7])}}));' -- \
		"$owner-client" "$capture_command" "$root" "$obs" "$wan" "$awg" "$wan_filter" "$awg_filter")
	ubus call service set "$payload" >/dev/null
}
dns_start() {
	local payload
	payload=$(ucode -e 'const a=ARGV;
		print(sprintf("%J",{name:a[0],instances:{
			upstream:{command:["/bin/sh","-c", "exec /usr/sbin/dnsmasq --conf-file=/dev/null --keep-in-foreground --no-hosts --no-resolv --bind-interfaces --listen-address=127.0.0.1 --port=24156 --local-ttl=60 --pid-file=\"$1/upstream.pid\" --host-record=\"www.cloudflare.com,$2\" --host-record=\"echo.pkc.invalid,$3\" >\"$1/upstream.log\" 2>&1", "sh", a[1], a[2], a[3]]},
			main:{command:["/bin/sh","-c", "exec \"$1/podkopchik-native-dns\" -config \"$1/pilot.dns\" -ledger \"$1/ledger\" >\"$1/classifier.log\" 2>&1", "sh", a[1]]}
		}}));' -- "$owner-dns" "$root" "$https" "$udp")
	ubus call service set "$payload" >/dev/null
}
direct_probe() {
	client curl -4 --noproxy '*' --resolve "dns.google:443:$direct" --connect-timeout 3 --max-time 7 -fsS -o /dev/null \
		-w 'virtual direct HTTPS=%{http_code}\n' 'https://dns.google/resolve?name=example.com&type=A'
}
expect_block() {
	if client "$obs/pilot-probe" tcp "$1:443" > rejected.log 2>&1; then
		echo "FAIL: $2 reached an unintended destination" >&2; exit 1
	fi
	grep -Eq 'i/o timeout|network is unreachable|no route to host|connection refused' rejected.log
	printf 'PASS: %s blocked\n' "$2"
}
cpu() { awk '/^cpu /{s=0;for(i=2;i<=9;i++)s+=$i;print s,$5+$6;exit}' /proc/stat; }

capture
for i in 1 2 3 4 5; do grep -q 'listening on' wan.log 2>/dev/null && grep -q 'listening on' awg.log 2>/dev/null && break; sleep 1; done
grep -q 'listening on' wan.log; grep -q 'listening on' awg.log
# Establish that the controlled peer answers through the same AWG before
# touching the virtual client. This socket is bound to the real tunnel.
"$obs/pilot-probe" udp-echo "$udp:$udp_port" "$awg"
ip link set dev "$port" addrgenmode none
ip -n "$ns" link set dev client0 addrgenmode none
ip -4 addr add 172.31.252.1/30 dev "$port"
ip -n "$ns" -4 addr add 172.31.252.2/30 dev client0
ip link set dev "$port" up
dns_start
for i in 1 2 3 4 5 6; do nft get element inet pkc_virtual_guard "s_${epoch}_live4" '{ 172.31.252.2 }' >/dev/null 2>&1 && break; sleep 1; done
nft get element inet pkc_virtual_guard "s_${epoch}_live4" '{ 172.31.252.2 }' >/dev/null
ip -n "$ns" link set lo up
ip -n "$ns" link set dev client0 up
ip -n "$ns" -4 route add default via 172.31.252.1
remaining 55
set -- $(cpu); total0=$1; idle0=$2

fake=$(client "$obs/pilot-probe" lookup 172.31.252.1:53 udp www.cloudflare.com)
case "$fake" in 172.31.253.*) ;; *) exit 1 ;; esac
[ "$(client "$obs/pilot-probe" lookup "$direct:53" tcp www.cloudflare.com)" = "$fake" ]
fake_udp=$(client "$obs/pilot-probe" lookup 172.31.252.1:53 udp echo.pkc.invalid)
case "$fake_udp" in 172.31.253.*) [ "$fake_udp" != "$fake" ] ;; *) exit 1 ;; esac
nft get element inet pkc_virtual_guard "s_${epoch}_m4" "{ $fake }" | grep -Fq ": $https"
nft get element inet pkc_virtual_guard "s_${epoch}_m4" "{ $fake_udp }" | grep -Fq ": $udp"
ip -4 route get "$https" from 172.31.252.2 iif "$port" mark 0x504b0901 | grep -Fq "dev $awg"
echo 'PASS: UDP/TCP DNS, external TCP DNS redirected, acknowledged DNAT bindings and AWG policy route'
client curl -4 --noproxy '*' --resolve "www.cloudflare.com:443:$fake" --connect-timeout 3 --max-time 7 -fsS -o /dev/null \
	-w 'protected HTTPS=%{http_code}\n' https://www.cloudflare.com/cdn-cgi/trace
client "$obs/pilot-probe" udp-echo "$fake_udp:$udp_port"
client "$obs/pilot-probe" quic "$fake:443" www.cloudflare.com
direct_probe
expect_block 172.31.253.1 'retired synthetic address from earlier pilot'
expect_block 172.31.253.2 'second retired synthetic address from earlier pilot'
expect_block 172.31.253.254 'unknown synthetic address'
expect_block 198.19.0.1 'legacy synthetic address'
expect_block "$https" 'cached real protected address'

# Keep the DNAT map for this address but revoke its authorization. A cached
# synthetic IP may not start a new connection even if its map still exists.
nft delete element inet pkc_virtual_guard "s_${epoch}_g0_4" "{ $fake }"
nft get element inet pkc_virtual_guard "s_${epoch}_m4" "{ $fake }" >/dev/null
expect_block "$fake" 'revoked synthetic address with surviving DNAT map'
[ "$(client "$obs/pilot-probe" lookup 172.31.252.1:53 udp www.cloudflare.com)" = "$fake" ]

remaining 20
ip -4 route del default dev "$awg" metric 100 proto 242 table 48181
ip -4 route del unreachable default metric 42760 proto 242 table 48181
ip -4 route get "$https" from 172.31.252.2 iif "$port" mark 0x504b0901 | grep -Fq "dev $wan"
expect_block "$fake" 'protected TCP with test table withdrawn'
direct_probe
# Keep the WAN witness live through the return window after route withdrawal.
sleep 3
set -- $(cpu)
awk -v t="$(($1-total0))" -v i="$(($2-idle0))" 'BEGIN{if(t>0)printf "Pilot-window CPU busy (all cores)=%.1f%%\n",100*(t-i)/t}'
dp=$(status "$owner-dns" | jsonfilter -q -e '@.*.instances.main.pid')
awk '/^VmRSS:/ {print "classifier RSS=" $2 " KiB"}' "/proc/$dp/status"
printf 'classifier FD=%s\n' "$(find "/proc/$dp/fd" -maxdepth 1 -type l | wc -l)"
awk '/^MemAvailable:/ {print}' /proc/meminfo
printf 'conntrack used/max: '; cat /proc/sys/net/netfilter/nf_conntrack_count /proc/sys/net/netfilter/nf_conntrack_max | xargs

# Stop only the capture instances; the watchdog owns all remaining resources.
ubus call service delete "{\"name\":\"$owner-client\"}" >/dev/null
for i in 1 2 3 4 5; do
	if grep -qx '0 packets dropped by kernel' wan.log && grep -qx '0 packets dropped by kernel' awg.log; then break; fi
	sleep 1
done
grep -qx '0 packets dropped by kernel' wan.log
grep -qx '0 packets dropped by kernel' awg.log
count() {
	local iface="$1" filter="$2"
	LD_LIBRARY_PATH="$obs" "$obs/tcpdump" -nn -r "$iface.pcap" "$filter" > count.tmp 2>/dev/null || return 1
	wc -l < count.tmp | tr -d ' '
}
synthetic=$(count wan 'net 172.31.253.0/24 or net 198.18.0.0/15')
wrong=$(count wan "(dst host $https and port 443) or (dst host $udp and udp dst port $udp_port) or src host $awgsrc")
dns=$(count wan "dst host $direct and dst port 53")
open=$(count wan "dst host $direct and tcp dst port 443")
encrypted=$(count wan "dst host $outer and udp dst port $outerport")
tcp=$(count awg "host $https and tcp port 443")
udp_tx=$(count awg "dst host $udp and udp dst port $udp_port")
udp_rx=$(count awg "src host $udp and udp src port $udp_port")
quic=$(count awg "host $https and udp port 443")
printf 'WAN: synthetic=%s protected_clear_or_AWG_source=%s DNS_bypass=%s direct=%s AWG_outer=%s\n' "$synthetic" "$wrong" "$dns" "$open" "$encrypted"
printf 'AWG inner: TCP=%s UDP_echo_tx=%s UDP_echo_rx=%s UDP_QUIC=%s; kernel_capture_drops=0\n' "$tcp" "$udp_tx" "$udp_rx" "$quic"
[ "$synthetic" = 0 ] && [ "$wrong" = 0 ] && [ "$dns" = 0 ] && [ "$open" -gt 0 ] && [ "$encrypted" -gt 0 ] &&
	[ "$tcp" -gt 0 ] && [ "$udp_tx" -ge 8 ] && [ "$udp_rx" -ge 8 ] && [ "$quic" -gt 0 ]
echo 'PASS: scoped physical pilot; requesting watchdog rollback'
