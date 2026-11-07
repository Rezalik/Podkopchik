#!/bin/sh
set -eu
umask 077
. /mnt/lab/native-vm-only.sh
state=/etc/pkc-native-vm-state
phase=first
boot=$(cat /proc/sys/kernel/random/boot_id)
if [ -s "$state/classification-boot" ]; then
	[ "$boot" != "$(cat "$state/classification-boot")" ] || exit 1
	phase=second
fi
exec > "$state/classification-$phase.log" 2>&1
printf '%s\n' /mnt/lab/base/packages.adb /mnt/lab/kernel/packages.adb >/tmp/pkc-classification-repos
apk --repositories-file /tmp/pkc-classification-repos --no-cache --no-progress add ip-full kmod-veth kmod-nft-tproxy tcpdump-mini
modprobe veth
if [ "$phase" = second ]; then
	[ "$(ucode /mnt/lab/trial-state.uc poll "$state/classification-trial")" = rollback ]
	if ucode /mnt/lab/trial-state.uc confirm "$state/classification-trial"; then exit 1; fi
fi
sh /mnt/lab/native-classification-vm-test.sh
if [ "$phase" = first ]; then
	mkdir -m 700 "$state/classification-trial"
	ucode /mnt/lab/trial-state.uc arm "$state/classification-trial" 300
	ucode /mnt/lab/trial-state.uc verify "$state/classification-trial"
	printf '%s\n' "$boot" > "$state/classification-boot"
	sync
	reboot
else
	ucode /mnt/lab/trial-state.uc restored "$state/classification-trial"
	: > "$state/classification-pass"
	sync
	echo 'PASS: actual reboot, procd reran both classification modes and both migration settings; old trial cannot be confirmed'
fi
