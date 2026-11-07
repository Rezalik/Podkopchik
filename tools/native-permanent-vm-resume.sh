#!/bin/sh
# Sourced only by the NIC-free persistent fixture after a real kernel reboot.
set -eu
[ -n "${PKC_VM_PERMANENT_STATE:-}" ]
[ -s "$work/early-guard.nft" ]
for address in 203.0.113.80:18084 '[2001:db8:80::1]:18084'; do
	case "$address" in \[*) family=6;; *) family=4;; esac
	PKC_NATIVE_LAB=https-serve ip netns exec "$w" "$bin" -test.run='^TestGuestFixture$' -- "$address" "$work/https$family.der" > "$work/reboot-tls$family.log" 2>&1 & pids="$pids $!"
done
native_env sh /etc/rc.common /mnt/lab/permanent/etc/init.d/podkopchik start
for attempt in $(seq 1 30); do
	ctl native-status > "$permanent/reboot-status.json"
	[ "$(jsonfilter -q -i "$permanent/reboot-status.json" -e '@.ready')" != true ] || break
	sleep 1
done
[ "$(jsonfilter -q -i "$permanent/reboot-status.json" -e '@.ready')" = true ] || {
	cat "$permanent/reboot-status.json" "$permanent/tmp/native-error"; fail 'confirmed native boot did not become ready'; }
old4=$(cat "$permanent/previous-v4")
old6=$(cat "$permanent/previous-v6")
for address in "$old4:18081" "[$old6]:18081"; do
	if ln wget -q -T 1 -O - "http://$address/" >/dev/null 2>&1; then fail 'prior-boot lease was trusted without fresh DNS'; fi
done
for proto in udp tcp; do
	fake=$(PKC_NATIVE_LAB=query ln "$bin" -test.run='^TestGuestFixture$' -- 10.19.0.1:53 "$proto" probe.protected.example. A NOERROR 1 | sed -n 's/^address=//p')
	[ "$fake" = "$old4" ]
	[ "$(ln wget -q -T 3 -O - "http://$fake:18081/")" = isolated-http-ok ]
	PKC_NATIVE_LAB=udp ln "$bin" -test.run='^TestGuestFixture$' -- "$fake:18081"
done
v4=$fake
v6=$(PKC_NATIVE_LAB=query ln "$bin" -test.run='^TestGuestFixture$' -- 10.19.0.1:53 tcp probe.protected.example. AAAA NOERROR 1 | sed -n 's/^address=//p')
PKC_NATIVE_LAB=https-client ln "$bin" -test.run='^TestGuestFixture$' -- "$v4:18084" "$work/https4.der"
PKC_NATIVE_LAB=https-client ln "$bin" -test.run='^TestGuestFixture$' -- "[$v6]:18084" "$work/https6.der"
PKC_NATIVE_LAB=quic-client ln "$bin" -test.run='^TestGuestFixture$' -- "$v4:18082" "$work/quic4.der"
PKC_NATIVE_LAB=quic-client ln "$bin" -test.run='^TestGuestFixture$' -- "[$v6]:18082" "$work/quic6.der"
echo 'PASS: actual reboot, production init dispatch, early LAN guard, no stale replay, fresh DNS revalidation and stable identity'
if [ ! -e "$PKC_VM_PERMANENT_STATE/pending-reboot" ]; then
	ctl apply > "$permanent/reboot-pending.json"
	touch "$PKC_VM_PERMANENT_STATE/pending-reboot"
	return
fi
[ -z "$(jsonfilter -q -i "$permanent/reboot-status.json" -e '@.pending')" ]
stale=$(jsonfilter -q -i "$permanent/reboot-pending.json" -e '@.pending')
if ctl native-confirm "$stale" > "$permanent/reboot-stale-confirm.log" 2>&1; then fail 'previous-boot pending trial was confirmed'; fi
echo 'PASS: reboot during an unconfirmed Apply autonomously restores the confirmed generation'
ctl cleanup
[ "$(uci -c "$permanent/uci" get podkopchik.main.routing_enabled)" = 0 ]
native_env sh /etc/rc.common /mnt/lab/permanent/etc/init.d/podkopchik start
[ -z "$(ubus call service list '{"name":"podkopchik-native-dns"}' | jsonfilter -q -e '@.*.instances.main.pid')" ]
rn nft list table inet podkopchik_fake_guard >/dev/null
echo 'PASS: explicit routing disable survives production boot dispatch; quarantine remains'
