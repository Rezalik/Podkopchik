#!/bin/sh
# Manual, runtime-only lan4 trial rollback. No installation or shared service reload.
set -eu
umask 077
lib=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=/etc/podkopchik-ax6000-trial
config=/etc/config
ns=
if [ "${1:-}" = --vm ]; then
	[ -r /mnt/lab/native-vm-only.sh ] || exit 2
	. /mnt/lab/native-vm-only.sh
	ns="$2"; root="$3"; config="$root/config"; shift 3
	case "$ns:$root" in pkc-ax6000-*:/tmp/pkc-ax6000.*) ;; *) exit 2 ;; esac
	case "$ns:$root" in *[!A-Za-z0-9_./:-]*) exit 2 ;; esac
else
	[ "$(cat /tmp/sysinfo/board_name)" = xiaomi,redmi-router-ax6000-stock ] && [ "$(uname -r)" = 6.12.112 ] || exit 2
	. /etc/openwrt_release
	[ "$DISTRIB_RELEASE" = 25.12.6 ] || exit 2
fi
[ "$(id -u)" = 0 ] && [ -d "$root" ] && [ ! -L "$root" ] || exit 2
[ "$(ls -ldn "$root" | awk '{print $1, $3}')" = 'drwx------ 0' ] || exit 2

