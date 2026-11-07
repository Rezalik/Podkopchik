#!/bin/sh
# Workstation-only lease renewal; DNS/provider faults must not trigger recovery.
set -eu
umask 077
work=${1:?private acceptance directory required}
host=${2:-openwrt}
token=$(cat "$work/emergency-token")
case "$token" in ''|*[!a-f0-9]*) exit 2 ;; esac
[ "${#token}" = 32 ] || exit 2
while [ ! -e "$work/stop-management-watch" ]; do
	if curl --noproxy '*' --max-time 5 -sS -D "$work/luci.headers" \
		-o "$work/luci.html" http://192.168.1.1/cgi-bin/luci/ &&
		grep -qi '^x-luci-login-required: yes' "$work/luci.headers" &&
		grep -q 'luci_password' "$work/luci.html" &&
		ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 \
		-o ServerAliveCountMax=1 "$host" \
		"test \"\$(cat /tmp/sysinfo/board_name)\" = xiaomi,redmi-router-ax6000-stock && ucode /etc/podkopchik-native-emergency/recovery.uc heartbeat '$token'"; then
		date -u '+%Y-%m-%dT%H:%M:%SZ management lease renewed'
	else
		date -u '+%Y-%m-%dT%H:%M:%SZ management validation failed; lease not renewed' >&2
	fi
	sleep 10
done
