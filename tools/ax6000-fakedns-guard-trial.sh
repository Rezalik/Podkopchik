#!/bin/sh
# First install only. procd owns every mutation after arming, not the SSH shell.
set -eu
umask 077
outer=
if [ "${1:-}" = --vm ]; then
	. /mnt/lab/native-vm-only.sh
	outer="$2"; shift 2
	case "$outer" in pkc-guard-vm-[0-9]*) ;; *) exit 2 ;; esac
	case "$outer" in *[!a-z0-9-]*) exit 2 ;; esac
else
	[ "$(cat /tmp/sysinfo/board_name)" = xiaomi,redmi-router-ax6000-stock ] && [ "$(uname -r)" = 6.12.112 ] || exit 2
	. /etc/openwrt_release
	[ "$DISTRIB_RELEASE" = 25.12.6 ] || exit 2
fi
[ "$#" = 2 ] && [ "$(id -u)" = 0 ] || exit 2
action="$1"; root="$2"
epoch=${root#/tmp/pkc-fake-guard.}
[ "$root" = "/tmp/pkc-fake-guard.$epoch" ] && [ "${#epoch}" = 16 ] || exit 2
case "$epoch" in *[!a-f0-9]*) exit 2 ;; esac
cd "$root"
manifest='ax6000-fakedns-guard-trial.sh trial-state.uc fakedns_guard.uc fakedns_guard.sh native_pool.uc podkopchik-fakedns podkopchik-fakedns-hotplug.sh podkopchik-fakedns.keep'
ucode -e 'import { lstat } from "fs";
	const d=lstat(ARGV[0]); if(d?.type!="directory"||d.uid!=0||d.gid!=0||d.mode!=0o700) die("unsafe trial directory");
	for(let f in slice(ARGV,1)){let s=lstat(f);if(s?.type!="file"||s.uid!=0||s.gid!=0||s.mode!=0o600||s.nlink!=1)die("unsafe trial file");}' \
	-- "$root" $manifest SHA256SUMS
sha256sum -c SHA256SUMS >/dev/null
watch="pkc-fake-guard-$epoch"
target=
[ -z "$outer" ] || target="$root/vm"
lib="$target/usr/libexec/podkopchik"
init="$target/etc/init.d/podkopchik-fakedns"
hotplug="$target/etc/hotplug.d/iface/95-podkopchik-fakedns"
rc="$target/etc/rc.d/S18podkopchik-fakedns"
keep="$target/lib/upgrade/keep.d/podkopchik-fakedns"
ledger=/etc/podkopchik-fakedns-guard.json
if [ -n "$outer" ]; then
	export PODKOPCHIK_CONFIG_DIR="$target/etc/podkopchik" PODKOPCHIK_TMP_DIR="$target/run"
	ledger="$PODKOPCHIK_CONFIG_DIR/fakedns-guard.json"
fi
export PODKOPCHIK_LIB="$lib" PODKOPCHIK_GUARD_TRIAL_DIR="$root"
pool=172.31.253.0/24

