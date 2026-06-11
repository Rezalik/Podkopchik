#!/bin/sh

set -eu

APP="podkopchik"
LIB="${PODKOPCHIK_LIB:-/usr/libexec/podkopchik}"
TMP_DIR="${PODKOPCHIK_TMP_DIR:-/tmp/podkopchik}"
CLEANUP="${PODKOPCHIK_CLEANUP:-$LIB/cleanup_rules.sh}"
IP="${PODKOPCHIK_IP:-ip}"
NFT="${PODKOPCHIK_NFT:-nft}"
ROUTE_STATE="$TMP_DIR/routing.env"
PODKOPCHIK_MARK="0x100000"
PODKOPCHIK_TABLE="10991"
PODKOPCHIK_PRIO="10991"

fail_apply() {
	reason="${1:-failed to apply Podkopchik routing rules}"
	logger -t podkopchik "$reason; cleaning up partial state" >/dev/null 2>&1 || true
	echo "podkopchik apply: $reason" >&2
	"$CLEANUP" >/dev/null 2>&1 || true
	exit 1
}

run_rule() {
	err="$TMP_DIR/apply-rule.err"

	if ! "$@" >"$err" 2>&1; then
		detail="$(cat "$err" 2>/dev/null || true)"
		rm -f "$err"
		if [ -n "$detail" ]; then
			fail_apply "command failed: $*; $detail"
		else
			fail_apply "command failed: $*"
		fi
	fi

	rm -f "$err"
}

require_ip_full() {
	case "$("$IP" -V 2>&1 || true)" in
		*iproute2*) return 0 ;;
	esac

	fail_apply "Missing required dependency: ip-full. BusyBox ip is not sufficient for fwmark policy routing. ip-full is required; BusyBox ip cannot add fwmark policy rules."
}

routing="$(uci -q get "$APP.main.routing_enabled" 2>/dev/null || echo 0)"
mode="${1:-uci}"

[ "$routing" = "1" ] || [ "$mode" = "apply" ] || {
	"$CLEANUP"
	exit 0
}

port="$(uci -q get "$APP.main.transparent_port" 2>/dev/null || echo 12345)"
lan="$(uci -q get "$APP.main.lan_ifname" 2>/dev/null || echo br-lan)"
dns_redirect="$(uci -q get "$APP.main.dns_redirect" 2>/dev/null || echo 0)"

require_ip_full

"$CLEANUP"

mkdir -p "$TMP_DIR"
printf '%s\n' 'podkopchik-routing-v1' > "$ROUTE_STATE" || fail_apply

run_rule "$IP" rule add fwmark "$PODKOPCHIK_MARK" table "$PODKOPCHIK_TABLE" priority "$PODKOPCHIK_PRIO"
run_rule "$IP" route add local default dev lo table "$PODKOPCHIK_TABLE"

run_rule "$NFT" add table inet podkopchik
run_rule "$NFT" 'add chain inet podkopchik prerouting { type filter hook prerouting priority mangle; policy accept; }'
run_rule "$NFT" add set inet podkopchik reserved4 '{ type ipv4_addr; flags interval; }'
run_rule "$NFT" add element inet podkopchik reserved4 '{ 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 192.168.0.0/16, 198.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4, 240.0.0.0/4 }'
run_rule "$NFT" add set inet podkopchik reserved6 '{ type ipv6_addr; flags interval; }'
run_rule "$NFT" add element inet podkopchik reserved6 '{ ::1/128, fc00::/7, fe80::/10 }'

run_rule "$NFT" add rule inet podkopchik prerouting iifname "$lan" meta mark "$PODKOPCHIK_MARK" return
run_rule "$NFT" add rule inet podkopchik prerouting iifname "$lan" ip daddr @reserved4 return
run_rule "$NFT" add rule inet podkopchik prerouting iifname "$lan" ip6 daddr @reserved6 return

if [ "$dns_redirect" = "1" ]; then
	run_rule "$NFT" add rule inet podkopchik prerouting iifname "$lan" udp dport 53 redirect to :53
	run_rule "$NFT" add rule inet podkopchik prerouting iifname "$lan" tcp dport 53 redirect to :53
fi

run_rule "$NFT" add rule inet podkopchik prerouting iifname "$lan" meta l4proto tcp meta mark set "$PODKOPCHIK_MARK" tproxy to :"$port" accept

exit 0
