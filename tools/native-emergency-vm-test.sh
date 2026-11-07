#!/bin/sh
# Full restore in the isolated guest; no physical interface or router secrets.
set -eu
. /mnt/lab/native-vm-only.sh
export PKC_EMERGENCY_VM_NS="$r" PKC_EMERGENCY_VM_ROOT="$work/emergency" PKC_EMERGENCY_VM_XRAY="$xray"
emergency() { native_env ucode -L "$permanent/lib" "$permanent/lib/native_emergency.uc" "$@"; }
emergency_clean() {
	for service in podkopchik-native-emergency podkopchik-native-emergency-xray podkopchik; do stop_service "$service"; done
	permanent_cleanup
}
trap emergency_clean EXIT
rn ip rule add priority 10991 fwmark 0x100000 table 10991
rn ip route add local default dev lo table 10991
cat > "$permanent/config/config.json" <<'EOF'
{"log":{"loglevel":"warning"},"fakedns":{"ipPool":"198.18.0.0/15","poolSize":65535},"inbounds":[{"tag":"transparent","listen":"0.0.0.0","port":12345,"protocol":"dokodemo-door","settings":{"network":"tcp,udp","followRedirect":true},"streamSettings":{"sockopt":{"tproxy":"tproxy"}}}],"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"awg_11111111111111111111111111111111","protocol":"freedom","streamSettings":{"sockopt":{"interface":"paw111111111111","mark":536917281}}}],"routing":{"rules":[]}}
EOF
ucode -e 'import * as fs from "fs";let p=json(fs.readfile(ARGV[0]));
	p.inbounds[0].sniffing={enabled:true,destOverride:["http","tls","fakedns"]};
	push(p.inbounds,{tag:"dns-in",listen:"0.0.0.0",port:1053,protocol:"dokodemo-door",settings:{address:"8.8.8.8",port:53,network:"tcp,udp"}});
	push(p.outbounds,{tag:"dns-out",protocol:"dns"});p.dns={servers:["fakedns"]};
	p.routing.rules=[{type:"field",inboundTag:["dns-in"],outboundTag:"dns-out"}];printf("%J\n",p);' "$permanent/config/config.json" > "$permanent/config/rescue-fixture.next"
mv "$permanent/config/rescue-fixture.next" "$permanent/config/config.json"
chmod 600 "$permanent/config/config.json"
ucode -e 'import * as f from "fs";let p=json(f.readfile(ARGV[0]));p.groups={auto_proxy_group:{active_proxy:"awg_11111111111111111111111111111111"}};printf("%J",p);' "$permanent/tmp/state.json" > "$permanent/state.next"
mv "$permanent/state.next" "$permanent/tmp/state.json"
cat > "$permanent/emergency-legacy.nft" <<'EOF'
add table inet podkopchik
add chain inet podkopchik prerouting { type filter hook prerouting priority mangle; policy accept; }
add rule inet podkopchik prerouting iifname "br-lan" fib daddr type local return
add rule inet podkopchik prerouting iifname "br-lan" meta l4proto tcp meta mark set 0x100000 tproxy to :12345 accept
add chain inet podkopchik dns_prerouting { type nat hook prerouting priority dstnat; policy accept; }
add rule inet podkopchik dns_prerouting iifname "br-lan" udp dport 53 redirect to :1053
add rule inet podkopchik dns_prerouting iifname "br-lan" tcp dport 53 redirect to :1053
EOF
rn nft -f "$permanent/emergency-legacy.nft"
printf '%s\n' podkopchik-routing-v1 > "$permanent/tmp/routing.env"
chmod 600 "$permanent/tmp/routing.env"
ubus call service set "{\"name\":\"podkopchik\",\"instances\":{\"xray\":{\"command\":[\"/sbin/ip\",\"netns\",\"exec\",\"$r\",\"$xray\",\"run\",\"-config\",\"$permanent/config/config.json\"],\"respawn\":[\"3600\",\"1\",\"0\"]}}}" >/dev/null
baseline_pid() { ubus call service list '{"name":"podkopchik"}' | jsonfilter -q -e '@.*.instances.xray.pid'; }
for i in $(seq 1 10); do [ -z "$(baseline_pid || true)" ] || break; sleep 1; done
[ -n "$(baseline_pid)" ]
uci -c "$permanent/uci" set podkopchik.main.routing_enabled=1
uci -c "$permanent/uci" commit podkopchik
emergency prepare 172.31.253.0/24
if rn nft list table inet podkopchik_native_emergency >/dev/null 2>&1; then fail 'prepare changed the packet path'; fi
old=$(baseline_pid)
lease=$(emergency arm 10)
rn nft 'add table inet pkc_native_emergency_test { comment "podkopchik-native-emergency-v1"; }'
for i in $(seq 1 18); do
	emergency status > "$permanent/emergency-status.json"
	[ "$(jsonfilter -i "$permanent/emergency-status.json" -e '@.mode')" != rehearsed ] || break
	sleep 1
done
[ "$(baseline_pid)" = "$old" ]
[ "$(jsonfilter -i "$permanent/emergency-status.json" -e '@.mode')" = rehearsed ]
if rn nft list table inet pkc_native_emergency_test >/dev/null 2>&1; then fail 'independent rehearsal left its table'; fi
echo 'PASS: emergency prepare is inactive; detached procd deadline removes only its fixture and retains the baseline PID'
lease=$(emergency arm 120)
uci -c "$permanent/uci" set podkopchik.main.native_recovery_policy=repair
uci -c "$permanent/uci" commit podkopchik
ctl apply > "$permanent/repair-apply.json"
wait_ready_native
token=$(jsonfilter -i "$permanent/status.json" -e '@.pending')
ctl native-confirm "$token"
emergency accept "$lease"
[ -z "$(baseline_pid || true)" ] || fail 'legacy Xray survived Native cutover'
# A dead upstream must not restore legacy while management is healthy.
cp "$permanent/tmp/native-dns-upstream.json" "$permanent/dns-good.json"
printf '%s\n' '{"schema":1,"endpoints":[{"address":"203.0.113.80:1853","name":"wrong.invalid"}],"transports":[]}' > "$permanent/tmp/native-dns-upstream.json"
chmod 600 "$permanent/tmp/native-dns-upstream.json"
PKC_NATIVE_LAB=query ln "$bin" -test.run='^TestGuestFixture$' -- 10.19.0.1:53 udp uncached.protected.example. A SERVFAIL 0
sleep 3
native_status
[ "$(jsonfilter -i "$permanent/status.json" -e '@.engine')" = native ]
[ -z "$(service_pid podkopchik-native-emergency-xray || true)" ]
cp "$permanent/dns-good.json" "$permanent/tmp/native-dns-upstream.json"
echo 'PASS: protected upstream all-down fails closed without emergency rollback'
if [ "${PKC_VM_SKIP_REPAIR_FAULTS:-0}" != 1 ]; then . /mnt/lab/native-repair-vm-nft-failure.sh; fi
# Request an emergency, kill the owning shell-equivalent supervisor and prove
# the independent capsule restores the path rather than just writing a log.
emergency request
for i in $(seq 1 35); do
	emergency status > "$permanent/emergency-status.json"
	[ "$(jsonfilter -i "$permanent/emergency-status.json" -e '@.mode')" != restored ] || break
	sleep 1
done
[ "$(jsonfilter -i "$permanent/emergency-status.json" -e '@.mode')" = restored ] || { cat "$work/emergency/recovery.log"; fail 'emergency restore not completed'; }
rn nft list table inet podkopchik_native_emergency > "$permanent/emergency-guard.txt"
grep -q '198.18.0.0/15' "$permanent/emergency-guard.txt"
grep -q '172.31.253.0/24' "$permanent/emergency-guard.txt"
if rn nft list table inet podkopchik_native >/dev/null 2>&1; then fail 'native table left after emergency'; fi
[ -n "$(service_pid podkopchik-native-emergency-xray)" ]
for proto in udp tcp; do
	PKC_NATIVE_LAB=query ln "$bin" -test.run='^TestGuestFixture$' -- 10.19.0.1:53 "$proto" probe.protected.example. A NOERROR 1 > "$permanent/rescue-dns-$proto.log"
	grep -Eq '^address=198\.(18|19)\.' "$permanent/rescue-dns-$proto.log" || { cat "$permanent/rescue-dns-$proto.log"; fail 'emergency DNS did not restore the legacy pool'; }
done
ip netns exec "$w" tcpdump -U -nn -i external0 -w "$permanent/rescue-wan.pcap" 'host 203.0.113.80 and port 18081' > "$permanent/rescue-wan.log" 2>&1 & cwan=$!; caps="$caps $cwan"
ip netns exec "$w" tcpdump -U -nn -i tunnel0 -w "$permanent/rescue-awg.pcap" 'host 203.0.113.80 and port 18081' > "$permanent/rescue-awg.log" 2>&1 & cawg=$!; caps="$caps $cawg"
sleep 1
[ "$(ln wget -q -T 5 -O - http://203.0.113.80:18081/)" = isolated-http-ok ]
if PKC_NATIVE_LAB=dial ln "$bin" -test.run='^TestGuestFixture$' -- 172.31.253.253:18081 > "$permanent/rescue-retired.log" 2>&1; then fail 'retired pool reachable after emergency'; fi
kill "$cwan" "$cawg"; wait "$cwan" || true; wait "$cawg" || true
[ "$(tcpdump -nn -r "$permanent/rescue-wan.pcap" 2>/dev/null | wc -l)" = 0 ]
[ "$(tcpdump -nn -r "$permanent/rescue-awg.pcap" 2>/dev/null | wc -l)" -gt 0 ]
echo 'PASS: emergency restore provides protected legacy TCP through the AWG stand-in, retains both pool guards and removes Native routing'
