#!/bin/sh
# Isolated recovery after loss of the actual trial-owning shell.
set -eu
umask 077
. /mnt/lab/native-vm-only.sh
work=$(mktemp -d /tmp/native-dns-vm.XXXXXX)
ns="pkc-router-detached-$$"
watch="pkc-vm-watchdog-detached-$$"
dns="pkc-vm-dns-detached-$$"
manager=; stub=
cleanup() {
	ubus call service delete "{\"name\":\"$watch\"}" >/dev/null 2>&1 || true
	for p in $manager $stub; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done
	ip netns del "$ns"
}
trap cleanup EXIT
ip netns add "$ns"
ip -n "$ns" link set lo up
rn() { ip netns exec "$ns" "$@"; }
initscript="$0"
service_triggers() { :; }
set +eu
. /lib/functions/procd.sh
set -eu
ucode -L /mnt/lab/source /mnt/lab/source/native_dns_vm_plan.uc gate > "$work/gate"
ucode -L /mnt/lab/source /mnt/lab/source/native_dns_vm_plan.uc release > "$work/release"
rn nft -f "$work/gate"
printf '%s\n' 'add table inet pkc_legacy_control' > "$work/old-fw4.nft"
(cd "$work" && sha256sum old-fw4.nft release > backup.sha256)
PKC_NATIVE_LAB=dns ip netns exec "$ns" /mnt/lab/native-dns.test -test.run='^TestGuestFixture$' -- 127.0.0.1:53 tcp \
	> "$work/stock.log" 2>&1 & stub=$!

(
	ucode /mnt/lab/trial-state.uc arm "$work" 8
	set +eu
	procd_open_service "$watch"
	procd_open_instance main
	procd_set_param command /bin/sh /mnt/lab/native-vm-watchdog.sh "$ns" "$work" "$dns"
	procd_close_instance
	procd_close_service >/dev/null || exit 1
	: > "$work/manager-ready"
	exec sleep 30
) & manager=$!
for i in 1 2 3 4; do [ ! -f "$work/manager-ready" ] || break; sleep 1; done
[ -f "$work/manager-ready" ]
kill -KILL "$manager"
wait "$manager" 2>/dev/null || true
manager=
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do [ ! -f "$work/rollback-done" ] || break; sleep 1; done
[ -f "$work/rollback-done" ]
[ "$(ucode /mnt/lab/trial-state.uc poll "$work")" = restored ]
rn nft list table inet pkc_legacy_control >/dev/null
rn nft list chain inet podkopchik_native_gate flow_pin >/dev/null
echo 'PASS: timeout restored after loss of the trial-owning process; release was idempotent and quarantine survived'
