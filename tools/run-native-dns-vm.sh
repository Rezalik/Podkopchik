#!/bin/sh
# Private OpenWrt VM: no virtual NIC, no writable host share, no port forwarding.
set -eu
base="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$base/.build/universal-dns-vm"
utm=/Applications/UTM.app/Contents
fw="$utm/Frameworks"
kernel="$work/openwrt-initramfs.bin"
printf '%s  %s\n' 2b1f0796ec31201b609643beca48de20d75f2879104a20adba327cbaf64b5f2b "$kernel" | shasum -a 256 -c
[ -d "$work/payload" ]
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$utm/Info.plist")" = 4.7.5 ]
clang -Wall -Wextra -Werror -Wl,-rpath,"$fw" "$base/tools/openwrt-lab-utm.c" -o "$work/qemu"
exec "$work/qemu" "$fw/qemu-aarch64-softmmu.framework/Versions/A/qemu-aarch64-softmmu" \
	-L "$utm/Resources/qemu" -M virt -accel tcg,thread=single -cpu cortex-a53 -smp 1 -m 512 -display none -serial stdio -monitor none \
	-nic none -virtfs "local,path=$work/payload,mount_tag=pkclab,security_model=none,readonly=on" \
	-kernel "$kernel" -append 'console=ttyAMA0' -no-reboot
