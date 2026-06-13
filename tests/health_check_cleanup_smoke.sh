#!/bin/sh

set -eu

tmp="tests/.tmp.health-cleanup.$$"
runtime="$tmp/runtime"
fake_proc="$tmp/proc"
rm -rf "$tmp"
mkdir -p "$tmp" "$runtime" "$tmp/lib" "$fake_proc"
trap 'kill ${main_pid:-} ${stale_pid:-} >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT

cat > "$tmp/uci" <<'EOF'
#!/bin/sh

[ "$1" = "-q" ] && shift
[ "${1:-}" = "get" ] || exit 1

case "${2:-}" in
	podkopchik.main.probe_url) echo "https://probe.example.invalid/" ;;
	podkopchik.main.timeout) echo "1" ;;
	podkopchik.main.health_socks_base_port) echo "20800" ;;
	podkopchik.main.routing_enabled) echo "0" ;;
	podkopchik.main.interval) echo "30" ;;
	podkopchik.@proxy\[0\]) echo "proxy" ;;
	podkopchik.@proxy\[0\].enabled) echo "1" ;;
	podkopchik.@proxy\[0\].tag) echo "gerwarp" ;;
	podkopchik.@proxy\[1\]) exit 1 ;;
	*) exit 1 ;;
esac
EOF

cat > "$tmp/ucode" <<'EOF'
#!/bin/sh

case " $* " in
	*" health "*)
		echo '{}'
		;;
	*" state "*)
		echo '{"version":"test","events":[]}'
		;;
	*)
		exit 1
		;;
esac
EOF

cat > "$tmp/jsonfilter" <<'EOF'
#!/bin/sh

exit 1
EOF

cat > "$tmp/logger" <<'EOF'
#!/bin/sh

echo "logger $*" >> "$PODKOPCHIK_TEST_LOG"
EOF

cat > "$tmp/netstat" <<'EOF'
#!/bin/sh

exit 0
EOF

cat > "$tmp/curl" <<'EOF'
#!/bin/sh

echo "curl: (28) Operation timed out" >&2
exit 28
EOF

cat > "$tmp/xray" <<'EOF'
#!/bin/sh

if [ "${1:-}" = "run" ] && [ "${2:-}" = "-test" ]; then
	exit 0
fi

if [ "${1:-}" = "run" ] && [ "${2:-}" = "-config" ]; then
	cfg="${3:-}"
	echo "$$ $cfg" >> "$XRAY_PID_LOG"
	trap '' HUP
	trap 'echo "term $$ '"$cfg"'" >> "$XRAY_TERM_LOG"; exit 0' INT TERM
	while :; do
		sleep 1
	done
fi

exit 1
EOF

chmod +x "$tmp/uci" "$tmp/ucode" "$tmp/jsonfilter" "$tmp/logger" "$tmp/netstat" "$tmp/curl" "$tmp/xray"

export PODKOPCHIK_TEST_LOG="$tmp/logger.log"
export XRAY_PID_LOG="$tmp/xray-pids.log"
export XRAY_TERM_LOG="$tmp/xray-terms.log"
export PATH="$tmp:$PATH"

: > "$PODKOPCHIK_TEST_LOG"
: > "$XRAY_PID_LOG"
: > "$XRAY_TERM_LOG"

"$tmp/xray" run -config /etc/podkopchik/config.json &
main_pid="$!"
(
	"$tmp/xray" run -config "$runtime/health-gerwarp.json" &
	echo "$!" > "$tmp/stale.pid"
)
stale_pid="$(cat "$tmp/stale.pid")"
mkdir -p "$fake_proc/$main_pid" "$fake_proc/$stale_pid"
printf '%s\n' "$tmp/xray run -config /etc/podkopchik/config.json" > "$fake_proc/$main_pid/cmdline"
printf '%s\n' "$tmp/xray run -config $runtime/health-gerwarp.json" > "$fake_proc/$stale_pid/cmdline"
mkdir -p "$runtime/health-port-20800.lock"
sleep 1

PODKOPCHIK_LIB="$tmp/lib" \
	PODKOPCHIK_TMP_DIR="$runtime" \
	PODKOPCHIK_PROC_DIR="$fake_proc" \
	PODKOPCHIK_STATE="$runtime/state.json" \
	sh root/usr/libexec/podkopchik/health_check.sh once

for _ in 1 2 3; do
	kill -0 "$stale_pid" >/dev/null 2>&1 || break
	sleep 1
done
if kill -0 "$stale_pid" >/dev/null 2>&1; then
	echo "stale health Xray process was not cleaned up" >&2
	exit 1
fi
rm -rf "$fake_proc/$stale_pid"

kill -0 "$main_pid" >/dev/null 2>&1
! grep -q '/etc/podkopchik/config.json' "$XRAY_TERM_LOG"
grep -q "$runtime/health-gerwarp.json" "$XRAY_TERM_LOG"
grep -q "cleaning up stale health probe Xray process" "$PODKOPCHIK_TEST_LOG"
grep -q "gerwarp.*down.*Operation timed out" "$runtime/health-results.tsv"
[ ! -d "$runtime/health-port-20800.lock" ]
[ ! -d "$runtime/health-check.lock" ]

PODKOPCHIK_LIB="$tmp/lib" \
	PODKOPCHIK_TMP_DIR="$runtime" \
	PODKOPCHIK_PROC_DIR="$fake_proc" \
	PODKOPCHIK_STATE="$runtime/state.json" \
	sh root/usr/libexec/podkopchik/health_check.sh once

[ ! -d "$runtime/health-port-20800.lock" ]
[ ! -d "$runtime/health-check.lock" ]

health_runs="$(grep -c "$runtime/health-gerwarp.json" "$XRAY_PID_LOG")"
health_terms="$(grep -c "$runtime/health-gerwarp.json" "$XRAY_TERM_LOG")"
[ "$health_runs" -eq "$health_terms" ]

kill "$main_pid" >/dev/null 2>&1 || true
wait "$main_pid" >/dev/null 2>&1 || true
main_pid=""

echo "health check cleanup smoke OK"
