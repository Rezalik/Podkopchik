#!/bin/sh
# Recover one runtime-only virtual trial. Never address a physical interface.
set -eu
umask 077
lib=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
outer=
if [ "${1:-}" = --vm ]; then
	. /mnt/lab/native-vm-only.sh
	outer="$2"; shift 2
	case "$outer" in pkc-vm-host-[0-9]*) ;; *) exit 2 ;; esac
	case "$outer" in *[!a-z0-9-]*) exit 2 ;; esac
else
	[ "$(cat /tmp/sysinfo/board_name)" = xiaomi,redmi-router-ax6000-stock ] && [ "$(uname -r)" = 6.12.112 ] || exit 2
	. /etc/openwrt_release
	[ "$DISTRIB_RELEASE" = 25.12.6 ] || exit 2
fi
[ "$#" = 2 ] && [ "$(id -u)" = 0 ] || exit 2
action="$1"; root="$2"
epoch=${root#/tmp/pkc-vpilot.}
[ "$root" = "/tmp/pkc-vpilot.$epoch" ] && [ "${#epoch}" = 16 ] || exit 2
case "$epoch" in *[!0-9a-f]*) exit 2 ;; esac
[ -d "$root" ] && [ ! -L "$root" ] && [ "$(ls -ldn "$root" | awk '{print $1, $3}')" = 'drwx------ 0' ] || exit 2
port="pv$(printf %.12s "$epoch")"; alias="pkc-virtual-$epoch"
ns="pkcv-$epoch"; mount="/var/run/netns/$ns"
watch="$alias-watch"; dns="$alias-dns"; client="$alias-client"

run() { if [ -n "$outer" ]; then ip netns exec "$outer" "$@"; else "$@"; fi; }
journal() { ucode "$lib/trial-state.uc" "$1" "$root"; }
decode() { ucode "$lib/virtual-trial-cleanup.uc" "$1" "$epoch"; }
service() { ubus call service list "{\"name\":\"$1\"}"; }
empty_service() {
	printf '%s' "$1" | ucode -e 'import { stdin } from "fs";
		const v = json(stdin.read("all")); exit(type(v) == "object" && !length(keys(v)) ? 0 : 1);'
}
owned_service() {
	printf '%s\n' "$1" | jsonfilter -q -e '@.*.instances.*.command[*]' | grep -Fxq "$root"
}
stop_owned() {
	local data
	data=$(service "$1") || return 1
	empty_service "$data" && return 0
	owned_service "$data" || return 1
	ubus call service delete "{\"name\":\"$1\"}" >/dev/null
}
note() {
	# Keep only the latest result and a monotonic journal, not an unbounded log.
	printf '%s %s\n' "$(date -u +%FT%TZ)" "$1" > "$root/recovery.status"
}

owned_routing() {
	local rules routes all
	rules=$(run ip -4 -j rule show) || return 1
	all=$(run ip -4 -j route show table all) || return 1
	routes=$(printf '%s\n' "$all" | ucode -e 'import { stdin } from "fs";
		const a = json(stdin.read("all")); if (type(a) != "array") exit(1);
		print(sprintf("%J", filter(a, x => +x.table == 48181)));') || return 1
	printf '{"rules":%s,"routes":%s}\n' "$rules" "$routes" |
		ucode "$lib/virtual-trial-cleanup.uc" routing "$epoch" "$root/route.json"
}

cleanup() {
	local link links exists=0 info rules tables batch identity pids routing= item device
	links=$(run ip -j link show) || return 1
	if printf '%s\n' "$links" | jsonfilter -q -e '@[*].ifname' | grep -Fxq "$port"; then
		exists=1
		link=$(run ip -d -j link show dev "$port") || return 1
		[ "$(printf '%s\n' "$link" | jsonfilter -q -e '@[0].ifalias')" = "$alias" ] &&
			[ "$(printf '%s\n' "$link" | jsonfilter -q -e '@[0].linkinfo.info_kind')" = veth ] || return 1
		run ip link set dev "$port" down || return 1
	fi
	stop_owned "$client" && stop_owned "$dns" || return 1
	# The file is registered while the namespace is still disconnected.
	if [ -e "$mount" ]; then
		[ ! -L "$mount" ] && [ -f "$root/namespace.id" ] && [ ! -L "$root/namespace.id" ] || return 1
		identity=$(ip netns exec "$ns" readlink /proc/self/ns/net) || return 1
		[ "$identity" = "$(cat "$root/namespace.id")" ] || return 1
		pids=$(ip netns pids "$ns") || return 1
		[ -z "$pids" ] || return 1
	fi
	info=$(run nft -j list tables) || return 1
	tables=$(printf '%s\n' "$info" | decode tables) || return 1
	rules=
	if printf '%s\n' "$info" | jsonfilter -q -e '@.nftables[*].table.name' | grep -Fxq fw4; then
		info=$(run nft -j -a list table inet fw4) || return 1
		rules=$(printf '%s\n' "$info" | decode rules) || return 1
	fi
	if [ -e "$root/route.json" ]; then
		[ -f "$root/route.json" ] && [ ! -L "$root/route.json" ] || return 1
		routing=$(owned_routing) || return 1
	fi
	batch=$(printf '%s\n%s\n' "$rules" "$tables")
	[ -z "$batch" ] || printf '%s\n' "$batch" | run nft -f - || return 1
	for item in $routing; do
		case "$item" in
			rule) run ip -4 rule del priority 11581 from 172.31.252.2 iif "$port" fwmark 0x504b0901 table 48181 protocol 242 || return 1 ;;
			tunnel) device=$(jsonfilter -i "$root/route.json" -e '@.device') &&
				run ip -4 route del default dev "$device" metric 100 proto 242 table 48181 || return 1 ;;
			unreachable) run ip -4 route del unreachable default metric 42760 proto 242 table 48181 || return 1 ;;
			*) return 1 ;;
		esac
	done
	if [ "$exists" = 1 ]; then run ip link del dev "$port" || return 1; fi
	if [ -e "$mount" ]; then ip netns del "$ns" || return 1; fi
	[ ! -e "$mount" ]
}

case "$action" in
	start)
		[ "$(journal poll)" = waiting ] && empty_service "$(service "$watch")" || exit 1
		set -- /bin/sh "$lib/ax6000-virtual-watch.sh"
		if [ -n "$outer" ]; then
			set -- "$@" --vm "$outer"
		fi
		payload=$(ucode -e 'print(sprintf("%J", { name: ARGV[0], instances: { main: {
			command: slice(ARGV, 1), respawn: [3600, 1, 0]
		} } }));' -- "$watch" "$@" watch "$root")
		ubus call service set "$payload" >/dev/null
		;;
	watch)
		while :; do
			current=$(journal poll) || current=invalid
			case "$current" in
				waiting) sleep 1; continue ;;
				rollback|restored|invalid|confirmed) : ;;
				*) exit 2 ;;
			esac
			if cleanup; then
				if [ "$current" = rollback ]; then journal restored || exit 1; fi
				note "cleaned:$current"
				stop_owned "$watch"
				exit
			fi
			note restore_pending
			sleep 2
		done
		;;
	*) exit 2 ;;
esac
