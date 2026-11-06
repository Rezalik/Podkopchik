#!/bin/sh
set -eu
umask 077
. /mnt/lab/native-vm-only.sh
lib=/mnt/lab/source
lab=$(mktemp -d /tmp/pkc-native-apply-test.XXXXXX)
bin=/mnt/lab/native-dns.test
bootstate=/etc/pkc-native-apply-boot
case "${1:-}" in
	'') set -- timeout fault ;;
	reboot|post-reboot)
		grep -q ' / ext4 ' /proc/mounts || { echo 'Persistent VM disk required' >&2; exit 1; }
		if [ "$1" = post-reboot ]; then
			[ "$(cat /proc/sys/kernel/random/boot_id)" != "$(cat "$bootstate/first-boot")" ]
			for i in $(seq 1 20); do
				nslookup localhost 127.0.0.1 >/dev/null 2>&1 && break
				sleep 1
			done
			[ ! -e "$(cat "$bootstate/trial-dir")" ]
			[ -s /etc/podkopchik/native-canary-172-31-253.claim ]
			for name in pkc_native_edge podkopchik_native podkopchik_native_gate; do
				if nft list table inet "$name" >/dev/null 2>&1; then exit 1; fi
			done
			for pool in 198.18.0.0/15 172.31.253.0/24; do ip -4 rule show | grep -Fq "to $pool blackhole"; done
			sh /usr/libexec/podkopchik/fakedns_guard.sh status | grep -qx state=active
			sha256sum -c "$bootstate/config.sha256"
			nslookup localhost 127.0.0.1 >/dev/null
			echo 'PASS: actual reboot, Core guard restored both pools, scoped rules absent and DNS available'
			exit 0
		fi
		[ ! -e "$bootstate" ] && [ ! -e /etc/init.d/podkopchik-fakedns ] && [ ! -e /etc/podkopchik-fakedns-guard.json ]
		;;
	*) exit 2 ;;
