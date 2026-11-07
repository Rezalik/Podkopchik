#!/bin/sh
# Extended production-service tests; sourced in the same isolated whole-LAN VM.
set -eu
ready_native() {
	for attempt in $(seq 1 35); do
		ctl native-status > "$permanent/lifecycle-status.json"
		[ "$(jsonfilter -q -i "$permanent/lifecycle-status.json" -e '@.ready')" != true ] || return 0
		sleep 1
	done
	cat "$permanent/lifecycle-status.json" "$permanent/tmp/native-error"; fail 'lifecycle readiness'
}
confirm_native() {
	for attempt in $(seq 1 15); do
		ready_native
		token=$(jsonfilter -q -i "$permanent/lifecycle-status.json" -e '@.pending')
		if ctl native-confirm "$token"; then return 0; fi
		sleep 1
	done
	fail 'ready generation did not pass confirmation health recheck'
}
if [ -f "$PKC_VM_PERMANENT_STATE/disabled-reboot" ]; then
	native_env sh /etc/rc.common /mnt/lab/permanent/etc/init.d/podkopchik start
	[ "$(uci -c "$permanent/uci" get podkopchik.main.routing_enabled)" = 0 ]
	[ -z "$(ubus call service list '{"name":"podkopchik-native-dns"}' | jsonfilter -q -e '@.*.instances.main.pid')" ]
	if rn nft list table inet podkopchik_native >/dev/null 2>&1; then fail 'manual OFF did not survive actual reboot'; fi
	rn nft list table inet podkopchik_fake_guard >/dev/null
	native_env /sbin/ip netns exec "$r" "$daemon" -probe 127.0.0.1:53
	touch "$PKC_VM_PERMANENT_STATE/EXTENDED-PASS"
	echo 'PASS: explicit OFF survives real reboot, production init leaves DNS on dnsmasq and retains synthetic quarantine'
	return
fi
# A failed fixture may have left an intentionally unconfirmed generation.
# Reset only this VM's explicit intent before rerunning the lifecycle matrix.
if [ -n "$(jsonfilter -q -i "$permanent/config/native-state/runtime.json" -e '@.pending')" ]; then ctl cleanup; fi
# Exercise an application-code upgrade; confirmed recovery sources remain frozen.
cp /mnt/lab/permanent/usr/libexec/podkopchik/native_runtime.uc "$permanent/lib/native_runtime.uc"
cp /mnt/lab/native-permanent-vm-awg.uc "$permanent/lib/awg_network.uc"
cp /mnt/lab/permanent/usr/bin/podkopchikctl "$permanent/ctl"
chmod 700 "$permanent/ctl"
ctl validate > "$permanent/resource-budget.json"
ctl apply > "$permanent/lifecycle-apply.json"
ready_native
confirm_native
pid=$(ubus call service list '{"name":"podkopchik-native-dns"}' | jsonfilter -q -e '@.*.instances.main.pid')
for service in podkopchik-native-watch podkopchik-native-dns podkopchik-native-health; do
	ubus call service list "{\"name\":\"$service\"}" > "$permanent/respawn.json"
	[ "$(jsonfilter -q -i "$permanent/respawn.json" -e '@.*.instances.main.respawn.threshold')" = 3600 ]
	[ "$(jsonfilter -q -i "$permanent/respawn.json" -e '@.*.instances.main.respawn.timeout')" = 1 ]
	[ "$(jsonfilter -q -i "$permanent/respawn.json" -e '@.*.instances.main.respawn.retry')" = 0 ]
done
echo 'PASS: actual procd respawn retains bounded restart delay and unlimited supervisor recovery'
ucode -e 'import * as fs from "fs";let p=ARGV[0],s=fs.readfile("/proc/"+p+"/status");
	printf("RESOURCE pid=%s fd=%d rss_kib=%s conntrack=%s\n",p,length(fs.lsdir("/proc/"+p+"/fd") || []),match(s,/VmRSS:[ \t]+([0-9]+)/)?.[1],trim(fs.readfile("/proc/sys/net/netfilter/nf_conntrack_count") || "unavailable"));' "$pid"
for action in stop start restart; do
	native_env sh /etc/rc.common /mnt/lab/permanent/etc/init.d/podkopchik "$action"
	if [ "$action" = stop ]; then
		native_env /sbin/ip netns exec "$r" "$daemon" -probe 127.0.0.1:53
		if ln wget -q -T 1 -O - http://203.0.113.80:18081/ >/dev/null 2>&1; then fail 'service stop opened protected forwarding'; fi
	else ready_native; fi
done
echo 'PASS: exact production procd start/stop/restart dispatch, guarded service stop and stock DNS availability'

pool=$(jsonfilter -q -i "$permanent/config/native-state/runtime.json" -e '@.current')
epoch=$(jsonfilter -q -i "$permanent/config/native-state/g-$pool/plan.json" -e '@.epoch')
bindings="$permanent/config/native-state/pools/$epoch/watermark.bindings"
cp "$bindings" "$permanent/bindings-before-corruption"
printf '%s\n' '{corrupt}' >> "$bindings"
ubus call service delete '{"name":"podkopchik-native-dns"}' >/dev/null
for attempt in $(seq 1 100); do
	ctl native-status > "$permanent/lifecycle-status.json"
	[ "$(jsonfilter -q -i "$permanent/lifecycle-status.json" -e '@.phase')" != recovery ] || break
	sleep 1
done
[ "$(jsonfilter -q -i "$permanent/lifecycle-status.json" -e '@.phase')" = recovery ] || fail 'persistent DNS failure did not restore protected stock DNS'
PKC_NATIVE_LAB=query ln "$bin" -test.run='^TestGuestFixture$' -- 10.19.0.1:53 udp probe.protected.example. A NOERROR 1 >/dev/null
[ "$(ln wget -q -T 3 -O - http://203.0.113.80:18081/)" = isolated-http-ok ]
[ "$(ln wget -q -T 3 -O - http://203.0.113.81:18081/)" = isolated-http-ok ]
echo 'PASS: corrupt durable DNS journal fails closed and autonomously restores stock DNS under protected real-IP routing'
cp "$permanent/bindings-before-corruption" "$bindings"
ctl apply > "$permanent/recovery-reapply.json"
ready_native
confirm_native
ctl cleanup
touch "$PKC_VM_PERMANENT_STATE/disabled-reboot"
echo 'PASS: fresh confirmed Apply exits recovery; explicit OFF prepared for actual reboot'
