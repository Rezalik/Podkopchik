#!/bin/sh
set -eu
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export TEST_ROOT="$tmp" PODKOPCHIK_TMP_DIR="$tmp/run" PODKOPCHIK_CONFIG_DIR="$tmp/config"
export PODKOPCHIK_LIB="$tmp/lib" PODKOPCHIK_CTL="$tmp/ctl"
mkdir -p "$tmp/run" "$tmp/config" "$tmp/lib"
cat > "$tmp/ctl" <<'EOF'
#!/bin/sh
echo "ctl $*" >> "$TEST_ROOT/log"
exit 0
EOF
cat > "$tmp/lib/apply_rules.sh" <<'EOF'
#!/bin/sh
echo rules >> "$TEST_ROOT/log"
if [ -f "$TEST_ROOT/fail-nft" ]; then echo 'nft: syntax error (fixture)' >&2; exit 1; fi
EOF
cat > "$tmp/lib/cleanup_rules.sh" <<'EOF'
#!/bin/sh
echo cleanup >> "$TEST_ROOT/log"
EOF
chmod +x "$tmp/ctl" "$tmp/lib/"*.sh
echo '{}' > "$tmp/config/config.json"
extra_command() { :; }
. root/etc/init.d/podkopchik
uci_bool() { [ "$1" != podkopchik.main.routing_enabled ] || [ "$(cat "$tmp/requested")" = 1 ]; }
ucode() { echo "ucode $*" >> "$tmp/log"; }
xray_bin() { echo /usr/bin/xray; }
logger() { echo "$*" >> "$tmp/log"; }
procd_open_instance() { echo "instance $*" >> "$tmp/log"; }
procd_set_param() { echo "param $*" >> "$tmp/log"; }
procd_close_instance() { :; }
safety() {
	echo "safety $*" >> "$tmp/log"
	case "$1" in restore) [ -f "$tmp/recoverable" ] ;; *) return 0 ;; esac
}

echo 1 > "$tmp/requested"
touch "$tmp/fail-nft"
: > "$tmp/log"
if start_service; then echo 'Expected startup nft failure'; exit 1; fi
if service_started; then echo 'Failed startup must not report readiness'; exit 1; fi
! grep -q 'instance xray' "$tmp/log"
! grep -q 'param env' "$tmp/log"
! grep -q 'param limits' "$tmp/log"
grep -q 'safety guard' "$tmp/log"
! grep -q cleanup "$tmp/log"
grep -q 'syntax error' "$tmp/run/startup-rules.err"
[ "$(cat "$tmp/requested")" = 1 ]

# A valid previous snapshot can recover without accepting failed settings.
touch "$tmp/recoverable"
: > "$tmp/log"
start_service
service_started
grep -q 'instance xray' "$tmp/log"
! grep -q 'cone.disabled=true\|XRAY_CONE_DISABLED=true' "$tmp/log"
grep -qx 'param limits nofile=16384 16384' "$tmp/log"
grep -q 'startup recovered the last working' "$tmp/log"
grep -q 'safety unguard' "$tmp/log"

# Re-source as a boot invocation with the persisted explicit OFF state.
echo 0 > "$tmp/requested"
. root/etc/init.d/podkopchik
: > "$tmp/log"
uci_bool() { [ "$1" != podkopchik.main.routing_enabled ] || [ "$(cat "$tmp/requested")" = 1 ]; }
safety() { echo "safety $*" >> "$tmp/log"; }
start_service
service_started
grep -q 'instance health' "$tmp/log"
! grep -Eq 'instance xray|^rules$|safety guard|safety restore' "$tmp/log"
! grep -q 'param env' "$tmp/log"
! grep -q 'param limits' "$tmp/log"
[ "$(cat "$tmp/requested")" = 0 ]
stop_service
grep -q cleanup "$tmp/log"
echo 'Startup nft failure/recovery/persisted-disable smoke OK (mocked procd/kernel)'
