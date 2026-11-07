#!/bin/sh
# Operator-only bounded observation; never modifies application/network intent.
set -eu
umask 077
action=${1:?start|worker|status|stop required}
work=${2:-}
pointer=/tmp/pkc-native-observe-current
service=podkopchik-native-observe
[ "$(id -u)" = 0 ] && [ "$(cat /tmp/sysinfo/board_name)" = xiaomi,redmi-router-ax6000-stock ] || exit 2
check_work() {
	case "$work" in /tmp/pkc-native-observe.*) ;; *) exit 2 ;; esac
	[ -d "$work" ] && [ ! -L "$work" ] && [ -f "$work/config.json" ]
}
if [ "$action" = start ]; then
	base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
	if [ -e "$pointer" ]; then echo 'Existing observation found; inspect it before starting another.' >&2; exit 1; fi
	[ "$(df -k /tmp | awk 'END {print $4}')" -ge 16384 ] || exit 1
	work=$(mktemp -d /tmp/pkc-native-observe.XXXXXX)
	cp "$base/native-observe.sh" "$base/native-observe.uc" "$base/native_observe_lib.uc" "$work/"
	ucode -L "$work" "$work/native-observe.uc" init "$work" 48
	printf '%s\n' "$work" > "$pointer"
	payload=$(ucode -e 'printf("%J",{name:"podkopchik-native-observe",instances:{main:{command:["/bin/sh",ARGV[0]+"/native-observe.sh","worker",ARGV[0]],limits:{nofile:"256 256",core:"0 0"},stdout:false,stderr:false}}});' "$work")
	ubus call service set "$payload" >/dev/null
	printf 'Observation started: %s (48 hours, tmpfs only)\n' "$work"
	exit
fi
if [ -z "$work" ]; then work=$(cat "$pointer"); fi
check_work
observe() { ucode -L "$work" "$work/native-observe.uc" "$@" "$work"; }
case "$action" in
	worker)
		trap 'observe finish || true' EXIT
		trap 'exit 0' INT TERM HUP
		helper=$(jsonfilter -q -i "$work/config.json" -e @.helper)
		while [ "$(observe remaining)" -gt 0 ]; do
			before=$(cut -d. -f1 /proc/uptime)
			"$helper" -run-timeout 30 -- ucode -L "$work" "$work/native-observe.uc" sample "$work" >/dev/null 2>&1 || observe failure >/dev/null 2>&1 || true
			after=$(cut -d. -f1 /proc/uptime)
			delay=$((60 - after + before)); [ "$delay" -gt 0 ] || delay=1
			left=$(observe remaining); [ "$delay" -le "$left" ] || delay=$left
			[ "$delay" -gt 0 ] && sleep "$delay" || true
		done
		;;
	status) observe report ;;
	stop) ubus call service delete '{"name":"podkopchik-native-observe"}' >/dev/null; observe finish ;;
	*) exit 2 ;;
esac
