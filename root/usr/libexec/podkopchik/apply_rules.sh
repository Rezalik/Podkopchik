#!/bin/sh

set -eu

APP="podkopchik"
LIB="${PODKOPCHIK_LIB:-/usr/libexec/podkopchik}"
TMP_DIR="${PODKOPCHIK_TMP_DIR:-/tmp/podkopchik}"
CLEANUP="${PODKOPCHIK_CLEANUP:-$LIB/cleanup_rules.sh}"
IP="${PODKOPCHIK_IP:-ip}"
NFT="${PODKOPCHIK_NFT:-nft}"
UCODE="${PODKOPCHIK_UCODE:-ucode}"
JSONFILTER="${PODKOPCHIK_JSONFILTER:-jsonfilter}"
RESOLVER="${PODKOPCHIK_RESOLVER:-}"
ROUTE_STATE="$TMP_DIR/routing.env"
BYPASS_STATE="$TMP_DIR/proxy_bypass.env"
PODKOPCHIK_MARK="0x100000"
PODKOPCHIK_TABLE="10991"
PODKOPCHIK_PRIO="10991"
bypass4=""
bypass6=""
bypass_failed_hosts=""

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

warn_apply() {
	logger -t podkopchik "$*" >/dev/null 2>&1 || true
	echo "podkopchik apply warning: $*" >&2
}

require_ip_full() {
	case "$("$IP" -V 2>&1 || true)" in
		*iproute2*) return 0 ;;
	esac

	fail_apply "Missing required dependency: ip-full. BusyBox ip is not sufficient for fwmark policy routing. ip-full is required; BusyBox ip cannot add fwmark policy rules."
}

is_ipv4() {
	ip="$1"
	case "$ip" in
		*.*.*.*) ;;
		*) return 1 ;;
	esac
	case "$ip" in
		*[!0-9.]*|.*|*.) return 1 ;;
	esac

	old_ifs="$IFS"
	IFS=.
	set -- $ip
	IFS="$old_ifs"

	[ "$#" -eq 4 ] || return 1

	for part in "$@"; do
		case "$part" in
			''|*[!0-9]*) return 1 ;;
		esac
		[ "$part" -ge 0 ] 2>/dev/null && [ "$part" -le 255 ] 2>/dev/null || return 1
	done

	return 0
}

is_ipv6() {
	case "$1" in
		'') return 1 ;;
		*.*|*[!0-9A-Fa-f:]*) return 1 ;;
		*:*) return 0 ;;
		*) return 1 ;;
	esac
}

add_bypass_ip() {
	ip="$1"

	if is_ipv4 "$ip"; then
		case " $bypass4 " in
			*" $ip "*) ;;
			*) bypass4="$bypass4 $ip" ;;
		esac
		return 0
	fi

	if is_ipv6 "$ip"; then
		case " $bypass6 " in
			*" $ip "*) ;;
			*) bypass6="$bypass6 $ip" ;;
		esac
		return 0
	fi

	return 1
}

record_failed_host() {
	host="$1"

	case " $bypass_failed_hosts " in
		*" $host "*) ;;
		*) bypass_failed_hosts="$bypass_failed_hosts $host" ;;
	esac
}

proxy_endpoint_host() {
	uri="$1"
	parsed="$("$UCODE" -L "$LIB" "$LIB/parse_vless.uc" "$uri" 2>/dev/null)" || return 1
	host="$(printf '%s\n' "$parsed" | "$JSONFILTER" -q -e '@.host' 2>/dev/null || true)"
	[ -n "$host" ] || host="$(printf '%s\n' "$parsed" | "$JSONFILTER" -q -e '@.address' 2>/dev/null || true)"
	[ -n "$host" ] || return 1
	printf '%s\n' "$host"
}

resolve_endpoint_host() {
	host="$1"

	if [ -n "$RESOLVER" ]; then
		"$RESOLVER" "$host"
		return
	fi

	if command -v getent >/dev/null 2>&1; then
		getent ahosts "$host" 2>/dev/null | awk '{ print $1 }'
	fi

	if command -v nslookup >/dev/null 2>&1; then
		nslookup "$host" 2>/dev/null | awk '
			/^Address[[:space:]]+[0-9]+:/ { print $3 }
			/^Address:[[:space:]]*/ { print $2 }
		'
	fi
}

collect_proxy_bypass() {
	i=0

	while uci -q get "$APP.@proxy[$i]" >/dev/null 2>&1; do
		uri="$(uci -q get "$APP.@proxy[$i].uri" 2>/dev/null || true)"
		i=$((i + 1))

		[ -n "$uri" ] || continue

		if ! host="$(proxy_endpoint_host "$uri")"; then
			warn_apply "could not read proxy endpoint host from configured proxy link"
			continue
		fi

		if add_bypass_ip "$host"; then
			continue
		fi

		resolved=0
		for ip in $(resolve_endpoint_host "$host" 2>/dev/null || true); do
			if add_bypass_ip "$ip"; then
				resolved=1
			fi
		done

		if [ "$resolved" = "0" ]; then
			record_failed_host "$host"
			warn_apply "could not resolve proxy endpoint host for transparent proxy bypass: $host"
		fi
	done
}

