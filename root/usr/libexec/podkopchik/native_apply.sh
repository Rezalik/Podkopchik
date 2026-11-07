#!/bin/sh
# Scoped Native Apply: all mutations are owned by a bounded procd trial.
set -eu
umask 077
LIB="${PODKOPCHIK_LIB:-/usr/libexec/podkopchik}"
TMP="${PODKOPCHIK_TMP_DIR:-/tmp/podkopchik}"
DNS="${PODKOPCHIK_NATIVE_DNS:-/usr/libexec/podkopchik/podkopchik-native-dns}"
work="$TMP/native-trial"
claim="${PODKOPCHIK_CONFIG_DIR:-/etc/podkopchik}/native-canary-172-31-253.claim"
ns="${PKC_NATIVE_VM_NS:-}"
if [ -n "$ns" ]; then
	. /mnt/lab/native-vm-only.sh
	case "$ns" in pkc-native-apply-*) ;; *) exit 2 ;; esac
fi
fail() { echo "native apply: $*" >&2; exit 1; }
run() { if [ -n "$ns" ]; then ip netns exec "$ns" "$@"; else "$@"; fi; }
journal() { ucode "$LIB/trial-state.uc" "$1" "$work" "${2:-}"; }
guard() { run sh "$LIB/fakedns_guard.sh" "$@"; }
field() { jsonfilter -i "$work/plan.json" -e "@.$1"; }
link_info() { run ip -d -j link show dev "$lan"; }
link_value() { printf '%s\n' "$1" | jsonfilter -q -e "@[0].$2"; }
note() { printf '%s\n' "$1" > "$work/result.new" && mv "$work/result.new" "$work/result"; }
root_owned() {
	ucode -e 'import { lstat } from "fs"; const s=lstat(ARGV[0]);
		exit(s?.type!="directory" || s.uid!=0 || (s.mode&0o077)!=0);' "$work"
}
params() {
	root_owned || return 1
	epoch=$(field epoch); lan=$(field lan)
	printf '%s\n' "$epoch" | grep -Eq '^[0-9a-f]{16}$' || return 1
	printf '%s\n' "$lan" | grep -Eq '^pkc-[a-z0-9]{1,11}$' || return 1
	pool=172.31.253.0/24
	owner="pkc-native-$epoch"
}
same_link() {
	local info
	info=$(link_info) || return 1
	[ "$(link_value "$info" ifalias)" = "$owner" ] &&
		[ "$(link_value "$info" ifindex)" = "$(cat "$work/ifindex")" ] &&
		[ "$(link_value "$info" linkinfo.info_kind)" = veth ] &&
		[ -z "$(link_value "$info" master)" ]
}
service() { ubus call service list "{\"name\":\"$1\"}"; }
start_service() {
	local name="$1" payload
	shift
	payload=$(ucode -e 'printf("%J",{name:ARGV[0],instances:{main:{command:slice(ARGV,1),respawn:[3600,1,0]}}});' -- "$name" "$@")
	ubus call service set "$payload" >/dev/null
}
running() {
	service "$1" | jsonfilter -q -e '@.*.instances.main.running' | grep -qx true
}
owned_service() {
	service "$1" | jsonfilter -q -e '@.*.instances.main.command[*]' | grep -Fxq "$2"
}
stop_service() {
	local name="$1" identity="$2" data
	data=$(service "$name") || return 1
	if printf '%s\n' "$data" | jsonfilter -q -e '@.*.instances.main.command[*]' | grep -q .; then
		owned_service "$name" "$identity" || return 1
		ubus call service delete "{\"name\":\"$name\"}" >/dev/null
	fi
}
owned_rules() {
	run nft -j -a list ruleset | ucode -e '
		import { stdin } from "fs";
		const a=json(stdin.read("all")).nftables, owner=ARGV[0], epoch=ARGV[1];
		const tables={pkc_native_edge:owner,podkopchik_native:"podkopchik-native-"+epoch,
			podkopchik_native_gate:"podkopchik-native-dns-"+epoch};
		let count=0, lines=[];
		for(let item in a) {
			let t=item.table, r=item.rule;
			if(t?.family=="inet" && tables[t.name]) {
				if(t.comment!=tables[t.name]) die("foreign native table");
				push(lines,"delete table inet "+t.name);
			}
			if(r?.comment==owner) {
				if(r.family!="inet"||r.table!="fw4"||(r.chain!="input"&&r.chain!="forward")||
					type(r.handle)!="int"||r.handle<1) die("invalid native fw4 rule");
				push(lines,"delete rule inet fw4 "+r.chain+" handle "+r.handle);
				count++;
			}
		}
		if(ARGV[2]=="count") print(count);
		else print(join("\n",lines));' -- "$owner" "$epoch" "${1:-}"
}
healthy() {
	same_link && running "$owner-dns" && owned_service "$owner-dns" "$work/dns.json" &&
		[ "$(owned_rules count)" = "$(cat "$work/fw4-count")" ] &&
		run netstat -ln | awk '$1=="tcp" && $4=="172.31.252.1:24053" {t=1}
			$1=="udp" && $4=="172.31.252.1:24053" {u=1} END {exit !(t&&u)}' &&
		run nft list chain inet podkopchik_native_gate dns_lan >/dev/null 2>&1 &&
		run nft list chain inet podkopchik_native canary_reply >/dev/null 2>&1 &&
		run nft list chain inet pkc_native_edge source >/dev/null 2>&1
}
rollback() {
	local remove
	# Silence the isolated client before removing its last fail-closed hook.
	if link_info >/dev/null 2>&1; then
		same_link && run ip link set dev "$lan" down || return 1
	fi
	remove=$(owned_rules) || return 1
	[ -z "$remove" ] || printf '%s\n' "$remove" | run nft -f - || return 1
	stop_service "$owner-dns" "$work/dns.json"
	# Issued addresses remain quarantined; never reset the allocation ledger.
}
prepare_batch() {
	ucode -L "$LIB" -e 'import { readfile, writefile } from "fs";
		const dir=ARGV[0], p=json(readfile(dir+"/plan.json")), lan=p.lan, owner=ARGV[1];
		const declared=require("universal_plan").classification(p.classification);
		if(!p.classification || p.classification.unknown!=declared.unknown ||
			p.dns.classification_mode!=declared.mode || !!p.dns.migration_restrict_unknown!=declared.migration_restrict_unknown)
			die("native classification does not match the staged DNS policy");
		if(p.mode!="preview-only" || p.requires_xray!=false || !length(p.adapters) ||
			p.automatic.active=="blocked" || length(p.dns.pools)!=1 || p.dns.pools[0]!="172.31.253.0/24" ||
			p.dns.listen!="172.31.252.1:24053" || p.dns.listen6 || p.dns.virtual ||
			!length(filter(p.adapters,a=>a.usable && a.ipv4)))
			die("unsupported native canary plan");
		for(let a in p.adapters) if(a.type!="amneziawg" || !match(a.interface,/^paw[0-9a-f]{12}$/) || type(a.mark)!="int")
			die("invalid AWG adapter");
		// Reserve .1 and .2 issued by earlier AX6000 pilots. This trial
		// may use only its own non-overlapping slice of the test pool.
		p.dns.virtual_window=[32,63];
		const i="iifname \""+lan+"\" ", table="inet pkc_native_edge", dns="ip daddr 172.31.252.1 meta l4proto { tcp, udp } th dport 24053 ct status dnat ct direction original ct original proto-dst 53 ";
		let rules=[
			"create table "+table+" { comment \""+owner+"\"; }",
			"add chain "+table+" source { type filter hook prerouting priority -307; policy accept; }",
			"add rule "+table+" source "+i+"meta nfproto != ipv4 counter drop",
			"add rule "+table+" source "+i+"ip saddr != 172.31.252.2 counter drop",
			"add chain "+table+" input { type filter hook input priority -12; policy accept; }",
			"add rule "+table+" input "+i+dns+"return",
			"add rule "+table+" input "+i+"counter drop",
			p.nft.routing,p.nft.protection,p.nft.dns_redirect,p.nft.canary,p.nft.canary_reply
		];
		const comment=" comment \""+owner+"\"";
		push(rules,"insert rule inet fw4 input "+i+dns+"counter accept"+comment);
		for(let a in p.adapters) push(rules,"insert rule inet fw4 forward "+i+"meta mark "+a.mark+
			" oifname \""+a.interface+"\" ct state { new, established, related } counter accept"+comment);
		if(!writefile(dir+"/fw4-count",(length(p.adapters)+1)+"\n") ||
			!writefile(dir+"/apply.nft",join("\n",rules)+"\n") ||
			!writefile(dir+"/dns.json",sprintf("%J\n",p.dns))) die("cannot stage native transaction");' -- "$work" "$owner"
}
activate() {
	local s
	same_link || return 1
	run nft -c -f "$work/apply.nft" || return 1
	s=$(guard status) || return 1
	if ! printf '%s\n' "$s" | grep -qx 'state=active' ||
		! printf '%s\n' "$s" | sed -n 's/^native_pools=/ /p' | grep -Eq ' 172\.31\.253\.0/24( |$)'; then
		guard register-native "$pool" || return 1
	fi
	# Registration is not issuance. Burn this one-time address window before
	# the classifier can answer, including after a reboot or interrupted Apply.
	ucode -e 'import { open } from "fs"; const f=open(ARGV[0],"wx",0o600), s=ARGV[1]+"\n";
		if(!f || f.write(s)!=length(s) || !f.flush() || !f.close() || system(["sync"])!=0) exit(1);' \
		-- "$claim" "$epoch" || return 1
	run nft -f "$work/apply.nft" && run ip link set dev "$lan" up || return 1
	set -- "$DNS" -config "$work/dns.json" -ledger "$work/ledger"
	if [ -n "$ns" ]; then set -- /sbin/ip netns exec "$ns" "$@"; fi
	start_service "$owner-dns" "$@"
}

