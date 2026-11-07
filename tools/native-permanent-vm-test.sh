#!/bin/sh
# Sourced by the NIC-free full-LAN fixture, never on physical hardware.
set -eu
permanent="$work/permanent"
mkdir -m700 -p "$permanent/lib" "$permanent/config/awg" "$permanent/uci" "$permanent/tmp"
resuming=0
[ ! -s "$permanent/config/native-state/runtime.json" ] || resuming=1
if [ "$resuming" = 0 ]; then
cp /mnt/lab/permanent/usr/libexec/podkopchik/* "$permanent/lib/"
cp /mnt/lab/permanent/usr/bin/podkopchikctl "$permanent/ctl"
chmod 700 "$permanent/ctl"
cp "$permanent/lib/awg_network.uc" "$permanent/lib/awg_network_real.uc"
cp /mnt/lab/native-permanent-vm-awg.uc "$permanent/lib/awg_network.uc"
cp "$work/firewall-base" "$permanent/uci/firewall"
cp "$work/firewall-base" "$permanent/firewall-original"
printf '%s\n' '{"fakedns":{"ipPool":"198.18.0.0/15","poolSize":65535}}' > "$permanent/config/config.json"
chmod 600 "$permanent/config/config.json"
for id in 11111111111111111111111111111111 22222222222222222222222222222222; do
	case "$id" in 1*) i=1;; *) i=2;; esac
	rn ip link set "paw$(printf '%s' "$id" | cut -c1-12)" alias "podkopchik-awg:$id"
	printf '{"id":"%s","revision":"%s","name":"VM transport %s"}\n' "$id" "$id" "$i" > "$permanent/config/awg/$id.json"
	printf '[Interface]\nPrivateKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=\nAddress = 198.51.%s.1/24,2001:db8:%s::1/64\nRandomTrailers = on\n[Peer]\nPublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=\nEndpoint = 192.0.2.2:51820\nAllowedIPs = 0.0.0.0/0,::/0\n' "$i" "$i" > "$permanent/config/awg/$id.$id.conf"
done
cat > "$permanent/uci/podkopchik" <<'EOF'
config settings 'main'
 option enabled '1'
 option routing_enabled '0'
 option routing_engine 'native'
 option lan_ifname 'br-lan'
 option native_pool_v4 '172.31.253.0/24'
 option native_pool_v6 '2001:2::/48'
 option native_dns_port '24253'
 option native_direct_grants_confirmed '1'
 option fakedns_enabled '1'
 option interval '2'
 option fail_threshold '2'
 option restore_threshold '2'
 option switch_cooldown '2'
config proxy
 option protocol 'amneziawg'
 option tag 'awg_11111111111111111111111111111111'
 option awg_id '11111111111111111111111111111111'
config proxy
 option protocol 'amneziawg'
 option tag 'awg_22222222222222222222222222222222'
 option awg_id '22222222222222222222222222222222'
config proxy_group
 option tag 'auto_proxy_group'
 option primary 'awg_11111111111111111111111111111111'
 option backup1 'awg_22222222222222222222222222222222'
config domain_rule
 list domain 'protected.example'
 option target 'auto_proxy_group'
config ip_rule
 option cidr '203.0.113.81/32'
 option target 'direct'
config ip_rule
 option cidr '203.0.113.82/32'
 option target 'auto_proxy_group'
config lan_device
 option source_ip '10.19.0.4'
 option mode 'direct'
config lan_device
 option source_ip '10.19.0.3'
 option mode 'full_proxy'
 option target 'awg_22222222222222222222222222222222'
EOF
chmod 600 "$permanent/uci/"* "$permanent/config/awg/"*
fi
for id in 11111111111111111111111111111111 22222222222222222222222222222222; do
	rn ip link set "paw$(printf '%s' "$id" | cut -c1-12)" alias "podkopchik-awg:$id"
done
mkdir -p "$permanent/core"
command ln -sf "$xray" "$permanent/core/xray"
printf '%s\n' local > "$permanent/core/selected"
native_env() {
	env PODKOPCHIK_LIB="$permanent/lib" PODKOPCHIK_CTL="$permanent/ctl" \
		PODKOPCHIK_CORE_DIR="$permanent/core" \
		PODKOPCHIK_NATIVE_DNS="$daemon" PODKOPCHIK_UCI_CONFIG_DIR="$permanent/uci" \
		PODKOPCHIK_CONFIG_DIR="$permanent/config" PODKOPCHIK_TMP_DIR="$permanent/tmp" PKC_NATIVE_VM_NS="$r" "$@"
}
ctl() { native_env sh "$permanent/ctl" "$@"; }
native_status() { ctl native-status > "$permanent/status.json"; }
wait_ready_native() {
	for attempt in $(seq 1 25); do native_status
		[ "$(jsonfilter -q -i "$permanent/status.json" -e '@.ready')" != true ] || return 0
		sleep 1
	done
	cat "$permanent/status.json"; fail 'native generation failed to become ready'
}
wait_auto() {
	for attempt in $(seq 1 20); do
		native_status
		[ "$(jsonfilter -q -i "$permanent/status.json" -e '@.automatic.active')" != "$1" ] || return 0
		sleep 1
	done
	cat "$permanent/tmp/state.json" "$permanent/status.json"; fail 'health did not update the active Core selection'
}
permanent_cleanup() {
	for service in podkopchik-native-watch podkopchik-native-dns podkopchik-native-health podkopchik-native-xray; do
		ubus call service delete "{\"name\":\"$service\"}" >/dev/null 2>&1 || true
	done
	cleanup
}
trap permanent_cleanup EXIT
fresh_state() {
	ucode -e 'printf("%J",{proxies:{awg_11111111111111111111111111111111:{status:"up",probe_status:"up",checked_at:time()},awg_22222222222222222222222222222222:{status:"up",probe_status:"up",checked_at:time()}}});' > "$permanent/tmp/state.json"
}
fresh_state
rn nft delete table inet podkopchik_native_gate
rn ip addr del 198.19.0.1/32 dev lo
for family in 4 6; do
	rn ip "-$family" rule del priority "$xprio" fwmark "$xmark" table "$xtable"
	rn ip "-$family" route del local default dev lo table "$xtable"
done
if [ "$resuming" = 1 ]; then
	if [ "${PKC_VM_RUNTIME_EXTENDED:-0}" = 1 ]; then . /mnt/lab/native-permanent-vm-lifecycle.sh; return; fi
	. /mnt/lab/native-permanent-vm-resume.sh
	return
fi
ctl apply > "$permanent/apply.json"
cat "$permanent/apply.json"
for i in $(seq 1 30); do
	ctl native-status > "$permanent/status.json"
	[ "$(jsonfilter -q -i "$permanent/status.json" -e '@.ready')" != true ] || break
	sleep 1
done
cat "$permanent/status.json"
[ "$(jsonfilter -q -i "$permanent/status.json" -e '@.ready')" = true ] || {
	logread | tail -15; cat "$permanent/tmp/native-error" "$permanent/tmp/native-last-command.json" "$permanent/tmp/native-command.err"; fail 'permanent Apply not ready'; }
token=$(jsonfilter -q -i "$permanent/status.json" -e '@.pending')
ctl native-confirm "$token"
for service in podkopchik-native-watch podkopchik-native-dns podkopchik-native-health; do
	ubus call service list "{\"name\":\"$service\"}" > "$permanent/respawn.json"
	[ "$(jsonfilter -q -i "$permanent/respawn.json" -e '@.*.instances.main.respawn.threshold')" = 3600 ]
	[ "$(jsonfilter -q -i "$permanent/respawn.json" -e '@.*.instances.main.respawn.timeout')" = 1 ]
done
for proto in udp tcp; do
	PKC_NATIVE_LAB=query ln "$bin" -test.run='^TestGuestFixture$' -- 10.19.0.1:53 "$proto" probe.protected.example. A NOERROR 1 > "$permanent/query-$proto"
done
echo 'PASS: ordinary full-LAN Apply, explicit confirmation, UDP/TCP DNS, AWG-only without Xray'
query_native() { PKC_NATIVE_LAB=query ln "$bin" -test.run='^TestGuestFixture$' -- 10.19.0.1:53 "$@"; }
v4=$(query_native udp probe.protected.example. A NOERROR 1 | sed -n 's/^address=//p')
v6=$(query_native tcp probe.protected.example. AAAA NOERROR 1 | sed -n 's/^address=//p')
for family in 4 6; do
	address=203.0.113.80:18084
	[ "$family" = 4 ] || address='[2001:db8:80::1]:18084'
	PKC_NATIVE_LAB=https-serve ip netns exec "$w" "$bin" -test.run='^TestGuestFixture$' -- "$address" "$work/https$family.der" >"$work/https$family.log" 2>&1 & pids="$pids $!"
done
if [ "${PKC_VM_ONLY_MIXED:-0}" = 1 ]; then
	. /mnt/lab/native-permanent-vm-vless.sh
	return
fi
ip netns exec "$w" tcpdump --immediate-mode -U -i external0 -Q in -nn -s 96 -w "$permanent/wan.pcap" \
	"$pools or host 203.0.113.80 or host 2001:db8:80::1" >"$permanent/wan.log" 2>&1 &
wan_cap=$!; caps="$caps $wan_cap"
ip netns exec "$w" tcpdump --immediate-mode -U -i tunnel0 -Q in -nn -s 96 -w "$permanent/awg.pcap" \
	'port 18081 or port 18082 or port 18084' >"$permanent/awg.log" 2>&1 &
awg_cap=$!; caps="$caps $awg_cap"
ip netns exec "$w" tcpdump --immediate-mode -U -i tunnel1 -Q in -nn -s 96 -w "$permanent/backup.pcap" \
	'port 18081 or port 18082 or port 18084' >"$permanent/backup.log" 2>&1 &
backup_cap=$!; caps="$caps $backup_cap"
sleep 1
rn nft add table inet pkc_permanent_trace
rn nft 'add chain inet pkc_permanent_trace pre { type filter hook prerouting priority -400; policy accept; }'
rn nft add rule inet pkc_permanent_trace pre iifname br-lan ip daddr "$v4" meta nftrace set 1
ip netns exec "$r" nft monitor trace > "$permanent/trace.log" 2>&1 & trace_pid=$!; pids="$pids $trace_pid"
for addr in "$v4:18081" "[$v6]:18081"; do
	if [ "$(ln wget -q -T 3 -O - "http://$addr/")" != isolated-http-ok ]; then
		ln ip rule; ln ip route; ln nft list ruleset; rn nft list table inet podkopchik_native_transition || true
		PKC_NATIVE_LAB=cached-http ln "$bin" -test.run='^TestGuestFixture$' -- "$v4" protected.example || true
		cat "$permanent/trace.log"; rn ip route get 203.0.113.80 from 10.19.0.2 iif br-lan mark 536917281
		ctl native-status; rn ip rule; rn nft list table inet podkopchik_native; rn nft list table inet podkopchik_native_gate
		fail 'full-LAN Native TCP did not reach the peer'
	fi
	PKC_NATIVE_LAB=udp ln "$bin" -test.run='^TestGuestFixture$' -- "$addr"
done
PKC_NATIVE_LAB=https-client ln "$bin" -test.run='^TestGuestFixture$' -- "$v4:18084" "$work/https4.der"
PKC_NATIVE_LAB=https-client ln "$bin" -test.run='^TestGuestFixture$' -- "[$v6]:18084" "$work/https6.der"
PKC_NATIVE_LAB=quic-client ln "$bin" -test.run='^TestGuestFixture$' -- "$v4:18082" "$work/quic4.der"
PKC_NATIVE_LAB=quic-client ln "$bin" -test.run='^TestGuestFixture$' -- "[$v6]:18082" "$work/quic6.der"
for ip in 203.0.113.80 2001:db8:80::1; do
	PKC_NATIVE_LAB=cached-http ln "$bin" -test.run='^TestGuestFixture$' -- "$ip" protected.example
done
PKC_NATIVE_LAB=source-http ln "$bin" -test.run='^TestGuestFixture$' -- 203.0.113.80 protected.example 10.19.0.3
[ "$(ln wget -q -T 3 -O - http://203.0.113.82:18080/)" = isolated-http-ok ]
for addr in 172.31.253.254 198.19.28.7; do
	if ln wget -q -T 1 -O - "http://$addr:18081/" >/dev/null 2>&1; then fail 'unknown or retired synthetic address escaped'; fi
done
touch "$permanent/tmp/probe-down-11111111111111111111111111111111"
wait_auto awg_22222222222222222222222222222222
if [ "$(ln wget -q -T 3 -O - "http://$v4:18081/")" != isolated-http-ok ]; then
	cat "$permanent/trace.log"; rn nft list table inet podkopchik_native; rn nft list table inet podkopchik_native_gate; rn nft list table inet podkopchik_fake_guard
	fail 'synthetic TCP failed after the real Core selected the backup'
fi
PKC_NATIVE_LAB=udp ln "$bin" -test.run='^TestGuestFixture$' -- "$v4:18081"
touch "$permanent/tmp/probe-down-22222222222222222222222222222222"
wait_auto blocked
if ln wget -q -T 1 -O - "http://$v4:18081/" >/dev/null 2>&1; then fail 'all-down leaked a protected connection'; fi
if PKC_NATIVE_LAB=udp ln "$bin" -test.run='^TestGuestFixture$' -- "$v4:18081" >/dev/null 2>&1; then fail 'all-down leaked UDP'; fi
[ "$(ln wget -q -T 3 -O - http://203.0.113.81:18081/)" = isolated-http-ok ]
rm "$permanent/tmp/probe-down-11111111111111111111111111111111"
wait_auto awg_11111111111111111111111111111111
[ "$(query_native tcp probe.protected.example. A NOERROR 1 | sed -n 's/^address=//p')" = "$v4" ]
rm "$permanent/tmp/probe-down-22222222222222222222222222222222"
echo 'PASS: actual health daemon hysteresis, AWG-to-AWG, all-down TCP/UDP fail-closed, direct retention and primary return'
kill "$wan_cap" "$awg_cap" "$backup_cap"; wait "$wan_cap" "$awg_cap" "$backup_cap" 2>/dev/null || true
[ "$(wn tcpdump -nr "$permanent/wan.pcap" 2>/dev/null | wc -l)" = 0 ] || fail 'protected packet reached VM WAN'
[ "$(wn tcpdump -nr "$permanent/awg.pcap" 2>/dev/null | wc -l)" -gt 10 ] || fail 'no native tunnel packet evidence'
[ "$(wn tcpdump -nr "$permanent/backup.pcap" 2>/dev/null | wc -l)" -gt 2 ] || fail 'no backup transport packet evidence'
echo 'PASS: native dual-stack TCP, HTTPS, UDP echo, QUIC, shared cached CDN, unknown/retired pools; 0 protected packets on virtual WAN'
[ "$(ln wget -q -T 3 -O - http://203.0.113.81:18081/)" = isolated-http-ok ]
PKC_NATIVE_LAB=direct-client ln "$bin" -test.run='^TestGuestFixture$' -- 10.19.0.1:53 10.19.0.4
echo 'PASS: explicit direct CIDR and whole-client exception retain documented scope'

dns_pid() { ubus call service list '{"name":"podkopchik-native-dns"}' | jsonfilter -q -e '@.*.instances.main.pid'; }
watch_pid() { ubus call service list '{"name":"podkopchik-native-watch"}' | jsonfilter -q -e '@.*.instances.main.pid'; }
before_dns=$(dns_pid)
cp "$permanent/uci/podkopchik" "$permanent/valid-uci"
uci -c "$permanent/uci" set podkopchik.@ip_rule[0].cidr=invalid
uci -c "$permanent/uci" commit podkopchik
if ctl apply > "$permanent/invalid.log" 2>&1; then fail 'invalid Apply was accepted'; fi
[ "$(dns_pid)" = "$before_dns" ]
[ "$(ln wget -q -T 3 -O - "http://$v4:18081/")" = isolated-http-ok ]
cp "$permanent/valid-uci" "$permanent/uci/podkopchik"
echo 'PASS: invalid Apply preserves active DNS, interception and user routing intent'

if ! rn sh -c 'mount --bind "$1" /etc/config/firewall; sh -x /sbin/fw4 reload' fw4 "$permanent/uci/firewall" > "$permanent/fw4-reload.log" 2>&1; then
	cat "$permanent/fw4-reload.log"; cat "$permanent/tmp/native-command.err"; fail 'firewall4 reload/reconcile failed'
fi
wait_ready_native
for attempt in $(seq 1 10); do
	[ "$(ln wget -q -T 2 -O - "http://$v4:18081/")" != isolated-http-ok ] || break
	sleep 1
done
[ "$attempt" -lt 10 ]
[ "$(dns_pid)" = "$before_dns" ]
echo 'PASS: firewall4 reload restores owned permits without restarting DNS or transports'

kill -KILL "$before_dns"
wait_ready_native
[ "$(dns_pid)" != "$before_dns" ]
[ "$(query_native udp probe.protected.example. A NOERROR 1 | sed -n 's/^address=//p')" = "$v4" ]
before_dns=$(dns_pid)
before_watch=$(watch_pid)
kill -KILL "$before_watch"
sleep 2
wait_ready_native
[ "$(watch_pid)" != "$before_watch" ]
[ "$(dns_pid)" = "$before_dns" ]
echo 'PASS: classifier and supervisor SIGKILL recovery preserve pool ownership and stable bindings'

PKC_NATIVE_LAB=hold ip netns exec "$l" "$bin" -test.run='^TestGuestFixture$' -- "$v4:18081" "$permanent/hold-ready" "$permanent/hold-send" apply > "$permanent/hold.log" 2>&1 &
hold_pid=$!; pids="$pids $hold_pid"
for attempt in $(seq 1 10); do [ ! -f "$permanent/hold-ready" ] || break; sleep 1; done
[ -f "$permanent/hold-ready" ]
ctl apply > "$permanent/reapply.json"
wait_ready_native
token=$(jsonfilter -q -i "$permanent/status.json" -e '@.pending')
ctl native-confirm "$token"
touch "$permanent/hold-send"
wait "$hold_pid" || { cat "$permanent/hold.log"; fail 'repeated Apply broke an established tuple'; }
[ "$(query_native udp probe.protected.example. A NOERROR 1 | sed -n 's/^address=//p')" = "$v4" ]
echo 'PASS: repeated confirmed Apply preserves live TCP, leases, conntrack pin and synthetic identity'
. /mnt/lab/native-permanent-vm-nft-failure.sh

if [ -z "${PKC_VM_PERMANENT_STATE:-}" ]; then
	. /mnt/lab/native-permanent-vm-vless.sh
	native_status
	token=$(jsonfilter -q -i "$permanent/status.json" -e '@.confirmed')
fi

confirmed=$token
uci -c "$permanent/uci" set podkopchik.main.native_confirm_seconds=60
uci -c "$permanent/uci" commit podkopchik
ctl apply > "$permanent/unconfirmed.json"
expired=$(jsonfilter -q -i "$permanent/unconfirmed.json" -e '@.pending')
sleep 65
for attempt in $(seq 1 35); do
	native_status
	pending=$(jsonfilter -q -i "$permanent/status.json" -e '@.pending') || pending=''
	[ -n "$pending" ] || break
	sleep 1
done
wait_ready_native
[ "$(jsonfilter -q -i "$permanent/status.json" -e '@.confirmed')" = "$confirmed" ]
[ -z "$(jsonfilter -q -i "$permanent/status.json" -e '@.pending')" ]
if ctl native-confirm "$expired" > "$permanent/expired.log" 2>&1; then fail 'expired generation was confirmed'; fi
[ "$(query_native udp probe.protected.example. A NOERROR 1 | sed -n 's/^address=//p')" = "$v4" ]
echo 'PASS: fixed autonomous confirmation timeout restores the last confirmed whole-LAN generation'
if [ -n "${PKC_VM_PERMANENT_STATE:-}" ]; then
	printf '%s\n' "$v4" > "$permanent/previous-v4"
	printf '%s\n' "$v6" > "$permanent/previous-v6"
	return
fi
ctl cleanup
