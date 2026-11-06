#!/bin/sh
# Explicit operator helper for a private, already reviewed virtual-pilot bundle.
set -eu
umask 077
case "${1:-}" in rehearsal) limit=25 ;; pilot) limit=125 ;; *) exit 2 ;; esac
[ "$#" = 1 ] && [ "$(id -u)" = 0 ] || exit 2
[ "$(cat /tmp/sysinfo/board_name)" = xiaomi,redmi-router-ax6000-stock ] && [ "$(uname -r)" = 6.12.112 ] || exit 2
. /etc/openwrt_release
[ "$DISTRIB_RELEASE" = 25.12.6 ] && [ -d /sys/module/veth ] || exit 2
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$root"
ucode -e 'import { lstat } from "fs";
	const dir=lstat("."); if(dir?.type!="directory"||dir.uid!=0||dir.gid!=0||dir.mode!=0o700) die("unsafe pilot directory\n");
	let files=["ax6000-scoped-pilot-arm.sh","ax6000-virtual-watch.sh","trial-state.uc","virtual-trial-cleanup.uc","pilot.nft","route.json","run.json","SHA256SUMS"];
	if(ARGV[0]=="pilot") push(files,"ax6000-scoped-pilot-exercise.sh","pilot.dns","podkopchik-native-dns");
	for(let f in files){let s=lstat(f); if(s?.type!="file"||s.uid!=0||s.gid!=0||s.nlink!=1||s.mode!=(f=="podkopchik-native-dns"?0o700:0o600)) die("unsafe pilot file metadata: "+f+"\n");}' -- "$1"
sha256sum -c SHA256SUMS
get() { jsonfilter -i run.json -e "@.$1"; }
epoch=$(get epoch); port=$(get port); ns=$(get ns); awg=$(get awg); owner=$(get owner)
[ "${#epoch}" = 16 ] && [ "$root" = "/tmp/pkc-vpilot.$epoch" ] || exit 2
case "$epoch" in *[!0-9a-f]*) exit 2 ;; esac
[ "$port" = "pv$(printf %.12s "$epoch")" ] && [ "$ns" = "pkcv-$epoch" ] && [ "$owner" = "pkc-virtual-$epoch" ] || exit 2
printf '%s\n' "$awg" | grep -Eq '^paw[0-9a-f]{12}$'
[ "$(cat /proc/sys/kernel/random/boot_id)" = "$(get boot)" ]
[ "$(sha256sum /etc/config/network /etc/config/firewall /etc/config/dhcp /etc/config/wireless /etc/config/podkopchik /etc/podkopchik/config.json /usr/bin/xray | sha256sum | awk '{print $1}')" = "$(get cfg_digest)" ]
[ "$(nft -s list ruleset | sha256sum | awk '{print $1}')" = "$(get nft_digest)" ]
[ "$(awg show "$awg" endpoints | awk 'NR==1{print $2} END{if(NR!=1)exit 1}')" = "$(get outer):$(get outer_port)" ]
[ "$(ip -4 -j addr show dev "$awg" | jsonfilter -q -e '@[0].addr_info[0].local')" = "$(get source)" ]
if ip link show dev "$port" >/dev/null 2>&1; then exit 1; fi
[ ! -e "/var/run/netns/$ns" ] && [ ! -e trial.json ]
rules=$(ip -4 -j rule show); routes=$(ip -4 -j route show table all)
if printf '%s\n' "$rules" | grep -Eq '48181|11581|0x504b0901' ||
	printf '%s\n' "$routes" | grep -Eq '"table":"48181"'; then exit 1; fi
nft -c -f pilot.nft
if [ "$1" = pilot ]; then
	# The system-wide guard is a separately authorized prerequisite, never
	# created by the temporary pilot or removed by its watchdog.
	nft -j list tables | ucode -e 'import { stdin } from "fs";
		if(!length(filter(json(stdin.read("all")).nftables, r=>r.table?.family=="inet" &&
			r.table.name=="podkopchik_fake_guard" && r.table.comment=="podkopchik-fakedns-guard-v1"))) die("persistent FakeDNS guard is missing\n");'
	nft -s list set inet podkopchik_fake_guard legacy4 | grep -Fq '198.18.0.0/15'
	nft -s list set inet podkopchik_fake_guard native4 | grep -Fq '172.31.253.0/24'
	ip -d -j link show dev "$awg" | jsonfilter -q -e '@[0].linkinfo.info_kind' | grep -qx amneziawg
	ucode -e 'import { readfile } from "fs"; if(length(json(readfile("pilot.dns")).virtual_window || []) != 2)
		die("pilot requires a fresh reserved address window\n");'
	# The daemon checks UID, mode and hardlink count before opening the policy.
	# Initialize only the private ledger before making any kernel changes.
	./podkopchik-native-dns -config "$root/pilot.dns" -ledger "$root/ledger" -init-ledger
fi

registered=0; succeeded=0; made_ns=0; made_link=0
cleanup() {
	if [ "$registered" = 1 ]; then
		[ "$succeeded" = 1 ] || ucode trial-state.uc abort "$root" || true
	else
		[ "$made_link" = 0 ] || ip link del dev "$port" 2>/dev/null || true
		[ "$made_ns" = 0 ] || ip netns del "$ns" 2>/dev/null || true
	fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
ip netns add "$ns"; made_ns=1
ip netns exec "$ns" readlink /proc/self/ns/net > namespace.id
ip link add "$port" type veth peer name client0 netns "$ns"; made_link=1
ip link set dev "$port" alias "$owner"
ucode trial-state.uc arm "$root" "$limit"
sh ax6000-virtual-watch.sh start "$root"
registered=1
wp=
for i in 1 2 3 4 5; do
	wp=$(ubus call service list "{\"name\":\"$owner-watch\"}" | jsonfilter -q -e '@.*.instances.main.pid' || true)
	if [ -n "$wp" ] && kill -0 "$wp" 2>/dev/null; then break; fi
	sleep 1
done
[ -n "$wp" ] && kill -0 "$wp"
[ "$(ucode trial-state.uc poll "$root")" = waiting ]
nft -f pilot.nft
ip -4 route add unreachable default metric 42760 proto 242 table 48181
ip -4 route add default dev "$awg" metric 100 proto 242 table 48181
ip -4 rule add priority 11581 from 172.31.252.2 iif "$port" fwmark 0x504b0901 table 48181 protocol 242
[ "$(ip -j addr show dev "$port" | ucode -e 'import {stdin} from "fs"; const a=json(stdin.read("all"))[0]; print(!a.master && index(a.flags,"UP")<0 && !length(a.addr_info));')" = true ]
printf 'controller=%s watchdog=%s deadline=%ss veth=down nft=installed routes=installed\n' "$$" "$wp" "$limit"
succeeded=1