[ "$(id -u)" = 0 ] || fail 'root is required'
case "${1:-}" in
	start)
		[ "$#" = 2 ] && [ -s "$2" ] && [ -x "$DNS" ] || fail 'inventory and native DNS binary required'
		[ ! -e "$claim" ] && [ ! -L "$claim" ] || fail 'the canary address window has already been claimed'
		if [ -z "$ns" ]; then
			[ -z "${PODKOPCHIK_CONFIG_DIR:-}" ] && [ -x /etc/rc.d/S18podkopchik-fakedns ] &&
				[ -x /etc/rc.d/S95podkopchik ] &&
				[ -f /etc/hotplug.d/iface/95-podkopchik-fakedns ] &&
				cmp -s "$LIB/fakedns_guard.uc" /usr/libexec/podkopchik/fakedns_guard.uc ||
				fail 'the matching Core FakeDNS guard must be installed and enabled for boot'
			status=$(guard status) || fail 'cannot inspect the active Core FakeDNS guard'
			printf '%s\n' "$status" | grep -qx 'state=active' || fail 'the Core FakeDNS guard must already be active'
		fi
		mkdir -p "$TMP"
		mkdir -m 700 "$work" || fail 'a native trial exists; inspect or clear it first'
		armed=0
		trap '[ "$armed" = 1 ] || rm -rf "$work"' EXIT
		if [ -n "$ns" ]; then
			cp "$2" "$work/plan.json"
		else
			run ucode -L "$LIB" "$LIB/generate.uc" native-preview "$2" > "$work/plan.json"
		fi
		params || fail 'invalid native scope'
		info=$(link_info) || fail 'isolated veth must be provisioned separately'
		link_value "$info" ifindex > "$work/ifindex"
		same_link || fail 'test veth ownership does not match this trial'
		if link_value "$info" 'flags[*]' | grep -qx UP; then fail 'test veth must be down'; fi
		run ip -4 -j addr show dev "$lan" | ucode -e 'import { stdin } from "fs"; const a=json(stdin.read("all"))[0]?.addr_info;
			exit(length(a)!=1 || a[0].local!="172.31.252.1" || a[0].prefixlen!=30);' ||
			fail 'test veth must have the dedicated /30 address'
		previous=$(owned_rules) || fail 'native ownership preflight failed'
		[ -z "$previous" ] || fail 'native resources are already present'
		prepare_batch
		run nft -c -f "$work/apply.nft"
		run "$DNS" -config "$work/dns.json" -ledger "$work/ledger" -init-ledger
		limit=120
		[ -z "$ns" ] || limit=25
		journal arm "$limit"
		# Do not discard the journal if SSH dies while procd accepts the request.
		armed=1
		start_service "$owner-watch" /usr/bin/env "PODKOPCHIK_LIB=$LIB" "PODKOPCHIK_TMP_DIR=$TMP" \
			"PODKOPCHIK_CONFIG_DIR=${PODKOPCHIK_CONFIG_DIR:-}" "PODKOPCHIK_NATIVE_DNS=$DNS" "PKC_NATIVE_VM_NS=$ns" \
			/bin/sh "$LIB/native_apply.sh" watch
		printf 'Native trial armed for %ss. No household LAN changes.\n' "$limit"
		;;
	watch)
		params
		while :; do
			current=$(journal poll) || current=invalid
			case "$current" in
				waiting)
					if [ ! -e "$work/begun" ]; then
						touch "$work/begun"
						if activate > "$work/activate.log" 2>&1; then
							for i in 1 2 3 4 5; do healthy && break; sleep 1; done
							if healthy; then note active; else journal abort || :; fi
						else journal abort || :; fi
					elif ! healthy; then journal abort || :; fi
					sleep 1 ;;
				rollback|invalid)
					if rollback > "$work/rollback.log" 2>&1; then
						[ "$current" = invalid ] || journal restored
						note restored
						stop_service "$owner-watch" "$LIB/native_apply.sh"
						exit
					fi
					note rollback_pending
					sleep 2 ;;
				restored) note restored; stop_service "$owner-watch" "$LIB/native_apply.sh"; exit ;;
				*) fail 'permanent promotion is not supported by the scoped trial' ;;
			esac
		done ;;
	status) if [ -r "$work/result" ]; then cat "$work/result"; else echo inactive; fi ;;
	verify) params; healthy; journal verify; echo 'Trial verified; deadline and automatic rollback remain armed.' ;;
	abort) params; journal abort ;;
	clear)
		params
		[ "$(journal poll)" = restored ] && ! running "$owner-watch" && ! running "$owner-dns" ||
			fail 'only a restored trial can be cleared'
		rm -rf "$work" ;;
	*) fail 'usage: native-apply start INVENTORY.json|status|verify|abort|clear' ;;
esac
