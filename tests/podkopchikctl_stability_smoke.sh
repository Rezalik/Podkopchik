#!/bin/sh

set -eu

CTL="root/usr/bin/podkopchikctl"

grep -F 'config-apply.lock' "$CTL" >/dev/null
grep -F 'config.apply.$$.json' "$CTL" >/dev/null
grep -F 'apply-rules.$$.err' "$CTL" >/dev/null
grep -F 'main_xray_running()' "$CTL" >/dev/null
grep -F 'CONFIG="$CONFIG_DIR/config.json"' "$CTL" >/dev/null

if grep -F 'pidof xray' "$CTL" >/dev/null; then
	echo "podkopchikctl status must not use pidof xray; it can mistake a health probe for the main service" >&2
	exit 1
fi

tmp="$(mktemp -d)"
cleanup() {
	rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$tmp/bin" "$tmp/proc/100" "$tmp/proc/200"

cat > "$tmp/bin/uci" <<'EOF'
#!/bin/sh

case "$*" in
	*podkopchik.main.enabled*) echo 1; exit 0 ;;
	*podkopchik.main.routing_enabled*) echo 0; exit 0 ;;
	*) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/uci"

printf '/usr/bin/xray\000run\000-config\000/tmp/podkopchik/health-gerwarp.json\000' > "$tmp/proc/100/cmdline"

out="$(PODKOPCHIK_PROC_DIR="$tmp/proc" PATH="$tmp/bin:$PATH" sh "$CTL" status)"
printf '%s\n' "$out" | grep 'Xray: not running' >/dev/null

printf '/usr/bin/xray\000run\000-config\000/etc/podkopchik/config.json\000' > "$tmp/proc/200/cmdline"

out="$(PODKOPCHIK_PROC_DIR="$tmp/proc" PATH="$tmp/bin:$PATH" sh "$CTL" status)"
printf '%s\n' "$out" | grep 'Xray: running' >/dev/null

echo "podkopchikctl stability smoke OK"
