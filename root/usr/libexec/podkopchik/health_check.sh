#!/bin/sh

set -u
umask 077

APP="podkopchik"
LIB="${PODKOPCHIK_LIB:-/usr/libexec/podkopchik}"
CTL="${PODKOPCHIK_CTL:-/usr/bin/podkopchikctl}"
TMP_DIR="${PODKOPCHIK_TMP_DIR:-/tmp/podkopchik}"
PROC_DIR="${PODKOPCHIK_PROC_DIR:-/proc}"
STATE="${PODKOPCHIK_STATE:-$TMP_DIR/state.json}"
HEALTH_LOCK="$TMP_DIR/health-check.lock"
HEALTH_LOCK_HELD="0"
ACTIVE_PROBE_PID=""
ACTIVE_PROBE_LOCK=""

xray_bin() {
	. "${PODKOPCHIK_XRAY_SELECTOR:-$LIB/xray.sh}"
	xray_bin
}

cmdline_for_pid() {
	pid="$1"
	tr '\000' ' ' < "$PROC_DIR/$pid/cmdline" 2>/dev/null || true
}

is_health_xray_cmdline() {
	cmdline="$1"

	case "$cmdline" in
		*xray*" run -config $TMP_DIR/health-"*".json"*|*xray-core*" run -config $TMP_DIR/health-"*".json"*) return 0 ;;
	esac

	return 1
}

is_health_check_pid() {
	pid="$1"
	cmdline="$(cmdline_for_pid "$pid")"

	case "$cmdline" in
		*health_check.sh*) return 0 ;;
	esac

	return 1
}

terminate_pid() {
	pid="$1"

	kill "$pid" >/dev/null 2>&1 || return 0
	sleep 1
	if kill -0 "$pid" >/dev/null 2>&1; then
		kill -KILL "$pid" >/dev/null 2>&1 || true
	fi
}

cleanup_active_probe() {
	if [ -n "$ACTIVE_PROBE_PID" ]; then
		terminate_pid "$ACTIVE_PROBE_PID"
		wait "$ACTIVE_PROBE_PID" >/dev/null 2>&1 || true
		ACTIVE_PROBE_PID=""
	fi

	if [ -n "$ACTIVE_PROBE_LOCK" ]; then
		rmdir "$ACTIVE_PROBE_LOCK" >/dev/null 2>&1 || true
		ACTIVE_PROBE_LOCK=""
	fi
}

release_health_lock() {
	if [ "$HEALTH_LOCK_HELD" = "1" ]; then
		rm -rf "$HEALTH_LOCK" >/dev/null 2>&1 || true
		HEALTH_LOCK_HELD="0"
	fi
}

cleanup_on_exit() {
	cleanup_active_probe
	release_health_lock
}

trap 'cleanup_on_exit' EXIT
trap 'cleanup_on_exit; exit 130' INT
trap 'cleanup_on_exit; exit 143' HUP TERM

acquire_health_lock() {
	mkdir -p "$TMP_DIR"
	if [ -f "$TMP_DIR/config-apply.lock/connection-token" ]; then
		logger -t podkopchik "health check skipped; connection selection transaction is running"
		return 1
	fi
	if [ -d "$TMP_DIR/xray-update.lock" ]; then
		logger -t podkopchik "health check skipped; Xray update is running"
		return 1
	fi

	if mkdir "$HEALTH_LOCK" >/dev/null 2>&1; then
		printf '%s\n' "$$" > "$HEALTH_LOCK/pid" 2>/dev/null || true
		HEALTH_LOCK_HELD="1"
		return 0
	fi

	old_pid="$(cat "$HEALTH_LOCK/pid" 2>/dev/null || true)"
	if [ -z "$old_pid" ]; then
		sleep 1
		old_pid="$(cat "$HEALTH_LOCK/pid" 2>/dev/null || true)"
	fi

	if [ -n "$old_pid" ] && kill -0 "$old_pid" >/dev/null 2>&1 && is_health_check_pid "$old_pid"; then
		logger -t podkopchik "health check skipped; another health check is already running"
		return 1
	fi

	rm -rf "$HEALTH_LOCK" >/dev/null 2>&1 || true
	if mkdir "$HEALTH_LOCK" >/dev/null 2>&1; then
		printf '%s\n' "$$" > "$HEALTH_LOCK/pid" 2>/dev/null || true
		HEALTH_LOCK_HELD="1"
		return 0
	fi

	logger -t podkopchik "health check skipped; could not acquire health lock"
	return 1
}

