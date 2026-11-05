#!/bin/sh
# A separate forward guard keeps failure recovery independent of TPROXY syntax.
set -u
umask 077
LIB="${PODKOPCHIK_LIB:-/usr/libexec/podkopchik}"
TMP="${PODKOPCHIK_TMP_DIR:-/tmp/podkopchik}"
DIR="${PODKOPCHIK_CONFIG_DIR:-/etc/podkopchik}"
PROC="${PODKOPCHIK_PROC_DIR:-/proc}"
NFT="${PODKOPCHIK_NFT:-nft}"
IP="${PODKOPCHIK_IP:-ip}"
CONFIG="$DIR/config.json"
MARKER="$TMP/guard.owner"
POINTER="$DIR/working-state.name"

state_dir() {
	local name
	[ ! -L "$POINTER" ] || return 1
	name=$(cat "$POINTER" 2>/dev/null) || return 1
	case "$name" in .working-*) ;; *) return 1 ;; esac
	case "$name" in *[!A-Za-z0-9_.-]*) return 1 ;; esac
	[ -d "$DIR/$name" ] && [ ! -L "$DIR/$name" ] || return 1
	printf '%s\n' "$DIR/$name"
}

guard_status() {
	local tables
	tables=$("$NFT" list tables 2>/dev/null) || { echo unknown; return 1; }
	if printf '%s\n' "$tables" | grep -qx 'table inet podkopchik_guard'; then
		[ "$(cat "$MARKER" 2>/dev/null)" = podkopchik-guard-v1 ] || { echo unknown; return 1; }
		echo active
	else
		echo inactive
	fi
}

guard() {
	local status lan old state batch rc
	status=$(guard_status) || return 1
	lan=$(uci -q get podkopchik.main.lan_ifname 2>/dev/null || echo br-lan)
	case "$lan" in ''|*[!A-Za-z0-9_.-]*) lan=br-lan ;; esac
	old="$lan"
	if state=$(state_dir); then old=$(cat "$state/lan"); fi
	case "$old" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
	mkdir -p "$TMP" || return 1
	batch=$(mktemp "$TMP/guard.XXXXXX") || return 1
	{
		[ "$status" != active ] || echo 'delete table inet podkopchik_guard'
		echo 'add table inet podkopchik_guard'
		echo 'add chain inet podkopchik_guard forward { type filter hook forward priority -10; policy accept; }'
		printf 'add rule inet podkopchik_guard forward iifname "%s" counter drop\n' "$old"
		[ "$old" = "$lan" ] || printf 'add rule inet podkopchik_guard forward iifname "%s" counter drop\n' "$lan"
	} > "$batch"
	printf '%s\n' podkopchik-guard-v1 > "$MARKER" || { rm -f "$batch"; return 1; }
	rc=0
	"$NFT" -c -f "$batch" && "$NFT" -f "$batch" || rc=1
	rm -f "$batch"
	return "$rc"
}

unguard() {
	local status
	status=$(guard_status) || return 1
	if [ "$status" = active ]; then "$NFT" delete table inet podkopchik_guard || return 1; fi
	rm -f "$MARKER"
}

main_pids() {
	local p args pid
	for p in "$PROC"/[0-9]*/cmdline; do
		[ -r "$p" ] || continue
		args=$(tr '\000' ' ' < "$p")
		case "$args" in *xray*" run -config $CONFIG "|*xray*" run -config $CONFIG") ;; *) continue ;; esac
		pid=${p%/cmdline}; printf '%s\n' "${pid##*/}"
	done
}

ready() {
	local pid port owner found=0 excluded
	excluded=" $(printf '%s' "${1:-}" | tr '\n' ' ') "
	port=$(jsonfilter -q -i "$CONFIG" -e '@.inbounds[@.tag="transparent"].port') || return 1
	case "$port" in ''|*[!0-9]*) return 1 ;; esac
	for pid in $(main_pids); do
		case "$excluded" in *" $pid "*) continue ;; esac
		owner=$(netstat -lntp 2>/dev/null | awk -v port="$port" -v pid="$pid" '$4 ~ ":" port "$" && $NF ~ "^" pid "/" {print pid}')
		[ -z "$owner" ] || found=1
	done
	[ "$found" = 1 ]
}