run() { if [ -n "$ns" ]; then ip netns exec "$ns" "$@"; else "$@"; fi; }
data() { ucode -L "$lib" "$lib/ax6000-recovery-data.uc" "$1" "$root/spec.json" "${2:-}"; }
state() { ucode "$lib/trial-state.uc" "$1" "$root" "${2:-}"; }
log() {
	if [ -f "$root/recovery.log" ] && [ "$(wc -c < "$root/recovery.log")" -ge 16384 ]; then
		mv -f "$root/recovery.log" "$root/recovery.log.old"
	fi
	printf '%s %s\n' "$(date -u +%FT%TZ)" "$1" >> "$root/recovery.log"
}
for f in spec.json SHA256SUMS config.sha256; do [ -f "$root/$f" ] && [ ! -L "$root/$f" ] || exit 2; done
manifest_ok() {
	awk -v wanted="$2" 'BEGIN {n=split(wanted,a," "); for(i=1;i<=n;i++) names[a[i]]=1}
		NF!=2 || length($1)!=64 || $1 !~ /^[0-9a-f]+$/ || !($2 in names) || seen[$2]++ {bad=1}
		END {exit bad || NR!=n}' "$1"
}
manifest_ok "$root/SHA256SUMS" 'spec.json config.sha256' || exit 2
manifest_ok "$root/config.sha256" 'network firewall dhcp wireless podkopchik' || exit 2
(cd "$root" && sha256sum -c SHA256SUMS >/dev/null) || { log manifest_rejected; exit 1; }
info=$(data info) || exit 2
epoch=${info% *}; up=${info#* }
alias="pkc-ax6000-$epoch"

quarantine() {
	tables=$(run nft -j list tables) || return 1
	status=$(printf '%s\n' "$tables" | data tables quarantine) || return 1
	case "$status" in
		owned) return 0 ;;
		absent) batch=$(data quarantine) && printf '%s\n' "$batch" | run nft -f - ;;
		*) return 1 ;;
	esac
}
config_ok() { (cd "$config" && sha256sum -c "$root/config.sha256" >/dev/null 2>&1); }
link() { run ip -j link show dev "$1"; }
attr() { jsonfilter -q -e "@[0].$1"; }
stop_trial() {
	name="pkc-ax6000-$1-$epoch"
	svc=$(ubus call service list "{\"name\":\"$name\"}") || return 1
	if [ -n "$(printf '%s\n' "$svc" | jsonfilter -q -e '@.*.instances' || true)" ]; then
		ubus call service delete "{\"name\":\"$name\"}" >/dev/null || return 1
	fi
}
trial_running() {
	local name="pkc-ax6000-$1-$epoch"
	ubus call service list "{\"name\":\"$name\"}" | jsonfilter -q -e '@.*.instances.*.running' | grep -qx true
}
trial_healthy() {
	config_ok && [ "$(link lan4 | attr master)" = br-pkc-test ] &&
		[ "$(link br-pkc-test | attr ifalias)" = "$alias" ] &&
		run nft list chain inet podkopchik_native_gate dns_lan >/dev/null 2>&1 &&
		run nft list table inet podkopchik_native >/dev/null 2>&1 &&
		run nft list chain inet fw4 forward 2>/dev/null | grep -Fq "comment \"$alias\"" &&
		trial_running dns && trial_running dhcp
}
restore() {
	quarantine || return 1
	dev=$(link lan4) || return 1
	master=$(printf '%s\n' "$dev" | attr master || true)
	case "$master" in br-lan|br-pkc-test|'') ;; *) log foreign_lan4_master; return 1 ;; esac
	link br-lan >/dev/null 2>&1 || return 1
	if br=$(link br-pkc-test 2>/dev/null); then
		[ "$(printf '%s\n' "$br" | attr ifalias)" = "$alias" ] || { log foreign_canary_bridge; return 1; }
		members=$(run ip -j link show master br-pkc-test) || return 1
		case "$(printf '%s\n' "$members" | jsonfilter -q -e '@[*].ifname' || true)" in lan4|'') ;; *) return 1 ;; esac
	elif [ "$master" = br-pkc-test ]; then return 1
	fi
	if [ "$master" != br-lan ]; then run ip link set dev lan4 down || return 1; fi
	config_ok || { log household_config_drift; return 1; }
	for svc in dns dhcp xray; do stop_trial "$svc" || return 1; done
	listed=$(run nft -j -a list table inet fw4) || return 1
	remove_rules=$(printf '%s\n' "$listed" | data rules) || return 1
	listed=$(run nft -j list tables) || return 1
	remove_tables=$(printf '%s\n' "$listed" | data tables) || return 1
	printf '%s\n%s\n' "$remove_rules" "$remove_tables" | run nft -f - || return 1
	if [ "$master" = br-pkc-test ]; then run ip link set dev lan4 nomaster || return 1; fi
	if [ -n "$br" ]; then run ip link delete dev br-pkc-test type bridge || return 1; fi
	if [ "$master" != br-lan ]; then run ip link set dev lan4 master br-lan || return 1; fi
	dev=$(link lan4) || return 1
	admin=0
	if printf '%s\n' "$dev" | jsonfilter -q -e '@[0].flags[*]' | grep -qx UP; then admin=1; fi
	if [ "$admin" != "$up" ]; then
		if [ "$up" = 1 ]; then run ip link set dev lan4 up || return 1; else run ip link set dev lan4 down || return 1; fi
	fi
	[ "$(link lan4 | attr master)" = br-lan ] && config_ok
}

case "${1:-}" in
	boot)
		[ -f "$root/trial.json" ] || exit 0
		current=$(state poll) || { quarantine; log invalid_trial_state; exit 1; }
		case "$current" in rollback|restored) quarantine ;; waiting) : ;; *) exit 1 ;; esac
		;;
	watch)
		while :; do
			if [ ! -f "$root/trial.json" ]; then sleep 1; continue; fi
			current=$(state poll) || { quarantine; log invalid_trial_state; exit 1; }
			case "$current" in
				waiting)
					if [ -f "$root/active" ] && ! trial_healthy; then
						state abort || true
						log active_health_failed
					fi
					sleep 1 ;;
				restored) sleep 1 ;;
				rollback)
					if restore && state restored; then log restored; else log restore_pending; sleep 2; fi ;;
				*) quarantine; log unsupported_confirmation; exit 1 ;;
			esac
		done
		;;
	*) exit 2 ;;
esac
