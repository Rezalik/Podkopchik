#!/bin/sh
set -eu
. /mnt/lab/native-vm-only.sh
umask 077
lib=/mnt/lab/native-update
work=$(mktemp -d /tmp/podkopchik-native-update.XXXXXX)
root=$(mktemp -d /tmp/pkc-component-flint.XXXXXX)
trap 'rm -rf "$work" "$root"' EXIT HUP INT TERM
mkdir "$work/ax6000" "$work/flint2"
for target in ax6000 flint2; do
	archive="$lib/candidate.tar.gz"
	[ "$target" = ax6000 ] || archive="$lib/flint2.tar.gz"
	cp "$archive" "$work/package.tar.gz"
	ucode "$lib/native_update.uc" archive "$work/package.tar.gz"
	tar -xzf "$work/package.tar.gz" -C "$work/$target"
done
flint="$work/flint2"
code="$flint/root/usr/libexec/podkopchik"
catalog="$code/native-targets.json"
cmp "$work/ax6000/COMMON_SHA256SUMS" "$flint/COMMON_SHA256SUMS"
cmp "$work/ax6000/NATIVE_DNS_SHA256" "$flint/NATIVE_DNS_SHA256"
ucode -L "$code" "$lib/native_portability_smoke.uc" "$catalog" \
	"$work/ax6000/PLATFORM.json" "$flint/PLATFORM.json" "$lib/native-platform-flint2.json"
ucode -L "$code" "$code/native_package_check.uc" verify "$catalog" "$flint"
if ucode -L "$code" "$code/native_package_check.uc" admit "$catalog" "$flint" > "$work/refused"; then exit 1; fi
echo 'PASS actual VM identity refused, no production admission override'
mkdir -p "$root/etc/config" "$root/etc/podkopchik/awg" "$root/etc/podkopchik/native-state"
printf '%s\n' preserved-uci > "$root/etc/config/podkopchik"
printf '%s\n' preserved-profile > "$root/etc/podkopchik/awg/fixture.conf"
printf '%s\n' preserved-ledger > "$root/etc/podkopchik/native-state/fixture.json"
PODKOPCHIK_INSTALL_ROOT="$root" sh "$flint/tools/install-native-rc-files.sh" "$flint"
grep -qx preserved-uci "$root/etc/config/podkopchik"
grep -qx preserved-profile "$root/etc/podkopchik/awg/fixture.conf"
grep -qx preserved-ledger "$root/etc/podkopchik/native-state/fixture.json"
cmp "$root/usr/libexec/podkopchik/podkopchik-native-dns" "$code/podkopchik-native-dns"
echo 'PASS Flint static bundle in isolated root, preserved UCI/AWG/ledger'
before=$(sha256sum /etc/config/firewall)
nft -s list ruleset > "$work/before.nft"
helper="$root/etc/podkopchik/native-bin/$(cat "$flint/NATIVE_DNS_SHA256")"
rc=0
ucode -L "$code" "$code/native_inventory_check.uc" --helper "$helper" > "$work/inventory.json" || rc=$?
[ "$rc" = 2 ]
ucode -e 'import {readfile} from "fs";let r=json(readfile(ARGV[0]));
	if(r.status!="review_required"||r.source!="live_read_only"||r.activation_authorized||r.installation_authorized||
		!r.issues.profile_inventory_unavailable) die("invalid live inventory outcome");' "$work/inventory.json"
[ "$(sha256sum /etc/config/firewall)" = "$before" ]
nft -s list ruleset > "$work/after.nft"
cmp "$work/before.nft" "$work/after.nft"
echo 'PASS real inventory collector, unchanged firewall UCI/nftables'