save() {
	local stage old older lan
	[ "$(cat "$TMP/routing.env" 2>/dev/null)" = podkopchik-routing-v1 ] || return 1
	mkdir -p "$DIR" || return 1
	stage=$(mktemp -d "$DIR/.working-XXXXXX") || return 1
	if ! cp "$CONFIG" "$stage/config.json" || ! "$NFT" list table inet podkopchik > "$stage/rules.nft"; then
		rm -rf "$stage"; return 1
	fi
	old=$(state_dir || true)
	# Recovered applied state must not be reinterpreted using pending bad UCI.
	if [ -n "$old" ] && cmp -s "$CONFIG" "$old/config.json" && cmp -s "$stage/rules.nft" "$old/rules.nft"; then
		rm -rf "$stage"; return 0
	fi
	lan=$(uci -q get podkopchik.main.lan_ifname 2>/dev/null || echo br-lan)
	case "$lan" in ''|*[!A-Za-z0-9_.-]*) rm -rf "$stage"; return 1 ;; esac
	printf '%s\n' "$lan" > "$stage/lan"
	if [ "$(cat "$TMP/routing6.env" 2>/dev/null)" = podkopchik-routing6-v1 ]; then echo 1 > "$stage/ipv6"; else echo 0 > "$stage/ipv6"; fi
	(cd "$stage" && sha256sum config.json rules.nft lan ipv6 > files.sha256) || { rm -rf "$stage"; return 1; }
	printf '%s\n' "${stage##*/}" > "$POINTER.new" && mv "$POINTER.new" "$POINTER" || { rm -rf "$stage"; return 1; }
	# Keep the current and one previous generation, never arbitrary paths.
	for older in "$DIR"/.working-*; do
		[ "$older" = "$stage" ] || [ "$older" = "$old" ] || { [ -d "$older" ] && [ ! -L "$older" ] && rm -rf "$older"; }
	done
	return 0
}

ensure_policy() {
	local family="$1" marker="$2" expected="$3" rules routes
	rules=$("$IP" $family rule show) || return 1
	rules=$(printf '%s\n' "$rules" | awk '$1 == "10991:" {$1=$1; print}')
	routes=$("$IP" $family route show table 10991 2>/dev/null | awk '{$1=$1; print}')
	if [ -z "$rules$routes" ]; then
		printf '%s\n' "$expected" > "$marker" || return 1
		if ! "$IP" $family rule add fwmark 0x100000 table 10991 priority 10991; then rm -f "$marker"; return 1; fi
		if ! "$IP" $family route add local default dev lo table 10991; then
			if "$IP" $family rule del fwmark 0x100000 table 10991 priority 10991; then rm -f "$marker"; fi
			return 1
		fi
	else
		[ "$(cat "$marker" 2>/dev/null)" = "$expected" ] || return 1
		[ "$rules" = '10991: from all fwmark 0x100000 lookup 10991' ] || return 1
		printf '%s\n' "$routes" | grep -Eq '^local default dev lo( scope host)?( metric [0-9]+)?( pref medium)?$' || return 1
		[ "$(printf '%s\n' "$routes" | wc -l | tr -d ' ')" = 1 ] || return 1
	fi
}

restore() {
	local state batch publish bin
	state=$(state_dir) || return 1
	(cd "$state" && sha256sum -c files.sha256 >/dev/null) || return 1
	. "$LIB/xray.sh"
	bin=$(xray_bin) || return 1
	"$bin" run -test -config "$state/config.json" >/dev/null 2>&1 || return 1
	sh "$LIB/fakedns_guard.sh" sync "$state/config.json" || return 1
	if "$NFT" list table inet podkopchik >/dev/null 2>&1; then
		[ "$(cat "$TMP/routing.env" 2>/dev/null)" = podkopchik-routing-v1 ] || return 1
	fi
	guard || return 1
	ensure_policy '' "$TMP/routing.env" podkopchik-routing-v1 || return 1
	if [ "$(cat "$state/ipv6")" = 1 ]; then ensure_policy -6 "$TMP/routing6.env" podkopchik-routing6-v1 || return 1; fi
	batch=$(mktemp "$TMP/restore-nft.XXXXXX") || return 1
	if "$NFT" list table inet podkopchik >/dev/null 2>&1; then
		[ "$(cat "$TMP/routing.env" 2>/dev/null)" = podkopchik-routing-v1 ] || { rm -f "$batch"; return 1; }
		echo 'delete table inet podkopchik' > "$batch"
	fi
	cat "$state/rules.nft" >> "$batch"
	if ! "$NFT" -c -f "$batch" || ! "$NFT" -f "$batch"; then rm -f "$batch"; return 1; fi
	rm -f "$batch"
	if [ "$(cat "$state/ipv6")" = 0 ] &&
		[ "$(cat "$TMP/routing6.env" 2>/dev/null)" = podkopchik-routing6-v1 ]; then
		ensure_policy -6 "$TMP/routing6.env" podkopchik-routing6-v1 || return 1
		"$IP" -6 rule del fwmark 0x100000 table 10991 priority 10991 &&
			"$IP" -6 route del local default dev lo table 10991 || return 1
		rm -f "$TMP/routing6.env"
	fi
	publish="$DIR/config.recover.$$.json"
	cp "$state/config.json" "$publish" && mv "$publish" "$CONFIG" || { rm -f "$publish"; return 1; }
}

mkdir -p "$TMP"
case "${1:-}" in
	guard) guard ;;
	unguard) unguard ;;
	status) guard_status ;;
	ready) ready "${2:-}" ;;
	pids) main_pids ;;
	save) save ;;
	restore) restore ;;
	fake-sync) sh "$LIB/fakedns_guard.sh" sync "${2:-}" ;;
	*) echo 'Usage: routing_safety.sh guard|unguard|status|ready [OLD_PIDS]|pids|save|restore|fake-sync [JSON]' >&2; exit 2 ;;
esac
