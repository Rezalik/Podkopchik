#!/bin/sh
# Data-plane acceptance only in the NIC-free disposable OpenWrt guest.
set -eu
umask 077
. /mnt/lab/native-vm-only.sh
fail() { echo "FAIL: $*" >&2; exit 1; }
work=$(mktemp -d /tmp/pkc-virtual-data.XXXXXX)
epoch=ab11223344556677; port=pvab1122334455; awg=paw111111111111
r=pkc-virtual-router-$$; l=pkc-virtual-client-$$; w=pkc-virtual-wan-$$; h=pkc-virtual-home-$$
bin=/mnt/lab/native-dns.test; daemon=/mnt/lab/podkopchik-native-dns
pids=; caps=; dp=
cleanup() {
	for p in $dp $pids $caps; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done
	for n in "$l" "$w" "$h" "$r"; do ip netns del "$n" 2>/dev/null || true; done
}
trap cleanup EXIT
rn() { ip netns exec "$r" "$@"; }
ln() { ip netns exec "$l" "$@"; }
wn() { ip netns exec "$w" "$@"; }
hn() { ip netns exec "$h" "$@"; }
for n in "$r" "$l" "$w" "$h"; do ip netns add "$n"; ip -n "$n" link set lo up; done
pair() {
	ip -n "$r" link add "$1" type veth peer name "$2"
	ip -n "$r" link set "$2" netns "$3"
	ip -n "$r" link set "$1" up
	ip -n "$3" link set "$2" up
}
pair wan wan0 "$w"
pair "$awg" tunnel0 "$w"
pair br-lan home0 "$h"
rn ip addr add 192.0.2.1/30 dev wan
wn ip addr add 192.0.2.2/30 dev wan0
rn ip addr add 198.51.1.1/30 dev "$awg"
wn ip addr add 198.51.1.2/30 dev tunnel0
rn ip addr add 192.168.1.1/24 dev br-lan
hn ip addr add 192.168.1.2/24 dev home0
hn ip route add default via 192.168.1.1
rn ip route add default via 192.0.2.2 dev wan
wn ip addr add 203.0.113.80/32 dev lo
wn ip addr add 203.0.113.81/32 dev lo
wn ip route add 192.168.1.0/24 via 192.0.2.1
rn sysctl -qw net.ipv4.ip_forward=1
rn nft -f - <<'NFT'
add table inet fw4
add chain inet fw4 input { type filter hook input priority filter; policy drop; }
add rule inet fw4 input iifname "lo" accept
add chain inet fw4 forward { type filter hook forward priority filter; policy drop; }
add rule inet fw4 forward iifname "br-lan" oifname "wan" counter accept comment "home-rule"
add rule inet fw4 forward oifname "br-lan" ct state established,related counter accept
add table inet podkopchik { comment "home-table"; }
NFT
rn nft -s list table inet podkopchik > "$work/home-nft"
addr=$(rn ip -j addr show); routes=$(rn ip -4 -j route show table all); rules=$(rn ip -4 -j rule show)
chains=$(rn nft -j list chains | ucode -e 'import { stdin } from "fs"; print(sprintf("%J", map(filter(json(stdin.read("all")).nftables, x => x.chain), x => x.chain)));')
printf '{"epoch":"%s","awg":"%s","wan":"wan","direct":"203.0.113.81","protected":"protected.example","upstream":"127.0.0.1:1056","nft_chains":%s,"inventory":{"addresses":%s,"routes":%s,"rules":%s,"issued":["198.18.0.0/15"],"exclusions":[],"endpoints":[]}}\n' \
	"$epoch" "$awg" "$chains" "$addr" "$routes" "$rules" > "$work/spec"