run() { if [ -n "$outer" ]; then ip netns exec "$outer" "$@"; else "$@"; fi; }
journal() { ucode "$root/trial-state.uc" "$1" "$root" "${2:-}"; }
guard() {
	local endpoints allowed
	if [ -z "$outer" ] && { [ "$1" = preview-native ] || [ "$1" = register-native ]; }; then
		endpoints=$(awg show all endpoints) && allowed=$(awg show all allowed-ips) || return 1
		endpoints=$(printf '%s\n' "$endpoints" | awk '
			NF==3 && $3!="(none)" {e=$3;sub(/:[0-9]+$/,"",e);gsub(/[][]/,"",e); print e; n++}
			END{if(n<3)exit 1}') || return 1
		allowed=$(printf '%s\n' "$allowed" | awk '
			{for(i=3;i<=NF;i++) if($i!="0.0.0.0/0"&&$i!="::/0"&&$i!="(none)") print $i}') || return 1
		PODKOPCHIK_GUARD_EXCLUSIONS=$(printf '%s\n%s\n' "$endpoints" "$allowed" | tr '\n' ' ')
		export PODKOPCHIK_GUARD_EXCLUSIONS
	fi
	run ucode -L "$root" -L "$lib" -e 'require("fakedns_guard").cli(ARGV);' -- "$@"
}
status() { ubus call service list "{\"name\":\"$watch\"}"; }
empty_service() {
	status | ucode -e 'import { stdin } from "fs"; const s=json(stdin.read("all")); exit(type(s)!="object"||length(keys(s))!=0);'
}
present() { [ -e "$1" ] || [ -L "$1" ]; }
note() { printf '%s\n' "$1" > "$root/state.txt"; }
files() {
	"$1" fakedns_guard.uc "$lib/fakedns_guard.uc" 644 &&
	"$1" fakedns_guard.sh "$lib/fakedns_guard.sh" 644 &&
	"$1" native_pool.uc "$lib/native_pool.uc" 644 &&
	"$1" podkopchik-fakedns "$init" 755 &&
	"$1" podkopchik-fakedns-hotplug.sh "$hotplug" 644 &&
	"$1" podkopchik-fakedns.keep "$keep" 644
}
absent() { ! present "$2" && ! present "$2.pkc-$epoch"; }
stage() {
	local t="$2.pkc-$epoch"
	# On a procd respawn a published file must be byte-identical.
	if present "$2"; then [ -f "$2" ] && [ ! -L "$2" ] && cmp -s "$1" "$2"; return; fi
	rm -f "$t" && cp "$1" "$t" && chmod "$3" "$t" && ln "$t" "$2" && rm "$t"
}
owned() {
	! present "$2" || { [ -f "$2" ] && [ ! -L "$2" ] && cmp -s "$1" "$2"; }
}
remove() {
	rm -f "$2" "$2.pkc-$epoch"
}
active() {
	local s
	s=$(guard status) &&
		printf '%s\n' "$s" | grep -qx 'state=active' &&
		printf '%s\n' "$s" | grep -qx 'pools=198.18.0.0/15 172.31.253.0/24' &&
		printf '%s\n' "$s" | grep -qx 'native_pools=172.31.253.0/24' &&
		run nft -s list set inet podkopchik_fake_guard legacy4 | grep -Fq '198.18.0.0/15' &&
		run nft -s list set inet podkopchik_fake_guard native4 | grep -Fq "$pool"
}
rollback() {
	files owned || return 1
	if present "$rc"; then
		[ -L "$rc" ] && [ "$(readlink "$rc")" = ../init.d/podkopchik-fakedns ] || return 1
		rm "$rc" || return 1
	fi
	guard rollback-first-install "$pool" || return 1
	files remove
}

case "$action" in
	arm)
		empty_service && ! present "$rc" && ! present "$ledger" && ! present "$ledger.new" && files absent
		[ -d "$lib" ] && [ -d "${keep%/*}" ] && [ -d "${rc%/*}" ] && [ -d "${hotplug%/*}" ] && [ -f "$lib/awg.uc" ]
		guard preview-native "$pool" | grep -qx 'preview=ok'
		seconds=150
		[ -z "$outer" ] || seconds=25
		journal arm "$seconds"
		set -- /bin/sh "$root/ax6000-fakedns-guard-trial.sh"
		[ -z "$outer" ] || set -- "$@" --vm "$outer"
		payload=$(ucode -e 'printf("%J",{name:ARGV[0],instances:{main:{command:slice(ARGV,1),respawn:[3600,1,0]}}});' \
			-- "$watch" "$@" watch "$root")
		ubus call service set "$payload" >/dev/null
		;;
	watch)
		while :; do
			current=$(journal poll) || current=invalid
			case "$current" in
				waiting)
					if ! [ -f "$root/installed" ]; then
						if { guard preview-native "$pool" && files stage &&
							guard register-native "$pool" && active; } > "$root/watch.log" 2>&1; then
							touch "$root/installed"
							note active
						else
							journal abort || true
						fi
					elif [ -f "$root/accept" ]; then
						if active && { ! present "$rc" && ln -s ../init.d/podkopchik-fakedns "$rc" ||
							[ -L "$rc" ] && [ "$(readlink "$rc")" = ../init.d/podkopchik-fakedns ]; } && journal confirm; then
							note confirmed
						else
							journal abort || true
						fi
					fi
					sleep 1 ;;
				confirmed|restored)
					note "$current"
					ubus call service delete "{\"name\":\"$watch\"}" >/dev/null
					exit ;;
				rollback|invalid)
					if rollback > "$root/rollback.log" 2>&1; then
						if [ "$current" = rollback ]; then journal restored; fi
						note restored
						ubus call service delete "{\"name\":\"$watch\"}" >/dev/null
						exit
					fi
					note rollback_pending
					sleep 2 ;;
				*) exit 2 ;;
			esac
		done ;;
	accept)
		[ -f "$root/installed" ] && active
		journal verify
		touch "$root/accept" ;;
	abort) journal abort ;;
	*) exit 2 ;;
esac
