#!/bin/sh
# Both the direct-kernel and EFI harness have no external network device.
if [ -r /proc/device-tree/model ] && [ "$(tr -d '\000' </proc/device-tree/model)" = linux,dummy-virt ]; then
	:
else
	[ "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)" = QEMU ] &&
	[ "$(cat /sys/class/dmi/id/product_name 2>/dev/null)" = 'QEMU Virtual Machine' ] &&
	[ "$(cat /tmp/sysinfo/board_name 2>/dev/null)" = qemu-qemu-virtual-machine ] || exit 2
fi
[ "$(ls /sys/class/net)" = lo ] || exit 2
