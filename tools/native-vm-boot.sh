#!/bin/sh
set -eu
umask 077
. /mnt/lab/native-vm-only.sh
state=/etc/pkc-native-vm-state
[ -d "$state" ] && [ ! -L "$state" ]
export PKC_VM_PERSIST="$state"
boot=$(cat /proc/sys/kernel/random/boot_id)
phase=first
if [ -s "$state/first-boot" ]; then
	[ "$boot" != "$(cat "$state/first-boot")" ] || exit 1
	phase=second
	export PKC_VM_REBOOTED=1
fi
exec >"$state/$phase.log" 2>&1
echo "VM boot phase=$phase kernel=$(uname -r)"
echo 'System procd boot: firewall and dnsmasq init order precedes native fixture'
[ -x /etc/rc.d/S19firewall ] || ls /etc/rc.d/*firewall
ls /etc/rc.d/*dnsmasq /etc/rc.d/*pkc-native-vm-boot
if [ "$phase" = second ]; then
	[ "$(ucode /mnt/lab/trial-state.uc poll "$state/reboot-trial")" = rollback ]
	if ucode /mnt/lab/trial-state.uc confirm "$state/reboot-trial"; then exit 1; fi
	echo 'PASS: reboot invalidates an unconfirmed trial from the prior boot'
fi
sh /mnt/lab/setup-native-dns-guest.sh
if [ "$phase" = first ]; then
	mkdir -m 700 "$state/reboot-trial"
	ucode /mnt/lab/trial-state.uc arm "$state/reboot-trial" 600
	ucode /mnt/lab/trial-state.uc verify "$state/reboot-trial"
	printf '%s\n' "$boot" > "$state/first-boot"
	sync
	reboot
else
	: > "$state/reboot-pass"
	sync
	echo 'PASS: actual reboot and automatic procd startup retained the DNS ledger'
fi