add_bypass_elements() {
	set_name="$1"
	values="$2"
	elements=""

	[ -n "$values" ] || return 0

	for value in $values; do
		if [ -n "$elements" ]; then
			elements="$elements, $value"
		else
			elements="$value"
		fi
	done

	run_rule "$NFT" add element inet podkopchik "$set_name" "{ $elements }"
}

write_bypass_state() {
	{
		echo "proxy_bypass4=$bypass4"
		echo "proxy_bypass6=$bypass6"
		echo "proxy_bypass_failed_hosts=$bypass_failed_hosts"
	} > "$BYPASS_STATE" || true

	[ -n "$bypass4" ] && logger -t podkopchik "proxy endpoint IPv4 bypass:$bypass4" >/dev/null 2>&1 || true
	[ -n "$bypass6" ] && logger -t podkopchik "proxy endpoint IPv6 bypass:$bypass6" >/dev/null 2>&1 || true
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
fakedns_enabled="$(uci -q get "$APP.main.fakedns_enabled" 2>/dev/null || echo 0)"
fakedns_hijack_dns="$(uci -q get "$APP.main.fakedns_hijack_dns" 2>/dev/null || echo 0)"
fakedns_port="$(uci -q get "$APP.main.fakedns_port" 2>/dev/null || echo 1053)"

require_ip_full

"$CLEANUP"

mkdir -p "$TMP_DIR"
printf '%s\n' 'podkopchik-routing-v1' > "$ROUTE_STATE" || fail_apply

run_rule "$IP" rule add fwmark "$PODKOPCHIK_MARK" table "$PODKOPCHIK_TABLE" priority "$PODKOPCHIK_PRIO"
run_rule "$IP" route add local default dev lo table "$PODKOPCHIK_TABLE"

run_rule "$NFT" add table inet podkopchik
run_rule "$NFT" 'add chain inet podkopchik prerouting { type filter hook prerouting priority mangle; policy accept; }'
if [ "$fakedns_enabled" = "1" ] && [ "$fakedns_hijack_dns" = "1" ]; then
	run_rule "$NFT" 'add chain inet podkopchik dns_prerouting { type nat hook prerouting priority dstnat; policy accept; }'
	run_rule "$NFT" add rule inet podkopchik dns_prerouting iifname "$lan" udp dport 53 redirect to :"$fakedns_port"
	run_rule "$NFT" add rule inet podkopchik dns_prerouting iifname "$lan" tcp dport 53 redirect to :"$fakedns_port"
fi
run_rule "$NFT" add set inet podkopchik reserved4 '{ type ipv4_addr; flags interval; }'
run_rule "$NFT" add element inet podkopchik reserved4 '{ 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 192.168.0.0/16, 198.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4, 240.0.0.0/4 }'
run_rule "$NFT" add set inet podkopchik reserved6 '{ type ipv6_addr; flags interval; }'
run_rule "$NFT" add element inet podkopchik reserved6 '{ ::1/128, fc00::/7, fe80::/10 }'
run_rule "$NFT" add set inet podkopchik proxy_bypass4 '{ type ipv4_addr; flags interval; }'
run_rule "$NFT" add set inet podkopchik proxy_bypass6 '{ type ipv6_addr; flags interval; }'

collect_proxy_bypass
add_bypass_elements proxy_bypass4 "$bypass4"
add_bypass_elements proxy_bypass6 "$bypass6"
write_bypass_state

run_rule "$NFT" add rule inet podkopchik prerouting iifname "$lan" meta mark "$PODKOPCHIK_MARK" return
run_rule "$NFT" add rule inet podkopchik prerouting iifname "$lan" ip daddr @reserved4 return
run_rule "$NFT" add rule inet podkopchik prerouting iifname "$lan" ip6 daddr @reserved6 return
run_rule "$NFT" add rule inet podkopchik prerouting iifname "$lan" ip daddr @proxy_bypass4 return
run_rule "$NFT" add rule inet podkopchik prerouting iifname "$lan" ip6 daddr @proxy_bypass6 return

if [ "$dns_redirect" = "1" ]; then
	run_rule "$NFT" add rule inet podkopchik prerouting iifname "$lan" udp dport 53 redirect to :53
	run_rule "$NFT" add rule inet podkopchik prerouting iifname "$lan" tcp dport 53 redirect to :53
fi

run_rule "$NFT" add rule inet podkopchik prerouting iifname "$lan" meta l4proto tcp meta mark set "$PODKOPCHIK_MARK" tproxy to :"$port" accept

exit 0
