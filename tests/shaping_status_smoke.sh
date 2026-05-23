#!/bin/sh

set -eu

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/uci" <<'EOF'
#!/bin/sh

[ "$1" = "-q" ] && shift
cmd="$1"
key="${2:-}"

[ "$cmd" = "get" ] || exit 1

if [ "$key" = "podkopchik.main.lan_ifname" ]; then
	echo "br-lan"
	exit 0
fi

if [ "$key" = "podkopchik.@lan_device[0]" ]; then
	echo "lan_device"
	exit 0
fi

if [ "$key" = "podkopchik.@lan_device[1]" ]; then
	exit 1
fi

if [ "$key" = "podkopchik.@lan_device[0].enabled" ]; then
	echo "1"
elif [ "$key" = "podkopchik.@lan_device[0].speed_limit_enabled" ]; then
	[ "${PODKOPCHIK_TEST_DISABLED:-0}" = "1" ] && echo "0" || echo "1"
elif [ "$key" = "podkopchik.@lan_device[0].name" ]; then
	echo "Kid tablet"
elif [ "$key" = "podkopchik.@lan_device[0].source_ip" ]; then
	echo "192.168.1.50"
elif [ "$key" = "podkopchik.@lan_device[0].mode" ]; then
	echo "full_proxy"
elif [ "$key" = "podkopchik.@lan_device[0].target" ]; then
	echo "auto_proxy_group"
elif [ "$key" = "podkopchik.@lan_device[0].download_mbit" ]; then
	echo "10"
elif [ "$key" = "podkopchik.@lan_device[0].upload_mbit" ]; then
	echo "3"
elif [ "$key" = "podkopchik.@lan_device[0].speed_limit_mode" ]; then
	echo "unlimited_window"
elif [ "$key" = "podkopchik.@lan_device[0].unlimited_window_start" ]; then
	echo "00:00"
elif [ "$key" = "podkopchik.@lan_device[0].unlimited_window_end" ]; then
	echo "06:00"
else
	exit 1
fi
EOF

cat > "$tmp/date" <<'EOF'
#!/bin/sh

case "${1:-}" in
	+%H:%M) echo "01:30" ;;
	+%u) echo "1" ;;
	+%s) echo "1000" ;;
	*) /bin/date "$@" ;;
esac
EOF

chmod +x "$tmp/uci" "$tmp/date"

out="$(PATH="$tmp:$PATH" sh root/usr/bin/podkopchikctl shaping-status)"

printf '%s\n' "$out" | grep -q '^mode=diagnostic-only$'
printf '%s\n' "$out" | grep -q '^configured_devices=1$'
printf '%s\n' "$out" | grep -q '^device\[1\].ip=192.168.1.50$'
printf '%s\n' "$out" | grep -q '^device\[1\].download_mbit=10$'
printf '%s\n' "$out" | grep -q '^device\[1\].upload_mbit=3$'
printf '%s\n' "$out" | grep -q '^device\[1\].schedule_decision=inactive now (unlimited window)$'

out="$(PODKOPCHIK_TEST_DISABLED=1 PATH="$tmp:$PATH" sh root/usr/bin/podkopchikctl shaping-status)"
printf '%s\n' "$out" | grep -q '^configured_devices=0$'
! printf '%s\n' "$out" | grep -q '^device\[1\]\\.'

echo "shaping-status smoke OK"
