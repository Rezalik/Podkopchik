#!/bin/sh
# Only a disposable no-NIC VM may stage a helper for the live collector test.
set -eu
if [ ! -f /proc/device-tree/model ]; then echo 'SKIP: isolated OpenWrt VM required'; exit 0; fi
case "$(tr -d '\000' < /proc/device-tree/model)" in *dummy-virt*) ;; *) echo 'SKIP: isolated OpenWrt VM required'; exit 0;; esac
[ ! -e /sys/class/net/eth0 ]
for iface in /sys/class/net/*; do [ "$(basename "$iface")" = lo ] || exit 1; done
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
helper="${PODKOPCHIK_TEST_HELPER:-/mnt/bounded-helper}"
[ -f "$helper" ] && [ ! -L "$helper" ]
work=$(mktemp -d /tmp/pkc-platform-vm.XXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
cp "$helper" "$work/helper"
chmod 700 "$work/helper"
lib="$base/root/usr/libexec/podkopchik"
before=$(sha256sum /etc/config/firewall)
nft -s list ruleset > "$work/before.nft"
if ucode -L "$lib" "$lib/native_platform_check.uc" --helper "$work/helper" --awg > "$work/live.json"; then exit 1; else [ "$?" = 2 ]; fi
ucode -e 'import {readfile} from "fs";let r=json(readfile(ARGV[0]));
 if(r.source!="live_read_only"||r.status!="blocked"||r.installation_authorized||r.activation_authorized||index(r.blockers,"target")<0||index(r.unknown_checks,"bounded_executor")>=0)
 die("VM platform incorrectly admitted or live collector unavailable");' "$work/live.json"
[ "$(sha256sum /etc/config/firewall)" = "$before" ]
nft -s list ruleset > "$work/after.nft"
cmp "$work/before.nft" "$work/after.nft"
ln -s "$work/helper" "$work/unsafe"
if ucode -L "$lib" "$lib/native_platform_check.uc" --helper "$work/unsafe" > "$work/rejected.json"; then exit 1; else code=$?; [ "$code" = 2 ] || [ "$code" = 3 ]; fi
ucode -e 'import {readfile} from "fs";let r=json(readfile(ARGV[0]));if(index(r.unknown_checks,"bounded_executor")<0)die("symlink helper accepted");' "$work/rejected.json"
rm "$work/unsafe"
cp "$work/helper" "$work/unsafe"
chmod 777 "$work/unsafe"
if ucode -L "$lib" "$lib/native_platform_check.uc" --helper "$work/unsafe" > "$work/rejected.json"; then exit 1; else code=$?; [ "$code" = 2 ] || [ "$code" = 3 ]; fi
ucode -e 'import {readfile} from "fs";let r=json(readfile(ARGV[0]));if(index(r.unknown_checks,"bounded_executor")<0)die("writable helper accepted");' "$work/rejected.json"
echo 'PASS: live bounded collector, VM target refusal, unchanged UCI/nft, symlink/writable helper rejection'
