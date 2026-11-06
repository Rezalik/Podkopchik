#!/bin/sh
set -eu
umask 077
. /mnt/lab/native-vm-only.sh
worker=/mnt/lab/ax6000-virtual-watch.sh
journal=/mnt/lab/trial-state.uc
register() {
	local payload
	payload=$(ucode -e 'print(sprintf("%J", { name: ARGV[0], instances: { main: { command: slice(ARGV, 1) } } }));' -- "$@")
	ubus call service set "$payload" >/dev/null
}
service() { ubus call service list "{\"name\":\"$1\"}"; }
absent() { [ "$(service "$1" | tr -d ' \t\r\n')" = '{}' ]; }
pid() { service "$1" | jsonfilter -q -e '@.*.instances.main.pid'; }
stop() { ubus call service delete "{\"name\":\"$1\"}" >/dev/null 2>&1 || true; }
await() {
	for i in $(seq 1 22); do "$@" && return 0; sleep 1; done
	echo "Timed out: $*" >&2; return 1
}

scenario() (
	epoch="$1"; mode="$2"
	alias="pkc-virtual-$epoch"
	outer="pkc-vm-host-$$"
	root="/tmp/pkc-vpilot.$epoch"
	ns="pkcv-$epoch"; port="pv$(printf %.12s "$epoch")"
	watch="$alias-watch"; dns="$alias-dns"; client="$alias-client"
	legacy="pkc-vm-legacy-$$"; owner=
	cleanup() {
		if [ -n "$owner" ]; then kill "$owner" 2>/dev/null || true; wait "$owner" 2>/dev/null || true; fi
		for s in "$watch" "$client" "$dns" "$legacy"; do stop "$s"; done
		for n in "$ns" "$outer"; do ip netns del "$n" 2>/dev/null || true; done
		if [ -f "$root/recovery.status" ]; then cat "$root/recovery.status"; fi
	}
	trap cleanup EXIT
	mkdir -m 700 "$root"
	ip netns add "$outer"
	ip netns add "$ns"
	ip netns exec "$ns" readlink /proc/self/ns/net > "$root/namespace.id"
	rn() { ip netns exec "$outer" "$@"; }
	run_watch() { sh "$worker" --vm "$outer" "$@" "$root"; }
	registered() { pid "$1" >/dev/null; }
	state_is() { [ "$(ucode "$journal" poll "$root")" = "$1" ]; }
	status_has() { grep -q "$1" "$root/recovery.status" 2>/dev/null; }
	respawned() { new=$(pid "$watch") && [ "$new" != "$original" ]; }

	rn ip link set lo up
	rn ip link add br-lan type bridge
	rn ip link set br-lan addrgenmode none
	rn ip addr add 192.168.1.1/24 dev br-lan
	rn ip link set br-lan up
	rn ip link add paw111111111111 type bridge
	rn ip link set paw111111111111 addrgenmode none
	rn ip link set paw111111111111 up
	rn nft add table inet fw4
	rn nft 'add chain inet fw4 input { type filter hook input priority filter; policy accept; }'
	rn nft 'add chain inet fw4 forward { type filter hook forward priority filter; policy drop; }'
	rn nft 'add rule inet fw4 forward iifname "br-lan" counter accept comment "household"'
	rn nft 'add table inet podkopchik { comment "existing"; }'
	rn nft -s list ruleset > "$root/base.nft"
	rn ip -j route show table all > "$root/base.route"
	rn ip -j rule show > "$root/base.rule"
	register "$legacy" /bin/sleep 180
	await registered "$legacy"; legacy_pid=$(pid "$legacy")
	printf '%s\n' 'exec sleep 180' > "$root/probe.sh"
	rn ip link add "$port" type veth peer name client0
	rn ip link set dev "$port" alias "$alias"
	rn ip link set dev "$port" addrgenmode none
	rn ip link set dev client0 netns "$ns"
	ip -n "$ns" link set dev client0 addrgenmode none
	register "$client" /sbin/ip netns exec "$ns" /bin/sh "$root/probe.sh" "$root"
	register "$dns" /sbin/ip netns exec "$outer" /bin/sh "$root/probe.sh" "$root"
	await registered "$client"
	await registered "$dns"
	if [ "$mode" = timeout ]; then limit=13; else limit=90; fi
	# Simulate loss of the process that started the trial, not the procd service.
	(ucode "$journal" arm "$root" "$limit"; : > "$root/owner-ready"; exec sleep 120) & owner=$!
	await test -f "$root/owner-ready"
	run_watch start
	await registered "$watch"
	kill -KILL "$owner"; wait "$owner" 2>/dev/null || true; owner=
	rn nft add table inet podkopchik_native "{ comment \"podkopchik-native-$epoch\"; }"
	rn nft add table inet podkopchik_native_gate "{ comment \"podkopchik-native-dns-$epoch\"; }"
	rn nft add table inet pkc_virtual_guard "{ comment \"$alias\"; }"
	rn nft add rule inet fw4 input iifname "$port" ip saddr 172.31.252.2 udp dport 53 accept comment "\"$alias\""
	rn nft add rule inet fw4 forward oifname "$port" ip daddr 172.31.252.2 ct state established accept comment "\"$alias\""
	rn ip addr add 172.31.252.1/30 dev "$port"
	rn ip link set dev "$port" up
	ip -n "$ns" link set dev client0 up
	printf '{"owner":"%s","port":"%s","mark":"0x504b0901","route_table":48181,"priority":11581,"device":"paw111111111111"}\n' "$alias" "$port" > "$root/route.json"
	rn ip -4 route add unreachable default metric 42760 proto 242 table 48181
	rn ip -4 route add default dev paw111111111111 metric 100 proto 242 table 48181
	rn ip -4 rule add priority 11581 from 172.31.252.2 iif "$port" fwmark 0x504b0901 table 48181 protocol 242
	if [ "$mode" = fault ]; then
		# Correct epoch but not scoped to the virtual port: never delete it.
		rn nft add rule inet fw4 forward iifname '"br-lan"' counter accept comment "\"$alias\""
		ucode "$journal" abort "$root"
		await status_has restore_pending
		rn ip -j link show dev "$port" | jsonfilter -e '@[0].flags[*]' | awk '$0=="UP"{bad=1} END{exit bad}'
		rn nft list chain inet fw4 forward | grep -Fq "comment \"$alias\""
		rn nft list table inet pkc_virtual_guard >/dev/null
		original=$(pid "$watch"); kill -KILL "$original"
		await respawned
		h=$(rn nft -a list chain inet fw4 forward | awk -v e="$alias" '/iifname "br-lan"/ && index($0,e) {print $NF}')
		[ -n "$h" ]; rn nft delete rule inet fw4 forward handle "$h"
	fi
	await state_is restored
	await absent "$watch"
	status_has cleaned:rollback
	! rn ip link show dev "$port" >/dev/null 2>&1
	[ ! -e "/var/run/netns/$ns" ]
	absent "$client" && absent "$dns"
	[ "$(pid "$legacy")" = "$legacy_pid" ]
	rn nft -s list ruleset | cmp - "$root/base.nft"
	rn ip -j route show table all | cmp - "$root/base.route"
	rn ip -j rule show | cmp - "$root/base.rule"
	echo "PASS: virtual $mode, owned state removed, household rules/routes and PID unchanged, watchdog exited"
)

scenario "$(printf '33%014x' "$$")" timeout
scenario "$(printf '55%014x' "$$")" fault