esac
for scenario do (
	work="$lab/$scenario"
	r="pkc-native-apply-$$-$scenario"; c="pkc-client-$$-$scenario"; w="pkc-peer-$$-$scenario"
	pids=
	cleanup() {
		for p in $pids; do kill "$p" 2>/dev/null || :; wait "$p" 2>/dev/null || :; done
		[ -z "${owner:-}" ] || for s in watch dns; do ubus call service delete "{\"name\":\"$owner-$s\"}" >/dev/null 2>&1 || :; done
		for n in "$r" "$c" "$w"; do ip netns del "$n" 2>/dev/null || :; done
	}
	trap cleanup EXIT
	mkdir -p "$work/conf" "$work/run"
	for n in "$r" "$c" "$w"; do ip netns add "$n"; ip -n "$n" link set lo up; done
	rn() { ip netns exec "$r" "$@"; }
	cn() { ip netns exec "$c" "$@"; }
	epoch=$(tr -d '-' </proc/sys/kernel/random/uuid | cut -c1-16)
	owner=pkc-native-$epoch
	awg=paw111111111111
	ip -n "$r" link add pkc-test type veth peer name client0 netns "$c"
	ip -n "$r" link set pkc-test alias "$owner"
	ip -n "$r" addr add 172.31.252.1/30 dev pkc-test
	ip -n "$c" addr add 172.31.252.2/30 dev client0
	ip -n "$c" link set client0 up
	ip -n "$c" route add default via 172.31.252.1
	ip -n "$r" link add "$awg" type veth peer name peer0 netns "$w"
	ip -n "$r" addr add 198.51.1.1/30 dev "$awg"
	ip -n "$w" addr add 198.51.1.2/30 dev peer0
	ip -n "$w" addr add 203.0.113.80/32 dev lo
	ip -n "$r" link set "$awg" up
	ip -n "$w" link set peer0 up
	rn sysctl -w net.ipv4.ip_forward=1 >/dev/null
	set -- $(ucode -L "$lib" -e 'const a=require("awg_network").resources("11111111111111111111111111111111"); printf("%d %d %d",a.mark,a.table,a.priority);')
	rn ip rule add fwmark "$1" table "$2" priority "$3"
	rn ip route add default via 198.51.1.2 dev "$awg" table "$2"
	rn nft -f - <<'EOF'
add table inet fw4
add chain inet fw4 input { type filter hook input priority filter; policy drop; }
add rule inet fw4 input iifname "lo" accept
add chain inet fw4 forward { type filter hook forward priority filter; policy drop; }
add rule inet fw4 forward ct state established,related accept
add table inet podkopchik
add chain inet podkopchik legacy
EOF
	legacy=$(rn nft -s list table inet podkopchik)
	fw4=$(rn nft -s list table inet fw4)
	printf '%s\n' '{"fakedns":{"ipPool":"198.18.0.0/15"}}' > "$work/conf/config.json"
	ucode -L "$lib" -e '
		const c=require("universal_plan"), id="11111111111111111111111111111111", tag="awg_"+id;
		const p=c.compile({lan:"pkc-test",legacy_lans:["br-lan"],
			adapters:[{id,type:"amneziawg",usable:true,ipv4:true,source_ips:["198.51.1.1"]}],automatic:tag,
			fake_pools:["198.18.0.0/15"],bypass:[],clients:[],ips:[],
			domains:[{names:["protected.example"],target:"auto_proxy_group"}],
			synthetic:{epoch:ARGV[0],pools:["172.31.253.0/24"],private_pool:"172.31.253.0/24",
			dns:{ipv4:"172.31.252.1",port:24053},
			inventory:{issued:["198.18.0.0/15"],addresses:[{addr_info:[{local:"172.31.252.1",prefixlen:30}]}],routes:[{dst:"default"}]}}});
		print(sprintf("%J",{mode:"preview-only",lan:p.lan,epoch:ARGV[0],requires_xray:false,automatic:{active:tag},adapters:values(p.adapters),
			dns:c.dns_policy(p,"","127.0.0.1:1059",[]),nft:{routing:c.batch(p),protection:c.dns_gate(p,true),
			dns_redirect:c.dns_edge(p),canary:c.canary_guard(p),canary_reply:c.canary_reply_guard(p)}}));' "$epoch" > "$work/plan.json"
	PKC_NATIVE_LAB=dns ip netns exec "$r" "$bin" -test.run='^TestGuestFixture$' -- 127.0.0.1:1059 udp > "$work/dns.log" 2>&1 & pids="$pids $!"
	PKC_NATIVE_LAB=serve ip netns exec "$w" "$bin" -test.run='^TestGuestFixture$' -- 203.0.113.80:18081 > "$work/origin.log" 2>&1 & pids="$pids $!"
	export PKC_NATIVE_VM_NS="$r" PODKOPCHIK_NATIVE_DNS=/mnt/lab/podkopchik-native-dns
	export PODKOPCHIK_LIB="$lib" PODKOPCHIK_CONFIG_DIR="$work/conf" PODKOPCHIK_TMP_DIR="$work/run"
	act() { sh "$lib/native_apply.sh" "$@"; }
	await() {
		for i in $(seq 1 32); do [ "$(act status)" != "$1" ] || return 0; sleep 1; done
		cat "$work/run/native-trial/"*.log >&2
		return 1
	}
	if [ "$scenario" = fault ]; then rn sh "$lib/fakedns_guard.sh" register-native 172.31.253.0/24; fi
	act start "$work/plan.json"
	if act start "$work/plan.json" >/dev/null 2>&1; then exit 1; fi
	await active
	# The disposable guest has Ethernet stand-ins, not the AWG kernel module.
	rn nft insert rule inet podkopchik_fake_guard native_original oifname "$awg" meta oifkind '"veth"' return
	fake=$(cn /mnt/lab/pilot-probe lookup 172.31.252.1:53 udp protected.example)
	[ "$(cn /mnt/lab/pilot-probe lookup 172.31.252.1:53 tcp protected.example)" = "$fake" ]
	[ "$fake" = 172.31.253.32 ]
	cn wget -T 3 -qO- "http://$fake:18081/" | grep -qx isolated-http-ok
	if cn wget -T 1 -qO- 'http://203.0.113.80:18081/' >/dev/null 2>&1; then exit 1; fi
	if cn wget -T 1 -qO- 'http://172.31.253.100:18081/' >/dev/null 2>&1; then exit 1; fi
	act verify
	case "$scenario" in
	reboot)
		mkdir -m 700 "$bootstate" /etc/podkopchik
		mkdir -p /usr/libexec/podkopchik
		cp "$lib"/*.uc "$lib/fakedns_guard.sh" "$lib/routing_safety.sh" "$lib/cleanup_rules.sh" /usr/libexec/podkopchik/
		cp /mnt/lab/podkopchik-fakedns /etc/init.d/podkopchik-fakedns
		cp /mnt/lab/podkopchik-fakedns-hotplug.sh /etc/hotplug.d/iface/95-podkopchik-fakedns
		cp /mnt/lab/regression/root/etc/init.d/podkopchik /etc/init.d/podkopchik
		chmod 755 /etc/init.d/podkopchik-fakedns /etc/init.d/podkopchik /usr/libexec/podkopchik/cleanup_rules.sh
		# Use the real late Core startup, but leave legacy interception off.
		printf "config main 'main'\n\toption enabled '0'\n\toption routing_enabled '0'\n" > /etc/config/podkopchik
		cp "$work/conf/config.json" /etc/podkopchik/config.json
		cp "$work/conf/native-canary-172-31-253.claim" /etc/podkopchik/
		cp "$work/conf/fakedns-guard.json" /etc/podkopchik-fakedns-guard.json
		chmod 600 /etc/podkopchik-fakedns-guard.json
		/etc/init.d/podkopchik-fakedns enable
		/etc/init.d/podkopchik enable
		sha256sum /etc/config/dhcp /etc/config/firewall /etc/config/network /etc/config/podkopchik > "$bootstate/config.sha256"
		cat /proc/sys/kernel/random/boot_id > "$bootstate/first-boot"
		printf '%s\n' "$work/run/native-trial" > "$bootstate/trial-dir"
		[ "$(act status)" = active ]
		sync
		reboot
		sleep 45
		exit 1 ;;
	fault)
		rn nft flush chain inet fw4 input
		rn nft add rule inet fw4 input iifname lo accept ;;
	timeout)
		pid=$(ubus call service list "{\"name\":\"$owner-watch\"}" | jsonfilter -e '@.*.instances.main.pid')
		kill -KILL "$pid" ;;
	esac
	await restored
	[ "$(rn nft -s list table inet fw4)" = "$fw4" ]
	[ "$(rn nft -s list table inet podkopchik)" = "$legacy" ]
	if rn ip -j link show dev pkc-test | jsonfilter -e '@[0].flags[*]' | grep -qx UP; then exit 1; fi
	for name in pkc_native_edge podkopchik_native podkopchik_native_gate; do
		if rn nft list table inet "$name" >/dev/null 2>&1; then exit 1; fi
	done
	rn ip -4 rule show | grep -Fq 'to 172.31.253.0/24 blackhole'
	[ -s "$work/conf/fakedns-guard.json" ]
	act clear
	if act start "$work/plan.json" > "$work/rejected.log" 2>&1; then exit 1; fi
	grep -Fq 'address window has already been claimed' "$work/rejected.log"
	echo "PASS: scoped Native Apply/$scenario, legacy nft untouched, owned cleanup and quarantine retained"
); done
