#!/bin/sh
# Prepared NIC-free OpenWrt guest. No packages, outside endpoints or captures.
set -eu
umask 077
. /mnt/lab/native-vm-only.sh
. /mnt/lab/native-vm-binaries.sh
work=$(mktemp -d /tmp/pkc-dns-https-vm.XXXXXX)
r="pkc-doh-router-$$"
s="pkc-doh-server-$$"
server=
cleanup() {
	[ -z "$server" ] || kill "$server" 2>/dev/null || true
	[ -z "$server" ] || wait "$server" 2>/dev/null || true
	ip netns del "$r" 2>/dev/null || true
	ip netns del "$s" 2>/dev/null || true
	rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
for ns in "$r" "$s"; do ip netns add "$ns"; ip -n "$ns" link set lo up; done
ip link add "doh-r-$$" type veth peer name "doh-s-$$"
ip link set "doh-r-$$" netns "$r"
ip link set "doh-s-$$" netns "$s"
ip -n "$r" link set "doh-r-$$" name paw111111111111
ip -n "$s" link set "doh-s-$$" name tunnel0
ip -n "$r" addr add 10.89.0.1/30 dev paw111111111111
ip -n "$s" addr add 10.89.0.2/30 dev tunnel0
ip -n "$r" link set paw111111111111 up
ip -n "$s" link set tunnel0 up
ip -n "$s" addr add 1.1.1.1/32 dev lo
ip link add "doh-wr-$$" type veth peer name "doh-ws-$$"
ip link set "doh-wr-$$" netns "$r"
ip link set "doh-ws-$$" netns "$s"
ip -n "$r" link set "doh-wr-$$" name wan
ip -n "$s" link set "doh-ws-$$" name wan0
ip -n "$r" addr add 10.90.0.1/30 dev wan
ip -n "$s" addr add 10.90.0.2/30 dev wan0
ip -n "$r" link set wan up
ip -n "$s" link set wan0 up
ip -n "$r" route add default via 10.90.0.2 dev wan
ip -n "$r" rule add priority 12000 fwmark 536912912 table 42000
ip -n "$r" route add default via 10.89.0.2 dev paw111111111111 table 42000
ip netns exec "$s" nft -f - <<'NFT'
table inet fixture {
	counter wan { }
	counter https { }
	counter dot { }
	chain input {
		type filter hook input priority -100; policy accept;
		iifname "wan0" tcp dport { 443, 853 } counter name wan drop
		iifname "tunnel0" tcp dport 853 counter name dot drop
		iifname "tunnel0" tcp dport 443 counter name https accept
	}
}
NFT
PKC_DNS_BOUND_SERVER=1 PKC_DNS_BOUND_CERT="$work/root.pem" ip netns exec "$s" "$PKC_VM_BIN/native-dns.test" -test.run '^TestProtectedDNSBoundServer$' > "$work/server.log" 2>&1 &
server=$!
for attempt in $(seq 1 20); do [ ! -f "$work/root.pem.ready" ] || break; sleep 1; done
if [ ! -f "$work/root.pem.ready" ]; then cat "$work/server.log"; exit 1; fi
PKC_DNS_BOUND_CLIENT=1 PKC_DNS_BOUND_CERT="$work/root.pem" ip netns exec "$r" "$PKC_VM_BIN/native-dns.test" -test.v -test.run '^TestProtectedDNSBoundHTTPSFallback$'
for counter in wan https dot; do
	ip netns exec "$s" nft -j list counter inet fixture "$counter" |
		jsonfilter -e '@.nftables[*].counter.packets' > "$work/$counter"
done
[ "$(cat "$work/wan")" = 0 ]
[ "$(cat "$work/https")" -gt 0 ]
[ "$(cat "$work/dot")" -gt 0 ]
echo 'PASS: actual bound HTTPS fallback, blocked DoT, stale binding/all-down refused, bounded FD, zero DNS packets on virtual WAN'
