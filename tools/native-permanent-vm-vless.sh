#!/bin/sh
# Public deterministic laboratory keys only. Never usable credentials.
set -eu
cat > "$permanent/reality-server.json" <<'EOF'
{"log":{"loglevel":"warning"},"inbounds":[{"listen":"192.0.2.2","port":18443,"protocol":"vless","settings":{"clients":[{"id":"11111111-1111-4111-8111-111111111111"}],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"show":false,"target":"203.0.113.80:18084","serverNames":["protected.example"],"privateKey":"AAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAUE","shortIds":["1234"]}}}],"outbounds":[{"protocol":"freedom","tag":"direct"}]}
EOF
wn "$xray" run -test -config "$permanent/reality-server.json" > "$permanent/reality-test.log" 2>&1
vm_process "$xray_server" /sbin/ip netns exec "$w" "$xray" run -config "$permanent/reality-server.json"
wait_pid "$xray_server" >/dev/null || fail 'Reality server did not start'
uci -c "$permanent/uci" set firewall.@zone[0].input=REJECT
# A rejecting LAN zone still needs its IPv6 neighbour-discovery control plane.
# Otherwise this fixture tests broken ND, not the marked VLESS input permit.
uci -c "$permanent/uci" set firewall.vm_nd=rule
uci -c "$permanent/uci" set firewall.vm_nd.src=lan
uci -c "$permanent/uci" set firewall.vm_nd.family=ipv6
uci -c "$permanent/uci" set firewall.vm_nd.proto=icmp
uci -c "$permanent/uci" set firewall.vm_nd.target=ACCEPT
for kind in router-solicitation router-advertisement neighbour-solicitation neighbour-advertisement; do
	uci -c "$permanent/uci" add_list "firewall.vm_nd.icmp_type=$kind"
done
uci -c "$permanent/uci" commit firewall
rn sh -c 'mount --bind "$1" /etc/config/firewall; fw4 reload' fw4 "$permanent/uci/firewall" > "$permanent/mixed-fw4.log" 2>&1
wait_ready_native
cp "$permanent/uci/podkopchik" "$permanent/awg-only-uci"
uci -c "$permanent/uci" set podkopchik.vm_vless=proxy
uci -c "$permanent/uci" set podkopchik.vm_vless.tag=vless_vm
uci -c "$permanent/uci" set 'podkopchik.vm_vless.uri=vless://11111111-1111-4111-8111-111111111111@192.0.2.2:18443?security=reality&type=tcp&sni=protected.example&pbk=pOCSkrZRwni5dyxWn1-puxPZBrRqtoyd-dwrRAn4ogk&sid=1234&fp=chrome'
uci -c "$permanent/uci" set podkopchik.@proxy_group[0].backup1=vless_vm
uci -c "$permanent/uci" set podkopchik.@proxy_group[0].backup2=awg_22222222222222222222222222222222
uci -c "$permanent/uci" commit podkopchik
ucode -e 'let p={};for(let t in ["awg_11111111111111111111111111111111","awg_22222222222222222222222222222222","vless_vm"])p[t]={status:"up",probe_status:"up",checked_at:time()};printf("%J",{proxies:p});' > "$permanent/tmp/state.json"
ctl apply > "$permanent/mixed-apply.json"
wait_ready_native
ubus call service delete '{"name":"podkopchik-native-health"}' >/dev/null
token=$(jsonfilter -q -i "$permanent/status.json" -e '@.pending')
ctl native-confirm "$token"
ucode -e 'let p={};for(let t in ["awg_11111111111111111111111111111111","awg_22222222222222222222222222222222","vless_vm"])p[t]={status:t=="vless_vm"?"up":"down",probe_status:t=="vless_vm"?"up":"down",checked_at:time()};printf("%J",{proxies:p});' > "$permanent/vless-state.json"
native_env sh "$permanent/lib/native_runtime.sh" health "$permanent/vless-state.json"
cp "$permanent/vless-state.json" "$permanent/tmp/state.json"
wait_auto vless_vm
[ -n "$(ubus call service list '{"name":"podkopchik-native-xray"}' | jsonfilter -q -e '@.*.instances.main.pid')" ]
v4=$(query_native udp probe.protected.example. A NOERROR 1 | sed -n 's/^address=//p')
[ "$(ln wget -q -T 5 -O - "http://$v4:18081/")" = isolated-http-ok ]
PKC_NATIVE_LAB=https-client ln "$bin" -test.run='^TestGuestFixture$' -- "$v4:18084" "$work/https4.der"
v6=$(query_native tcp probe.protected.example. AAAA NOERROR 1 | sed -n 's/^address=//p')
PKC_NATIVE_LAB=https-client ln "$bin" -test.run='^TestGuestFixture$' -- "[$v6]:18084" "$work/https6.der"
if PKC_NATIVE_LAB=udp ln "$bin" -test.run='^TestGuestFixture$' -- "$v4:18081" >/dev/null 2>&1; then fail 'TCP-only VLESS admitted unsupported UDP'; fi
fresh_state
native_env sh "$permanent/lib/native_runtime.sh" health "$permanent/tmp/state.json"
wait_auto awg_11111111111111111111111111111111
[ -z "$(ubus call service list '{"name":"podkopchik-native-xray"}' | jsonfilter -q -e '@.*.instances.main.pid')" ]
cp "$permanent/awg-only-uci" "$permanent/uci/podkopchik"
ctl apply > "$permanent/back-to-awg.json"
wait_ready_native
token=$(jsonfilter -q -i "$permanent/status.json" -e '@.pending')
ctl native-confirm "$token"
echo 'PASS: permanent AWG-to-real-Reality/VLESS TCP/HTTPS, TCP-only UDP denial, primary return and Xray-free AWG-only'
