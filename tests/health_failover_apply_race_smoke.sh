#!/bin/sh

set -eu

tmp="tests/.tmp.health-failover-race.$$"
runtime="$tmp/runtime"
rm -rf "$tmp"
mkdir -p "$tmp" "$runtime" "$tmp/lib"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

cat > "$tmp/uci" <<'EOF'
#!/bin/sh

[ "$1" = "-q" ] && shift
[ "${1:-}" = "get" ] || exit 1

case "${2:-}" in
	podkopchik.main.probe_url) echo "https://probe.example.invalid/" ;;
	podkopchik.main.timeout) echo "1" ;;
	podkopchik.main.health_socks_base_port) echo "20800" ;;
	podkopchik.main.routing_enabled) echo "1" ;;
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
		echo '{"events":["group auto_proxy_group switched to gerwarp"],"proxies":{"gerwarp":{"status":"up"}}}'
		;;
	*)
		exit 1
		;;
esac
EOF

cat > "$tmp/jsonfilter" <<'EOF'
#!/bin/sh

echo "group auto_proxy_group switched to gerwarp"
EOF

cat > "$tmp/logger" <<'EOF'
#!/bin/sh

echo "logger $*" >> "$PODKOPCHIK_TEST_LOG"
EOF

cat > "$tmp/netstat" <<'EOF'
#!/bin/sh

exit 1
EOF

cat > "$tmp/curl" <<'EOF'
#!/bin/sh

exit 0
EOF

cat > "$tmp/xray" <<'EOF'
#!/bin/sh

if [ "${1:-}" = "run" ] && [ "${2:-}" = "-test" ]; then
	exit 0
fi

if [ "${1:-}" = "run" ] && [ "${2:-}" = "-config" ]; then
	trap 'exit 0' INT TERM
	while :; do
		sleep 1
	done
fi

exit 1
EOF

cat > "$tmp/podkopchikctl" <<'EOF'
#!/bin/sh

echo "$*" >> "$PODKOPCHIK_CTL_LOG"
exit 1
EOF

chmod +x "$tmp/uci" "$tmp/ucode" "$tmp/jsonfilter" "$tmp/logger" "$tmp/netstat" "$tmp/curl" "$tmp/xray" "$tmp/podkopchikctl"

export PODKOPCHIK_TEST_LOG="$tmp/logger.log"
export PODKOPCHIK_CTL_LOG="$tmp/ctl.log"
export PATH="$tmp:$PATH"

: > "$PODKOPCHIK_TEST_LOG"
: > "$PODKOPCHIK_CTL_LOG"
printf '%s\n' '{"events":[],"old":true}' > "$runtime/state.json"

if PODKOPCHIK_LIB="$tmp/lib" \
	PODKOPCHIK_TMP_DIR="$runtime" \
	PODKOPCHIK_STATE="$runtime/state.json" \
	PODKOPCHIK_CTL="$tmp/podkopchikctl" \
	sh root/usr/libexec/podkopchik/health_check.sh once; then
	echo "health check should fail when failover apply fails" >&2
	exit 1
fi

grep -q '"old":true' "$runtime/state.json"
[ ! -e "$runtime/state.tmp" ]
grep -q 'apply-health-state' "$PODKOPCHIK_CTL_LOG"
grep -q 'failover config apply failed' "$PODKOPCHIK_TEST_LOG"
grep -q 'health state was not replaced because failover apply failed' "$PODKOPCHIK_TEST_LOG"

echo "health failover apply race smoke OK"
