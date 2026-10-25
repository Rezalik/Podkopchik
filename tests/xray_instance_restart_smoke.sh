#!/bin/sh
set -eu
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export RESTART_LOG="$tmp/log"
cat > "$tmp/ctl" <<'EOF'
#!/bin/sh
echo "ctl $*" >> "$RESTART_LOG"
[ "$*" = validate-active ]
EOF
chmod +x "$tmp/ctl"
extra_command() { :; }
. root/etc/init.d/podkopchik
CTL="$tmp/ctl"
xray_bin() { echo /usr/libexec/podkopchik-core/xray; }
uci_bool() { return 0; }
procd_kill() { echo "kill $*" >> "$RESTART_LOG"; }
procd_open_service() { echo "open $*" >> "$RESTART_LOG"; }
procd_open_instance() { echo "instance $*" >> "$RESTART_LOG"; }
procd_set_param() { echo "param $*" >> "$RESTART_LOG"; }
procd_close_instance() { :; }
procd_close_service() { echo "close $*" >> "$RESTART_LOG"; }
core_restart
grep -qx 'ctl validate-active' "$tmp/log"
grep -qx 'kill podkopchik xray' "$tmp/log"
grep -qx 'instance xray' "$tmp/log"
grep -qx 'close add' "$tmp/log"
grep -qx 'param command /usr/libexec/podkopchik-core/xray run -config /etc/podkopchik/config.json' "$tmp/log"
! grep -Eq 'cleanup|apply_rules|health|nft' "$tmp/log"
echo 'Xray-only procd restart smoke OK'