cleanup_stale_health_xray() {
	for proc in "$PROC_DIR"/[0-9]*; do
		[ -d "$proc" ] || continue
		pid="${proc##*/}"
		[ "$pid" = "$$" ] && continue
		cmdline="$(cmdline_for_pid "$pid")"

		if is_health_xray_cmdline "$cmdline"; then
			logger -t podkopchik "cleaning up stale health probe Xray process $pid"
			terminate_pid "$pid"
		fi
	done
}

cleanup_stale_probe_locks() {
	for lock in "$TMP_DIR"/health-port-*.lock; do
		[ -d "$lock" ] || continue
		rm -rf "$lock" >/dev/null 2>&1 || true
	done
}

proxy_tag() {
	i="$1"
	raw="$(uci -q get "$APP.@proxy[$i].tag" 2>/dev/null || true)"
	[ -n "$raw" ] || raw="$(uci -q get "$APP.@proxy[$i].name" 2>/dev/null || echo "proxy_$i")"
	tag="$(printf '%s' "$raw" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9_]/_/g; s/^_*//; s/_*$//' | cut -c1-48)"
	case "$tag" in
		''|[0-9]*) tag="p_$tag" ;;
	esac
	printf '%s' "$tag"
}

record_unknown_all() {
	results="$1"
	message="$2"
	i=0
	while uci -q get "$APP.@proxy[$i]" >/dev/null 2>&1; do
		if [ "$(uci -q get "$APP.@proxy[$i].enabled" 2>/dev/null || echo 1)" != "0" ]; then
			tag="$(proxy_tag "$i")"
			printf '%s\tunknown\t%s\n' "$tag" "$message" >> "$results"
		fi
		i=$((i + 1))
	done
}

record_probe() {
	results="$1"
	tag="$2"
	status="$3"
	message="$4"
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$tag" "$status" "$message" "${5:-}" "${6:-}" "$(date +%s)" >> "$results"
}

probe_port_state() {
	port="$1"

	if command -v netstat >/dev/null 2>&1; then
		netstat -ln 2>/dev/null | grep -Eq "[:.]$port[[:space:]]" && return 0
		return 1
	fi

	return 2
}

