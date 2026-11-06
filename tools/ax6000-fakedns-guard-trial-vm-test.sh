#!/bin/sh
set -eu
umask 077
. /mnt/lab/native-vm-only.sh
cd /mnt/lab
sha256sum -c guard-trial.tar.sha256
r="pkc-guard-vm-$$"
dirs=
cleanup() {
	for d in $dirs; do
		ubus call service delete "{\"name\":\"pkc-fake-guard-${d##*.}\"}" >/dev/null 2>&1 || true
		rm -rf "$d"
	done
	ip netns del "$r"
}
trap cleanup EXIT
ip netns add "$r"
rn() { ip netns exec "$r" "$@"; }
rn ip link set lo up
rn nft add table inet podkopchik
rn nft add chain inet podkopchik unchanged
rn fw4 reload
before=$(rn nft -s list ruleset | sha256sum)
rules=$(rn ip -N -4 -j rule show)
prepare() {
	epoch=$(tr -d '-' </proc/sys/kernel/random/uuid | cut -c1-16)
	d="/tmp/pkc-fake-guard.$epoch"
	dirs="$dirs $d"
	mkdir -p "$d/vm/usr/libexec/podkopchik" "$d/vm/etc/init.d" "$d/vm/etc/rc.d" "$d/vm/etc/podkopchik" "$d/vm/lib/upgrade/keep.d"
	mkdir -p "$d/vm/etc/hotplug.d/iface"
	tar -xf /mnt/lab/guard-trial.tar -C "$d"
	cp source/awg.uc "$d/vm/usr/libexec/podkopchik/"
	printf '%s\n' '{"fakedns":{"ipPool":"198.18.0.0/15"}}' > "$d/vm/etc/podkopchik/config.json"
}
act() { sh "$d/ax6000-fakedns-guard-trial.sh" --vm "$r" "$1" "$d"; }
await() {
	for i in $(seq 1 38); do
		if grep -qx "$1" "$d/state.txt" 2>/dev/null; then return; fi
		sleep 1
	done
	cat "$d/watch.log" >&2
	return 1
}
check_active() {
	rn nft -s list set inet podkopchik_fake_guard legacy4 | grep -Fq 198.18.0.0/15
	rn nft -s list set inet podkopchik_fake_guard native4 | grep -Fq 172.31.253.0/24
	[ "$(rn ip -N -4 -j rule show | jsonfilter -e '@[*].priority' | grep -cx 10992)" = 2 ]
}
prepare
rn nft add table inet podkopchik_fake_guard
if act arm >/dev/null 2>&1; then echo 'foreign guard admitted' >&2; exit 1; fi
rn nft delete table inet podkopchik_fake_guard
act arm
await active
check_active
[ -f "$d/vm/etc/hotplug.d/iface/95-podkopchik-fakedns" ]
! [ -e "$d/vm/etc/rc.d/S18podkopchik-fakedns" ]
rn fw4 reload
check_active
watch=$(ubus call service list "{\"name\":\"pkc-fake-guard-$epoch\"}" | jsonfilter -e '@.*.instances.main.pid')
kill -KILL "$watch"
await restored
[ "$(rn nft -s list ruleset | sha256sum)" = "$before" ]
[ "$(rn ip -N -4 -j rule show)" = "$rules" ]
! [ -e "$d/vm/etc/podkopchik/fakedns-guard.json" ]
! [ -e "$d/vm/usr/libexec/podkopchik/fakedns_guard.uc" ]
! [ -e "$d/vm/etc/init.d/podkopchik-fakedns" ]
[ ! -e "$d/vm/etc/hotplug.d/iface/95-podkopchik-fakedns" ]
echo 'PASS: staged install, fw4 reload, watchdog SIGKILL/respawn and automatic removal without SSH'
prepare
act arm
await active
act accept
await confirmed
check_active
[ "$(readlink "$d/vm/etc/rc.d/S18podkopchik-fakedns")" = ../init.d/podkopchik-fakedns ]
if act abort >/dev/null 2>&1; then echo 'committed trial accepted abort' >&2; exit 1; fi
echo 'PASS: explicit confirmation enables persistent boot hook only after verification'
guard_read() {
	rn env PODKOPCHIK_CONFIG_DIR="$d/vm/etc/podkopchik" PODKOPCHIK_TMP_DIR="$d/vm/status-readonly" \
		PODKOPCHIK_LIB="$d/vm/usr/libexec/podkopchik" sh "$d/fakedns_guard.sh" status
}
guard_read | grep -qx 'state=active'
[ ! -e "$d/vm/status-readonly" ]
handle=$(rn nft -a list chain inet podkopchik_fake_guard forward | awk '/# handle/ && /counter/ {print $NF; exit}')
[ -n "$handle" ]
rn nft delete rule inet podkopchik_fake_guard forward handle "$handle"
guard_read | grep -qx 'state=incomplete'
[ ! -e "$d/vm/status-readonly" ]
echo 'PASS: guard status detects partial rules and writes no temporary state'