plan() { ucode -L /mnt/lab/source /mnt/lab/virtual-pilot-plan.uc "$1" "$2"; }
plan nft "$work/spec" > "$work/nft"
plan dns "$work/spec" > "$work/dns.json"
ucode -e 'import { readfile } from "fs"; let p=json(readfile(ARGV[0])); push(p.inventory.exclusions,"172.31.252.0/23"); print(sprintf("%J",p));' "$work/spec" > "$work/conflict"
if plan nft "$work/conflict" > /dev/null 2>&1; then fail 'overlapping subnet admitted'; fi
ucode -e 'import { readfile } from "fs"; let p=json(readfile(ARGV[0])); push(p.inventory.rules,{priority:42,fwmark:"0x504b0000",fwmask:"0xffff0000"}); print(sprintf("%J",p));' "$work/spec" > "$work/conflict"
if plan nft "$work/conflict" > /dev/null 2>&1; then fail 'overlapping masked mark admitted'; fi
ucode -e 'import { readfile } from "fs"; let p=json(readfile(ARGV[0])); push(p.nft_chains,{family:"inet",hook:"prerouting",prio:-151}); print(sprintf("%J",p));' "$work/spec" > "$work/conflict"
if plan nft "$work/conflict" > /dev/null 2>&1; then fail 'overlapping hook priority admitted'; fi
pair "$port" client0 "$l"
rn ip addr add 172.31.252.1/30 dev "$port"
ln ip addr add 172.31.252.2/30 dev client0
ln ip route add default via 172.31.252.1
rn nft -c -f "$work/nft"
rn nft -f "$work/nft"
rn ip -4 route add unreachable default metric 42760 proto 242 table 48181
rn ip -4 route add default dev "$awg" metric 100 proto 242 table 48181
rn ip -4 rule add priority 11581 from 172.31.252.2 iif "$port" fwmark 0x504b0901 table 48181 protocol 242
# Ethernet test double; real AWG does not perform ARP for the inner destination.
peer=$(wn ip -j link show dev tunnel0 | jsonfilter -e '@[0].address')
rn ip neigh add 203.0.113.80 lladdr "$peer" nud permanent dev "$awg"
ip -n "$r" -4 route get 203.0.113.80 from 172.31.252.2 iif "$port" mark 0x504b0901 | grep -q "dev $awg"
ip -n "$r" -4 route get 203.0.113.80 from 192.168.1.2 iif br-lan mark 0x504b0901 | grep -q 'dev wan'

PKC_NATIVE_LAB=dns ip netns exec "$r" "$bin" -test.run='^TestGuestFixture$' -- 127.0.0.1:1056 udp > "$work/upstream" 2>&1 & pids="$pids $!"
for dst in 203.0.113.80 203.0.113.81; do
	PKC_NATIVE_LAB=serve ip netns exec "$w" "$bin" -test.run='^TestGuestFixture$' -- "$dst:18081" > "$work/$dst" 2>&1 & pids="$pids $!"
done
PKC_NATIVE_LAB=quic-serve ip netns exec "$w" "$bin" -test.run='^TestGuestFixture$' -- 203.0.113.80:18443 "$work/cert" > "$work/quic" 2>&1 & pids="$pids $!"
rn "$daemon" -config "$work/dns.json" -ledger "$work/ledger" -init-ledger
ip netns exec "$r" "$daemon" -config "$work/dns.json" -ledger "$work/ledger" > "$work/classifier" 2>&1 & dp=$!
for dev in wan0 tunnel0; do
	ip netns exec "$w" tcpdump -U -n -i "$dev" -w "$work/$dev.pcap" 'ip' > "$work/cap-$dev" 2>&1 & caps="$caps $!"
done
live="s_${epoch}_live4"
for i in $(seq 1 12); do rn nft get element inet pkc_virtual_guard "$live" '{ 172.31.252.2 }' >/dev/null 2>&1 && break; sleep 1; done
rn nft get element inet pkc_virtual_guard "$live" '{ 172.31.252.2 }' >/dev/null
query() { PKC_NATIVE_LAB=query ln "$bin" -test.run='^TestGuestFixture$' -- 172.31.252.1:53 "$1" protected.example. A "$2" "$3"; }
probe() { PKC_NATIVE_LAB="$1" "$2" "$bin" -test.run='^TestGuestFixture$' -- "$3"; }
fake=$(query udp NOERROR 1 | sed -n 's/^address=//p')
case "$fake" in 172.31.253.*) ;; *) fail 'missing synthetic reply' ;; esac
query tcp NOERROR 1 | grep -Fxq "address=$fake"
if ! probe dial ln "$fake:18081"; then
	rn nft list table inet pkc_virtual_guard
	rn nft list table inet fw4
	cat "$work/classifier" "$work/203.0.113.80"
	fail 'initial TCP did not reach the native transport'