probe_proxy() {
	tag="$1"
	port="$2"
	results="$3"
	bin="$4"

	cfg="$TMP_DIR/health-$tag.json"
	log="$TMP_DIR/health-$tag.log"
	lock="$TMP_DIR/health-port-$port.lock"
	url="$(uci -q get "$APP.main.probe_url" 2>/dev/null || echo https://www.gstatic.com/generate_204)"
	timeout="$(uci -q get "$APP.main.timeout" 2>/dev/null || echo 5)"

	if ! mkdir "$lock" >/dev/null 2>&1; then
		record_probe "$results" "$tag" "unknown" "health probe port is locked"
		return
	fi
	ACTIVE_PROBE_LOCK="$lock"

	probe_port_state "$port"
	port_state="$?"
	if [ "$port_state" = "0" ]; then
		cleanup_active_probe
		record_probe "$results" "$tag" "unknown" "health probe port is already in use"
		return
	elif [ "$port_state" = "2" ]; then
		cleanup_active_probe
		record_probe "$results" "$tag" "unknown" "cannot verify health probe port ownership"
		return
	fi

	touch "$cfg" "$log"
	if ! chmod 600 "$cfg" "$log"; then
		cleanup_active_probe
		record_probe "$results" "$tag" "unknown" "could not protect temporary probe files"
		return
	fi
	if ! ucode -L "$LIB" "$LIB/generate.uc" health "$tag" "$port" > "$cfg" 2>"$log"; then
		msg="$(tr '\n\t' '  ' < "$log")"
		cleanup_active_probe
		record_probe "$results" "$tag" "unknown" "could not generate health config: $msg"
		return
	fi

	if ! "$bin" run -test -config "$cfg" >/dev/null 2>"$log"; then
		msg="$(tr '\n\t' '  ' < "$log")"
		cleanup_active_probe
		record_probe "$results" "$tag" "unknown" "health config validation failed: $msg"
		return
	fi

	"$bin" run -config "$cfg" >/dev/null 2>"$log" &
	pid="$!"
	ACTIVE_PROBE_PID="$pid"
	sleep 1

	if ! kill -0 "$pid" >/dev/null 2>&1; then
		msg="$(tr '\n\t' '  ' < "$log")"
		wait "$pid" >/dev/null 2>&1 || true
		ACTIVE_PROBE_PID=""
		cleanup_active_probe
		record_probe "$results" "$tag" "unknown" "temporary xray probe process exited before curl: ${msg:-no listener}"
		return
	fi

	if elapsed="$(curl --noproxy '' -fsS -I --max-time "$timeout" --socks5-hostname "127.0.0.1:$port" -w '%{time_total}' -o /dev/null "$url" 2>"$log")"; then
		legacy="$(uci -q get "$APP.main.extended_interception" 2>/dev/null || echo 0)"
		ipv6="$(uci -q get "$APP.main.ipv6_interception" 2>/dev/null || echo "$legacy")"
		if [ "$ipv6" = 1 ] && ! curl --noproxy '' --proto '=https' -fsS --max-time "$timeout" \
			--socks5 "127.0.0.1:$port" --resolve 'one.one.one.one:443:[2606:4700:4700::1111]' \
			https://one.one.one.one/cdn-cgi/trace -o /dev/null 2>"$log"; then
			record_probe "$results" "$tag" down 'ipv6_probe'
			cleanup_active_probe
			return
		fi
		latency="$(printf '%s\n' "$elapsed" | awk '/^[0-9]+([.][0-9]+)?$/ { printf "%.0f", $1 * 1000 }')"
		external_ip=""
		ip_file="$TMP_DIR/health-$tag.ip"
		if curl --noproxy '' --proto '=https' -fsS --max-time "$timeout" --max-filesize 128 --socks5-hostname "127.0.0.1:$port" https://api.ipify.org -o "$ip_file" 2>/dev/null; then
			external_ip="$(ucode "$LIB/probe_result.uc" "$ip_file" 2>/dev/null || true)"
		fi
		rm -f "$ip_file"
		if kill -0 "$pid" >/dev/null 2>&1; then
			record_probe "$results" "$tag" "up" "" "$latency" "$external_ip"
		else
			record_probe "$results" "$tag" "unknown" "temporary xray probe process exited during curl"
		fi
	else
		msg="$(tr '\n\t' '  ' < "$log")"
		record_probe "$results" "$tag" "down" "${msg:-probe failed}"
	fi

	cleanup_active_probe
}

