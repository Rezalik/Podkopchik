#!/bin/sh
set -eu
umask 077
. /mnt/lab/native-vm-only.sh
epoch=0011223344556677
alias="pkc-ax6000-$epoch"
worker=/mnt/lab/ax6000-recovery.sh
state=/mnt/lab/trial-state.uc
bin=/mnt/lab/native-dns.test
initscript="$0"
service_triggers() { :; }
set +eu
. /lib/functions/procd.sh
set -eu
register() (
	set +eu
	name="$1"; shift
	procd_open_service "$name"
	procd_open_instance main
	procd_set_param command "$@"
	procd_set_param respawn 3600 1 0
	procd_close_instance
	procd_close_service >/dev/null
)
pid() { ubus call service list "{\"name\":\"$1\"}" | jsonfilter -q -e '@.*.instances.main.pid'; }
wait_pid() {
	for i in 1 2 3 4 5; do
		p=$(pid "$1" || true)
		if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then printf '%s\n' "$p"; return; fi
		sleep 1
	done
	echo "Missing fixture service: $1" >&2
	return 1
}
stop() { ubus call service delete "{\"name\":\"$1\"}" >/dev/null 2>&1 || true; }

scenario() (
	set -eu
	mode="$1"
	ns="pkc-ax6000-$mode-$$"
	home="$ns-home"; wan="$ns-wan"; cap=; endpoint=
	d=$(mktemp -d /tmp/pkc-ax6000.XXXXXX)
	watch="pkc-recovery-vm-$mode-$$"; legacy="pkc-legacy-vm-$mode-$$"; oldx="pkc-legacy-xray-vm-$mode-$$"
	dns="pkc-ax6000-dns-$epoch"; dhcp="pkc-ax6000-dhcp-$epoch"
	cleanup() {
		for p in $cap $endpoint; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done
		for name in "$watch" "$legacy" "$oldx" "$dns" "$dhcp"; do stop "$name"; done
		for n in "$home" "$wan" "$ns"; do ip netns del "$n" 2>/dev/null || true; done
	}
	trap cleanup EXIT
	ip netns add "$ns"
	ip netns add "$home"
	ip netns add "$wan"
	rn() { ip netns exec "$ns" "$@"; }
	client() { ip netns exec "$home" "$@"; }
	remote() { ip netns exec "$wan" "$@"; }
	runworker() { sh "$worker" --vm "$ns" "$d" "$@"; }
	current() { ucode "$state" poll "$d"; }
	legacy_dns() {
		PKC_NATIVE_LAB=query client "$bin" -test.run='^TestGuestFixture$' -- 192.168.1.1:53 tcp legacy.example. A NOERROR 1 > "$d/legacy-dns.log" 2>&1 &&
			grep -qx address=192.0.2.8 "$d/legacy-dns.log"
	}
	rn ip link set lo up
	rn ip link add br-lan type bridge
	rn ip link set br-lan address 02:00:00:00:60:00 addrgenmode none
	rn ip addr add 192.168.1.1/24 dev br-lan
	rn ip -6 addr add fdab:6000::1/64 dev br-lan nodad
	rn ip link set br-lan up
	rn ip link add home-lan type veth peer name home-peer
	rn ip link set home-lan addrgenmode none
	rn ip link set home-peer addrgenmode none
	rn ip link set home-peer netns "$home"
	rn ip link set home-lan master br-lan
	rn ip link set home-lan up
	client ip link set home-peer up
	client ip addr add 192.168.1.2/24 dev home-peer
	client ip route add default via 192.168.1.1
	rn ip link add lan4 type veth peer name test-peer
	rn ip link set lan4 addrgenmode none
	rn ip link set test-peer addrgenmode none
	rn ip link set lan4 master br-lan
	rn ip link set lan4 up
	rn ip link add uplink type veth peer name capture-wan
	rn ip link set uplink addrgenmode none
	rn ip link set capture-wan netns "$wan"
	rn ip addr add 192.0.2.1/30 dev uplink
	rn ip link set uplink up
	remote ip addr add 192.0.2.2/30 dev capture-wan
	remote ip link set capture-wan up
	remote ip route add 192.168.1.0/24 via 192.0.2.1
	rn ip route add default via 192.0.2.2
	rn sysctl -qw net.ipv4.ip_forward=1
	rn ip rule add priority 10991 fwmark 0x100000 table 10991
	rn ip route add local default dev lo table 10991
	rn ip -j rule show > "$d/prior.rules"
	rn ip -j route show table all > "$d/prior.routes"
	# These are fixture configs, not the private AX6000 backup.
	mkdir "$d/config"
	for f in network firewall dhcp wireless podkopchik; do printf 'config %s\n' "$f" > "$d/config/$f"; done
	(cd "$d/config" && sha256sum network firewall dhcp wireless podkopchik > ../config.sha256)
	printf '%s\n' '{"schema":1,"epoch":"0011223344556677","pool":"172.31.253.0/24","issued":["198.18.0.0/15"],"restore_up":true,"awg_sources":[{"device":"paw111111111111","address":"198.51.1.1"}]}' > "$d/spec.json"
	(cd "$d" && sha256sum spec.json config.sha256 > SHA256SUMS)
	register "$legacy" /sbin/ip netns exec "$ns" /usr/sbin/dnsmasq -k --conf-file=/dev/null \
		--no-resolv --no-hosts --bind-interfaces --listen-address=192.168.1.1 --address=/legacy.example/192.0.2.8
	for i in 1 2 3 4; do legacy_dns && break; sleep 1; done
	legacy_dns || { cat "$d/legacy-dns.log" >&2; exit 1; }
	legacy_pid=$(wait_pid "$legacy")
	printf '%s\n' '{"log":{"loglevel":"warning"},"inbounds":[{"listen":"127.0.0.1","port":1080,"protocol":"socks"}],"outbounds":[{"protocol":"blackhole"}]}' > "$d/legacy-xray.json"
	register "$oldx" /sbin/ip netns exec "$ns" /mnt/lab/xray run -config "$d/legacy-xray.json"
	xray_pid=$(wait_pid "$oldx")
	cat <<'NFT' | rn nft -f -
add table inet fw4
add chain inet fw4 forward { type filter hook forward priority 0; policy drop; }
add rule inet fw4 forward ct state established,related counter accept
add rule inet fw4 forward iifname "br-lan" counter accept comment "legacy-owned"
add table inet podkopchik
add table inet podkopchik_native { comment "podkopchik-native-0011223344556677"; }
add table inet podkopchik_native_gate { comment "podkopchik-native-dns-0011223344556677"; }
add chain inet podkopchik_native_gate dns_lan
add rule inet fw4 forward iifname "br-pkc-test" counter accept comment "pkc-ax6000-0011223344556677"
NFT
	rn ip link add br-pkc-test type bridge
	rn ip link set br-pkc-test alias "$alias"
	rn ip addr add 172.31.252.1/30 dev br-pkc-test
	rn ip link set br-pkc-test up
	rn ip link set lan4 nomaster
	rn ip link set lan4 master br-pkc-test
	register "$dns" /bin/sleep 180
	register "$dhcp" /bin/sleep 180
	if [ "$mode" = reboot ]; then
		cp "$PKC_VM_PERSIST/ax6000-unfinished" "$d/trial.json"
		runworker boot
		[ "$(current)" = rollback ]
		rn nft list table inet pkc_ax6000_quarantine >/dev/null
	elif [ "$mode" = owner ]; then
		(ucode "$state" arm "$d" 8; : > "$d/ready"; exec sleep 60) & owner=$!
		for i in 1 2 3 4; do [ ! -f "$d/ready" ] || break; sleep 1; done
		[ -f "$d/ready" ]; kill -KILL "$owner"; wait "$owner" 2>/dev/null || true
	else
		ucode "$state" arm "$d" 90
		: > "$d/active"
		# Force an actual health failure and a temporarily unowned restore object.
		rn nft add chain inet fw4 foreign
		rn nft 'add rule inet fw4 foreign counter comment "pkc-ax6000-0011223344556677"'
		stop "$dns"
	fi
	register "$watch" /bin/sh "$worker" --vm "$ns" "$d" watch
	if [ "$mode" = fault ]; then
		for i in 1 2 3 4 5 6 7 8; do grep -q restore_pending "$d/recovery.log" 2>/dev/null && break; sleep 1; done
		grep -q active_health_failed "$d/recovery.log"
		grep -q restore_pending "$d/recovery.log"
		[ "$(current)" = rollback ]
		rn nft list table inet pkc_ax6000_quarantine >/dev/null
		rn nft list table inet podkopchik_native >/dev/null
		wp=$(pid "$watch"); kill -KILL "$wp"
		# Delete only the fixture's injected rule/chain.
		rn nft flush chain inet fw4 foreign
		rn nft delete chain inet fw4 foreign
	fi
	for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do [ "$(current)" != restored ] || break; sleep 1; done
	[ "$(current)" = restored ]
	[ "$(rn ip -j link show lan4 | jsonfilter -e '@[0].master')" = br-lan ]
	rn ip -j link show lan4 | jsonfilter -e '@[0].flags[*]' | grep -qx UP
	if rn ip link show br-pkc-test >/dev/null 2>&1; then exit 1; fi
	rn ip -j rule show | cmp - "$d/prior.rules"
	rn ip -j route show table all > "$d/after.routes"
	cmp "$d/after.routes" "$d/prior.routes"
	rn nft list chain inet fw4 forward | grep -q legacy-owned
	if rn nft list chain inet fw4 forward | grep -q "$alias"; then exit 1; fi
	rn nft list table inet podkopchik >/dev/null
	rn nft list table inet pkc_ax6000_quarantine | grep -q '172.31.253.0/24'
	rn nft list table inet pkc_ax6000_quarantine | grep -q '198.18.0.0/15'
	if rn nft list table inet podkopchik_native >/dev/null 2>&1; then exit 1; fi
	[ "$(pid "$legacy")" = "$legacy_pid" ] || { echo 'Legacy DNS PID changed' >&2; exit 1; }
	[ "$(pid "$oldx")" = "$xray_pid" ] || { echo 'Legacy Xray PID changed' >&2; exit 1; }
	legacy_dns || { cat "$d/legacy-dns.log" >&2; exit 1; }
	(cd "$d/config" && sha256sum -c "$d/config.sha256" >/dev/null)
	# nft original-destination matching must block even after conntrack DNAT.
	rn nft add table inet pkc_recovery_fixture
	rn nft 'add chain inet pkc_recovery_fixture output { type nat hook output priority dstnat; }'
	rn nft 'add rule inet pkc_recovery_fixture output ip daddr 172.31.253.253 dnat ip to 192.0.2.2'
	PKC_NATIVE_LAB=serve ip netns exec "$wan" "$bin" -test.run='^TestGuestFixture$' -- 192.0.2.2:18081 > "$d/endpoint.log" 2>&1 & endpoint=$!
	ip netns exec "$wan" tcpdump -U -n -i capture-wan -w "$d/wan.pcap" \
		'tcp or udp' > "$d/capture.log" 2>&1 & cap=$!
	sleep 1
	for probe in rn client; do
		for proto in dial udp; do
			PKC_NATIVE_LAB="$proto" "$probe" "$bin" -test.run='^TestGuestFixture$' -- 192.0.2.2:18081
			for dst in 172.31.253.252 198.19.10.11; do
				if PKC_NATIVE_LAB="$proto" "$probe" "$bin" -test.run='^TestGuestFixture$' -- "$dst:18081" > "$d/rejected" 2>&1; then exit 1; fi
			done
		done
	done
	if PKC_NATIVE_LAB=dial rn "$bin" -test.run='^TestGuestFixture$' -- 172.31.253.253:18081 > "$d/rejected" 2>&1; then exit 1; fi
	rn nft list chain inet pkc_ax6000_quarantine output | grep -Eq 'ct original ip daddr 172\.31\.253\.0/24 counter packets [1-9]'
	kill "$cap"; wait "$cap" || true; cap=
	tcpdump -n -r "$d/wan.pcap" 2>/dev/null > "$d/wan.txt"
	! grep -Eq '172\.31\.253\.|198\.19\.10\.11' "$d/wan.txt" || exit 1
	grep -Eq 'IP 192\.168\.1\.2\.[0-9]+ > 192\.0\.2\.2\.18081' "$d/wan.txt"
	grep -Eq 'IP 192\.0\.2\.1\.[0-9]+ > 192\.0\.2\.2\.18081' "$d/wan.txt"
	wp=$(pid "$watch")
	awk '/^VmRSS:/ {printf "Recovery watchdog RSS: %s KiB\n", $2}' "/proc/$wp/status"
	printf 'PASS: AX6000 recovery %s, legacy DNS/Xray PIDs and UCI/routes/rules unchanged, both pools quarantined\n' "$mode"
	echo 'PASS: rollback WAN capture had zero synthetic packets and TCP/UDP direct controls from LAN and router'
	printf 'Recovery metadata bytes: '
	wc -c "$d/spec.json" "$d/config.sha256" "$d/SHA256SUMS" "$d/trial.json" | tail -1
)

if [ "${PKC_VM_REBOOTED:-0}" = 1 ]; then
	scenario reboot
else
	scenario owner
	scenario fault
	if [ -n "${PKC_VM_PERSIST:-}" ]; then
		d=$(mktemp -d /tmp/pkc-ax6000.XXXXXX)
		ucode "$state" arm "$d" 600
		cp "$d/trial.json" "$PKC_VM_PERSIST/ax6000-unfinished"
	fi
fi