fi
probe udp ln "$fake:18081"
PKC_NATIVE_LAB=quic-client ln "$bin" -test.run='^TestGuestFixture$' -- "$fake:18443" "$work/cert"
probe dial ln 203.0.113.81:18081
probe udp ln 203.0.113.81:18081
probe dial hn 203.0.113.80:18081
awk '/^VmRSS:/ {printf "Virtual classifier RSS=%s KiB\n", $2}' "/proc/$dp/status"
printf 'Virtual classifier FD=%s\n' "$(find "/proc/$dp/fd" -maxdepth 1 -type l | wc -l)"
echo 'PASS: UDP/TCP DNS and synthetic TCP/UDP/QUIC through native stand-in without Xray; explicit direct and home traffic work'

for dst in 172.31.253.254 198.19.0.1 203.0.113.80; do
	if probe dial ln "$dst:18081" > "$work/rejected" 2>&1; then fail 'unknown or cached real address forwarded'; fi
done
rn ip -4 route del default dev "$awg" metric 100 proto 242 table 48181
if probe dial ln "$fake:18081" > "$work/rejected" 2>&1; then fail 'protected route failure escaped'; fi
rn ip -4 route del unreachable default metric 42760 proto 242 table 48181
ip -n "$r" -4 route get 203.0.113.80 from 172.31.252.2 iif "$port" mark 0x504b0901 | grep -q 'dev wan'
if probe dial ln "$fake:18081" > "$work/rejected" 2>&1; then fail 'nft allowed an RPDB fallback to WAN'; fi
probe dial hn 203.0.113.80:18081
rn ip -4 route add unreachable default metric 42760 proto 242 table 48181
rn ip -4 route add default dev "$awg" metric 100 proto 242 table 48181
rn nft flush chain inet pkc_virtual_guard translate
rn nft delete map inet pkc_virtual_guard "s_${epoch}_m4"
query udp SERVFAIL 0
if probe udp ln "$fake:18081" > "$work/rejected" 2>&1; then fail 'missing DNAT map escaped'; fi
rn nft flush chain inet pkc_virtual_guard dns
PKC_NATIVE_LAB=no-dns ln "$bin" -test.run='^TestGuestFixture$' -- 203.0.113.81:53 udp protected.example.
kill -KILL "$dp"; wait "$dp" 2>/dev/null || true; dp=
for i in $(seq 1 12); do ! rn nft get element inet pkc_virtual_guard "$live" '{ 172.31.252.2 }' >/dev/null 2>&1 && break; sleep 1; done
if rn nft get element inet pkc_virtual_guard "$live" '{ 172.31.252.2 }' >/dev/null 2>&1; then fail 'stale classifier heartbeat'; fi
PKC_NATIVE_LAB=no-dns ln "$bin" -test.run='^TestGuestFixture$' -- 172.31.252.1:53 udp protected.example.
if probe dial ln "$fake:18081" > "$work/rejected" 2>&1; then fail 'stopped classifier escaped'; fi
probe dial ln 203.0.113.81:18081
probe dial hn 203.0.113.80:18081
rn nft -s list table inet podkopchik | cmp - "$work/home-nft"
for p in $caps; do kill "$p"; wait "$p" || true; done; caps=
count() { tcpdump -nn -r "$work/$1.pcap" "$2" 2>/dev/null | wc -l; }
fakeleak=$(count wan0 'net 172.31.253.0/24 or net 198.18.0.0/15'); tunnelout=$(count tunnel0 'dst host 203.0.113.80'); direct=$(count wan0 'dst host 203.0.113.81');
# Home may reach the protected test server directly; distinguish its source.
bad=$(count wan0 'dst host 203.0.113.80 and not src host 192.168.1.2'); dnsleak=$(count wan0 'dst port 53')
printf 'Virtual WAN: synthetic=%s protected_wrong_egress=%s DNS=%s direct=%s tunnel=%s\n' "$fakeleak" "$bad" "$dnsleak" "$direct" "$tunnelout"
[ "$fakeleak" -eq 0 ] && [ "$bad" -eq 0 ] && [ "$dnsleak" -eq 0 ] && [ "$direct" -gt 0 ] && [ "$tunnelout" -gt 0 ] || fail 'WAN capture controls'
echo 'PASS: missing route/map, unknown/old addresses and classifier death fail closed only for virtual traffic'