run_once_locked() {
	mkdir -p "$TMP_DIR"
	results="$TMP_DIR/health-results.tsv"
	: > "$results"

	bin="$(xray_bin)"
	if ! command -v curl >/dev/null 2>&1; then
		record_unknown_all "$results" "curl not available for proxy probing"
	else
		base="$(uci -q get "$APP.main.health_socks_base_port" 2>/dev/null || echo 20800)"
		i=0
		while uci -q get "$APP.@proxy[$i]" >/dev/null 2>&1; do
			if [ "$(uci -q get "$APP.@proxy[$i].enabled" 2>/dev/null || echo 1)" != "0" ]; then
				tag="$(proxy_tag "$i")"
				if [ "$(uci -q get "$APP.@proxy[$i].protocol" 2>/dev/null || true)" = amneziawg ]; then
					id="$(uci -q get "$APP.@proxy[$i].awg_id" 2>/dev/null || true)"
					result="$TMP_DIR/awg-probe.json"
					if ucode -L "$LIB" "$LIB/awg_cli.uc" health "$id" > "$result"; then
						status="$(jsonfilter -q -i "$result" -e '@.status' 2>/dev/null || echo unknown)"
						reason="$(jsonfilter -q -i "$result" -e '@.reason' 2>/dev/null || true)"
						latency="$(jsonfilter -q -i "$result" -e '@.latency_ms' 2>/dev/null || true)"
						external_ip="$(jsonfilter -q -i "$result" -e '@.external_ip' 2>/dev/null || true)"
						record_probe "$results" "$tag" "$status" "$reason" "$latency" "$external_ip"
					else
						record_probe "$results" "$tag" unknown "AWG check could not run"
					fi
					rm -f "$result"
				elif [ -z "$bin" ]; then
					record_probe "$results" "$tag" unknown "xray binary not available"
				else
					probe_proxy "$tag" "$((base + i))" "$results" "$bin"
				fi
			fi
			i=$((i + 1))
		done
	fi

	if ucode -L "$LIB" "$LIB/generate.uc" state "$results" > "$STATE.tmp"; then
		events="$TMP_DIR/health-events.$$"
		switched="0"
		applied="0"
		apply_failed="0"
		: > "$events"
		if command -v jsonfilter >/dev/null 2>&1; then
			jsonfilter -q -i "$STATE.tmp" -e '@.events[*]' > "$events" 2>/dev/null || true
			while IFS= read -r event; do
				[ -n "$event" ] || continue
				switched="1"
				logger -t podkopchik "$event"
			done < "$events"
		else
			logger -t podkopchik "jsonfilter not available; failover switch events cannot be detected"
		fi

		if [ "$switched" = "1" ]; then
			if [ "$(uci -q get "$APP.main.routing_enabled" 2>/dev/null || echo 0)" = "1" ]; then
				if "$CTL" apply-health-state "$STATE.tmp"; then
					applied="1"
				else
					apply_failed="1"
					logger -t podkopchik "failover config apply failed; active Xray config was not changed"
				fi
			else
				logger -t podkopchik "routing inactive; failover state recorded without Xray restart"
			fi
		fi

		if [ "$apply_failed" = "1" ]; then
			rm -f "$STATE.tmp" "$events"
			logger -t podkopchik "health state was not replaced because failover apply failed; next health check will retry"
			return 1
		fi

		if ! mv "$STATE.tmp" "$STATE"; then
			rm -f "$events"
			logger -t podkopchik "health state update failed"
			return 1
		fi
		chmod 600 "$STATE"
		logger -t podkopchik "health check completed"
		if [ "$applied" = "1" ]; then
			logger -t podkopchik "failover config applied; restarting Xray"
			( sleep 1; /etc/init.d/podkopchik core_restart >/dev/null 2>&1 ) &
		fi
		rm -f "$events"
	else
		rm -f "$STATE.tmp"
		logger -t podkopchik "health state update failed"
		return 1
	fi
}

run_once() {
	mkdir -p "$TMP_DIR"

	if ! acquire_health_lock; then
		return 0
	fi

	cleanup_stale_health_xray
	cleanup_stale_probe_locks
	run_once_locked
	rc="$?"
	release_health_lock
	return "$rc"
}

case "${1:-once}" in
	daemon)
		while :; do
			run_once || true
			interval="$(uci -q get "$APP.main.interval" 2>/dev/null || echo 30)"
			sleep "$interval"
		done
		;;
	once)
		run_once
		;;
	*)
		echo "Usage: health_check.sh [once|daemon]" >&2
		exit 2
		;;
esac
