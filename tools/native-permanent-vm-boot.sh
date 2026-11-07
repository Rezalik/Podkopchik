#!/bin/sh
set -eu
umask 077
. /mnt/lab/native-vm-only.sh
export PKC_VM_PERMANENT=1 PKC_VM_PERMANENT_STATE=/etc/pkc-permanent-vm
mkdir -p -m700 "$PKC_VM_PERMANENT_STATE"
phase=first
if [ -f "$PKC_VM_PERMANENT_STATE/extended" ]; then
	export PKC_VM_RUNTIME_EXTENDED=1
	exec >"$PKC_VM_PERMANENT_STATE/extended-$(cat /proc/sys/kernel/random/boot_id).log" 2>&1
	sh /mnt/lab/setup-native-dns-guest.sh
	[ -f "$PKC_VM_PERMANENT_STATE/EXTENDED-PASS" ] || reboot
	exit
fi
if [ -f "$PKC_VM_PERMANENT_STATE/first" ]; then phase=second; fi
if [ -f "$PKC_VM_PERMANENT_STATE/pending-reboot" ]; then phase=third; fi
exec >"$PKC_VM_PERMANENT_STATE/$phase.log" 2>&1
echo "Permanent Native lifecycle: phase=$phase boot=$(cat /proc/sys/kernel/random/boot_id)"
sh /mnt/lab/setup-native-dns-guest.sh
if [ "$phase" = third ]; then
	touch "$PKC_VM_PERMANENT_STATE/PASS"
	sync
	echo 'PASS: permanent Native Apply acceptance completed across two real reboots'
else
	touch "$PKC_VM_PERMANENT_STATE/first"
	sync
	reboot
fi
