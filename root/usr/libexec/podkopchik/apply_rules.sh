#!/bin/sh

set -eu

APP="podkopchik"
LIB="/usr/libexec/podkopchik"
TMP_DIR="/tmp/podkopchik"
ROUTE_STATE="$TMP_DIR/routing.env"
PODKOPCHIK_MARK="0x100000"
PODKOPCHIK_TABLE="10991"
PODKOPCHIK_PRIO="10991"

fail_apply() {
	logger -t podkopchik "failed to apply Podkopchik routing rules; cleaning up partial state"
	"$LIB/cleanup_rules.sh" >/dev/null 2>&1 || true
	exit 1
}

run_rule() {
	"$@" >/dev/null 2>&1 || fail_apply
}

routing="$(uci -q get "$APP.main.routing_enabled" 2>/dev/null || echo 0)"
mode="${1:-uci}"

[ "$routing" = "1" ] || [ "$mode" = "apply" ] || {
	"$LIB/cleanup_rules.sh"
	exit 0
}

port="$(uci -q get "$APP.main.transparent_port" 2>/dev/null || echo 12345)"
lan="$(uci -q get "$APP.main.lan_ifname" 2>/dev/null || echo br-lan)"
dns_redirect="$(uci -q get "$APP.main.dns_redirect" 2>/dev/null || echo 0)"

"$LIB/cleanup_rules.sh"

mkdir -p "$TMP_DIR"
printf '%s\n' 'podkopchik-routing-v1' > "$ROUTE_STATE" || fail_apply

run_rule ip rule add fwmark "$PODKOPCHIK_MARK" table "$PODKOPCHIK_TABLE" priority "$PODKOPCHIK_PRIO"
run_rule ip route add local default dev lo table "$PODKOPCHIK_TABLE"

run_rule nft add table inet podkopchik
run_rule nft 'add chain inet podkopchik prerouting { type filter hook prerouting priority mangle; policy accept; }'
run_rule nft add set inet podkopchik reserved4 '{ type ipv4_addr; flags interval; }'
run_rule nft add element inet podkopchik reserved4 '{ 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 192.168.0.0/16, 198.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4, 240.0.0.0/4 }'
run_rule nft add set inet podkopchik reserved6 '{ type ipv6_addr; flags interval; }'
run_rule nft add element inet podkopchik reserved6 '{ ::1/128, fc00::/7, fe80::/10 }'

run_rule nft add rule inet podkopchik prerouting iifname "$lan" meta mark "$PODKOPCHIK_MARK" return
run_rule nft add rule inet podkopchik prerouting iifname "$lan" ip daddr @reserved4 return
run_rule nft add rule inet podkopchik prerouting iifname "$lan" ip6 daddr @reserved6 return

if [ "$dns_redirect" = "1" ]; then
	run_rule nft add rule inet podkopchik prerouting iifname "$lan" udp dport 53 redirect to :53
	run_rule nft add rule inet podkopchik prerouting iifname "$lan" tcp dport 53 redirect to :53
fi

run_rule nft add rule inet podkopchik prerouting iifname "$lan" meta l4proto tcp meta mark set "$PODKOPCHIK_MARK" tproxy ip to 127.0.0.1:"$port" accept

exit 0
