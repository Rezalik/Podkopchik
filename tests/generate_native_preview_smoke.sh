#!/bin/sh
set -eu
if ! command -v ucode >/dev/null 2>&1 ||
	! ucode -L "${UCODE_MODULE_DIR:-/usr/lib/ucode}" -e 'import { cursor } from "uci";' >/dev/null 2>&1; then
	echo 'SKIP: native preview requires OpenWrt ucode UCI'
	exit 0
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
umask 077
cat > "$tmp/podkopchik" <<'EOF'
config settings 'main'
	option routing_enabled '1'
	option native_direct_grants_confirmed '1'
	option lan_ifname 'br-lan'
	option fakedns_enabled '1'
config proxy
	option tag 'awg_11111111111111111111111111111111'
	option protocol 'amneziawg'
	option awg_id '11111111111111111111111111111111'
config proxy 'backup'
	option tag 'backup'
	option uri 'vless://11111111-2222-3333-4444-555555555555@example.invalid:443?type=tcp&security=reality&sni=example.invalid&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=abcd'
config proxy 'unused'
	option tag 'unused'
	option uri 'vless://11111111-2222-3333-4444-555555555555@example.invalid:443?type=tcp&security=reality&sni=example.invalid&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=abcd'
config proxy_group
	option tag 'auto_proxy_group'
	option primary 'awg_11111111111111111111111111111111'
	option backup1 'backup'
config domain_rule
	list domain 'first.example'
	list domain 'second.example'
	option target 'auto_proxy_group'
config domain_rule
	option domain 'legacy.example, SECOND.EXAMPLE'
	option target 'auto_proxy_group'
config ip_rule
	option cidr '203.0.113.0/24'
	option target 'auto_proxy_group'
config lan_device
	option source_ip '172.31.252.2'
	option mode 'direct'
config bypass_rule
	option host 'access.example'
EOF
cat > "$tmp/spec.json" <<'EOF'
{"lan":"pkc-test","legacy_lans":["br-lan"],"upstream":"127.0.0.1:1059",
 "synthetic":{"epoch":"0011223344556677","pools":["172.31.253.0/24"],"private_pool":"172.31.253.0/24",
 "dns":{"ipv4":"172.31.252.1","port":24053},
 "inventory":{"addresses":[{"addr_info":[{"local":"172.31.252.1","prefixlen":30}]}],
 "routes":[{"dst":"default"}],"issued":["198.18.0.0/15"]}}}
EOF
ucode -e 'printf("%J",{proxies:{backup:{status:"up",probe_status:"up",checked_at:time()}}});' > "$tmp/state.json"
preview() {
	UCI_CONFIG_DIR="$tmp" ucode -L "${UCODE_MODULE_DIR:-/usr/lib/ucode}" \
		root/usr/libexec/podkopchik/generate.uc native-preview "$1" "$2"
}
preview "$tmp/spec.json" "$tmp/state.json" > "$tmp/out"
ucode -e 'import { readfile } from "fs";
	let p=json(readfile(ARGV[0]));
	if(p.mode!="preview-only" || p.automatic.active!="backup" || !p.requires_xray || !p.xray_needed_now ||
		length(p.adapters)!=2 ||
		p.rules.domains!=4 || p.rules.ips!=1 || p.rules.clients!=1 ||
		p.dns.listen!="172.31.252.1:24053" || p.dns.groups[1].names[2]!="legacy.example" ||
		p.classification.mode!="strict" || p.classification.unknown!="protected" ||
		index(p.warnings,"synthetic_addresses_for_direct_clients_are_blocked")<0 ||
		index(p.warnings,"domain_direct_requires_explicit_address_or_client_grant")<0) die(sprintf("unexpected native preview: %J\n", {
			automatic:p.automatic, mode:p.mode, rules:p.rules, dns:p.dns, xray:p.requires_xray, warnings:p.warnings}));' "$tmp/out"
! grep -q '11111111-2222-3333-4444-555555555555' "$tmp/out"
sed "s/native_direct_grants_confirmed '1'/native_direct_grants_confirmed '0'/" "$tmp/podkopchik" > "$tmp/pending"
cp "$tmp/podkopchik" "$tmp/confirmed"
cp "$tmp/pending" "$tmp/podkopchik"
if preview "$tmp/spec.json" "$tmp/state.json" > "$tmp/rejected" 2>&1; then exit 1; fi
grep -q 'require explicit confirmation' "$tmp/rejected"
UCI_CONFIG_DIR="$tmp" ucode -L "${UCODE_MODULE_DIR:-/usr/lib/ucode}" \
	root/usr/libexec/podkopchik/generate.uc native-direct-grants "$tmp/spec.json" "$tmp/state.json" > "$tmp/review"
ucode -e 'import {readfile} from "fs"; const p=json(readfile(ARGV[0]));
	if(p.mode!="direct-grant-review-only" || p.classification.direct_grants_confirmed || p.nft || p.dns ||
		length(p.direct_grants)!=1 || p.direct_grants[0].kind!="client" || p.direct_grants[0].scope!="entire_client") die("unsafe grant review");' "$tmp/review"
cp "$tmp/confirmed" "$tmp/podkopchik"
if command -v uci >/dev/null 2>&1; then
	cp "$tmp/podkopchik" "$tmp/with-rules"
	for kind in domain_rule ip_rule lan_device bypass_rule; do
		while uci -c "$tmp" -q delete "podkopchik.@$kind[0]"; do :; done
	done
	uci -c "$tmp" commit podkopchik
	preview "$tmp/spec.json" "$tmp/state.json" > "$tmp/unknown-only"
	ucode -e 'import {readfile} from "fs";const p=json(readfile(ARGV[0]));
		if(p.rules.domains || p.rules.ips || p.rules.clients || !p.xray_needed_now ||
			p.unknown_fallback["4"].tcp!="backup" || p.unknown_fallback["4"].udp!="blocked")
			die("unknown-only native policy lost the automatic group or protocol guard");' "$tmp/unknown-only"
	cp "$tmp/with-rules" "$tmp/podkopchik"
fi
if command -v nft >/dev/null 2>&1 && [ "$(id -u)" = 0 ]; then
	ucode -e 'import { readfile } from "fs"; let n=json(readfile(ARGV[0])).nft;
		print(n.quarantine,n.routing,n.protection,n.dns_redirect);' "$tmp/out" > "$tmp/plan.nft"
	nft -c -f "$tmp/plan.nft"
fi
printf '{}\n' > "$tmp/state.json"
preview "$tmp/spec.json" "$tmp/state.json" | grep -q '"no_healthy_transport"'
sed 's/"pkc-test"/"br-lan"/' "$tmp/spec.json" > "$tmp/conflict.json"
if preview "$tmp/conflict.json" "$tmp/state.json" >/dev/null 2>&1; then exit 1; fi
if command -v uci >/dev/null 2>&1; then
	uci -c "$tmp" delete podkopchik.backup
	uci -c "$tmp" commit podkopchik
	preview "$tmp/spec.json" "$tmp/state.json" | grep -q '"requires_xray": false'
fi
printf '\nconfig domain_rule\n option domain "sub.first.example"\n option target "direct"\n' >> "$tmp/podkopchik"
if preview "$tmp/spec.json" "$tmp/state.json" >/dev/null 2>&1; then exit 1; fi
echo 'Native UCI preview PASS: redaction, real rule mapping, fresh fallback, all-down and conflict gates'
