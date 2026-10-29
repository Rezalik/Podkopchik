#!/bin/sh

# Results never alter health thresholds, current group selection or LAN routing.
set -eu
umask 077
LIB="${PODKOPCHIK_LIB:-/usr/libexec/podkopchik}"
TMP_DIR="${PODKOPCHIK_TMP_DIR:-/tmp/podkopchik}"
PROC_DIR="${PODKOPCHIK_PROC_DIR:-/proc}"
. "$LIB/xray.sh"
mkdir -p "$TMP_DIR"
work=""; probe_pid=""; locked=0

cleanup() {
	trap - EXIT
	if [ -n "$probe_pid" ]; then
		kill "$probe_pid" 2>/dev/null || true
		sleep 1
		kill -KILL "$probe_pid" 2>/dev/null || true
		wait "$probe_pid" 2>/dev/null || true
	fi
	[ -z "$work" ] || rm -rf "$work"
	if [ "$locked" = 1 ]; then
		rm -f "$TMP_DIR/connection-check.lock/pid"
		rmdir "$TMP_DIR/connection-check.lock"
	fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

result() {
	printf '{"status":"%s","reason":"%s","latency_ms":%s,"external_ip":"%s","checked_at":%s,"valid_for":300}\n' \
		"$1" "$2" "${3:-null}" "${4:-}" "$(date +%s)"
}
unavailable() { result unknown "$1"; exit 0; }

if ! mkdir "$TMP_DIR/connection-check.lock" 2>/dev/null; then
	# A killed checker must not permanently block future checks. An absent pid
	# file can be another process still acquiring the lock, so leave it alone.
	old_pid="$(cat "$TMP_DIR/connection-check.lock/pid" 2>/dev/null || true)"
	case "$old_pid" in ''|*[!0-9]*) unavailable busy ;; esac
	if kill -0 "$old_pid" 2>/dev/null; then unavailable busy; fi
	rm -f "$TMP_DIR/connection-check.lock/pid"
	rmdir "$TMP_DIR/connection-check.lock" 2>/dev/null || unavailable busy
	mkdir "$TMP_DIR/connection-check.lock" 2>/dev/null || unavailable busy
fi
locked=1
printf '%s\n' "$$" > "$TMP_DIR/connection-check.lock/pid"
# Only orphan processes from this checker are eligible; never health/main Xray.
for proc in "$PROC_DIR"/[0-9]*; do
	[ -r "$proc/cmdline" ] || continue
	cmd="$(tr '\000' ' ' < "$proc/cmdline")"
	case "$cmd" in
		*xray*" run -config $TMP_DIR/connection-check."*"/probe.json "|*xray*" run -config $TMP_DIR/connection-check."*"/probe.json")
			stale_pid="${proc##*/}"
			kill "$stale_pid" 2>/dev/null || true
			sleep 1
			kill -KILL "$stale_pid" 2>/dev/null || true
			;;
	esac
done
work="$(mktemp -d "$TMP_DIR/connection-check.XXXXXX")"
bin="$(xray_bin || true)"
[ -n "$bin" ] || unavailable missing_component
command -v curl >/dev/null 2>&1 && command -v netstat >/dev/null 2>&1 || unavailable missing_component

ipv6_probe=0
case "${1:-uri}" in
	primary) mode=probe-primary ;;
	uri) mode=probe-uri ;;
	tag|tag-ipv6)
		case "${2:-}" in ''|*[!A-Za-z0-9_]*) unavailable invalid_configuration ;; esac
		[ "$1" != tag-ipv6 ] || ipv6_probe=1
		mode=probe-tag
		;;
	*) unavailable invalid_configuration ;;
esac
# Never put the URI in command arguments, filenames, or error responses.
if ! ucode -L "$LIB" "$LIB/generate.uc" "$mode" "${2:-}" > "$work/probe.json" 2> "$work/error"; then
	unavailable invalid_configuration
fi
unset PODKOPCHIK_PROBE_URI
"$bin" run -test -config "$work/probe.json" > "$work/error" 2>&1 || unavailable invalid_configuration
if netstat -ln 2>/dev/null | grep -E ':20999[[:space:]]' >/dev/null; then unavailable port_in_use; fi
"$bin" run -config "$work/probe.json" > "$work/error" 2>&1 &
probe_pid=$!
sleep 1
kill -0 "$probe_pid" 2>/dev/null || unavailable probe_start_failed
netstat -lntp 2>/dev/null | grep -E ":20999[[:space:]].*[[:space:]]$probe_pid/" >/dev/null || unavailable probe_start_failed

# One HTTPS request verifies egress, measures request time and obtains the exit IP.
rc=0
if [ "$ipv6_probe" = 1 ]; then
	# SOCKS5 with local resolution sends this pinned IPv6 destination through
	# the candidate, not a dual-stack hostname which might fall back to IPv4.
	curl --noproxy '' --proto '=https' -fsS --connect-timeout 5 --max-time 10 --max-filesize 4096 \
		--socks5 127.0.0.1:20999 --resolve 'one.one.one.one:443:[2606:4700:4700::1111]' \
		-w '%{time_total}' -o "$work/trace" https://one.one.one.one/cdn-cgi/trace > "$work/time" 2> "$work/error" || rc=$?
	if [ "$rc" = 0 ]; then sed -n 's/^ip=//p' "$work/trace" > "$work/ip"; fi
else
	curl --noproxy '' --proto '=https' -fsS --connect-timeout 5 --max-time 10 --max-filesize 128 \
		--socks5-hostname 127.0.0.1:20999 -w '%{time_total}' -o "$work/ip" \
		https://api.ipify.org > "$work/time" 2> "$work/error" || rc=$?
fi
kill -0 "$probe_pid" 2>/dev/null || unavailable probe_start_failed
if [ "$rc" != 0 ]; then
	case "$rc" in
		5|6) reason=dns_error ;;
		28) reason=timeout ;;
		7|35|97) reason=server_unavailable ;;
		*) reason=internet_unavailable ;;
	esac
	result down "$reason"
	exit 0
fi
# Treat the provider's response as data, never interpolate arbitrary text into JSON.
if ! ip="$(ucode "$LIB/probe_result.uc" "$work/ip" 2>/dev/null)"; then
	unavailable external_ip_error
fi
if [ "$ipv6_probe" = 1 ]; then
	case "$ip" in *:*) ;; *) unavailable external_ip_error ;; esac
fi
ms="$(awk '/^[0-9]+([.][0-9]+)?$/ { printf "%.0f", $1 * 1000 }' "$work/time")"
[ -n "$ms" ] || unavailable external_ip_error
result up ok "$ms" "$ip"
