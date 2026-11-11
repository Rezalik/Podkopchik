#!/bin/sh
# Sourced by the permanent matrix after the NIC-free guest check.
uci_legacy() { uci -c "$permanent/uci" "$@"; }
same_legacy() {
	cmp "$permanent/legacy-uci" "$permanent/uci/podkopchik"
	rn nft -s list ruleset > "$permanent/current.nft"
	cmp "$permanent/legacy.nft" "$permanent/current.nft"
	for family in 4 6; do
		rn ip "-$family" rule show > "$permanent/current-rules$family"
		cmp "$permanent/legacy-rules$family" "$permanent/current-rules$family"
	done
	[ ! -e "$permanent/config/native-state/runtime.json" ]
	[ ! -e "$permanent/config/native-state/namespaces.json" ]
}
uci_legacy set podkopchik.main.routing_engine=legacy
uci_legacy set podkopchik.main.native_confirm_seconds=59
uci_legacy commit podkopchik
rn nft add table inet podkopchik
rn nft add table inet migration_keep
printf '%s\n' podkopchik-routing-v1 > "$permanent/tmp/routing.env"
printf '%s\n' podkopchik-routing6-v1 > "$permanent/tmp/routing6.env"
for family in 4 6; do
	rn ip "-$family" rule add fwmark 0x100000 table 10991 priority 10991
	rn ip "-$family" route add local default dev lo table 10991
	rn ip "-$family" rule add fwmark 0x123456 table main priority 11050
	rn ip "-$family" rule show > "$permanent/legacy-rules$family"
done
rn nft -s list ruleset > "$permanent/legacy.nft"
cp "$permanent/uci/podkopchik" "$permanent/legacy-uci"
ctl native-migration-readiness > "$permanent/migration-readiness.json"
[ "$(jsonfilter -i "$permanent/migration-readiness.json" -e '@.ready')" = false ]
[ ! -d "$permanent/config/native-state" ]
mkdir "$permanent/tmp/config-apply.lock"
if ctl native-migrate > "$permanent/migration-error" 2>&1; then fail 'concurrent Legacy Apply accepted'; fi
grep -q 'another config apply is in progress' "$permanent/migration-error"
rmdir "$permanent/tmp/config-apply.lock"
if ctl native-migrate > "$permanent/migration-error" 2>&1; then fail 'invalid migration deadline accepted'; fi
grep -q 'invalid confirmation deadline' "$permanent/migration-error"
same_legacy
uci_legacy set podkopchik.main.native_confirm_seconds=300
rn "$daemon" -probe 127.0.0.1:1059
uci_legacy set podkopchik.main.native_dns_port=1059
uci_legacy commit podkopchik
cp "$permanent/uci/podkopchik" "$permanent/legacy-uci"
if ctl native-migrate > "$permanent/migration-error" 2>&1; then fail 'occupied DNS port accepted'; fi
grep -q 'Native listener port is already in use: 1059' "$permanent/migration-error" || {
	cat "$permanent/migration-error"; fail 'expected occupied port refusal';
}
same_legacy
uci_legacy set podkopchik.main.native_dns_port=24253
uci_legacy commit podkopchik
cp "$permanent/uci/podkopchik" "$permanent/legacy-uci"
ctl native-migrate-check > "$permanent/migration-check.json"
[ "$(jsonfilter -i "$permanent/migration-check.json" -e '@.valid')" = true ]
same_legacy
ctl native-migrate > "$permanent/apply.json"
[ "$(uci_legacy get podkopchik.main.routing_engine)" = native ]
[ "$(jsonfilter -i "$permanent/apply.json" -e '@.confirmation_required')" = true ]
if ctl native-migrate > "$permanent/migration-error" 2>&1; then fail 'repeated first migration accepted'; fi
echo 'PASS: live identity refused on VM; Legacy Apply lock, invalid deadline and occupied port left Legacy untouched; validated trial armed'
