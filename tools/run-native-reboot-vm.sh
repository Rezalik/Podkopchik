#!/bin/sh
# Persistent disposable guest. Only the private EFI disk is writable.
set -eu
umask 077
base="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$base/.build/universal-dns-vm"
payload="${PKC_VM_PAYLOAD:-$work/payload}"
case "$payload" in "$work"/payload*) [ -d "$payload" ];; *) exit 2;; esac
utm=/Applications/UTM.app/Contents
fw="$utm/Frameworks"
image="$work/openwrt-efi.img.gz"
name="${1:-reboot-lab}"
case "$name" in reboot-lab*) ;; *) exit 2 ;; esac
case "$name" in *[!A-Za-z0-9_-]*) exit 2 ;; esac
disk="$work/$name.img"
printf '%s  %s\n' 77a3802b583a6964ccb868c80f83a6ea0eb5847d3835350b5f0bcbf6f141d1d3 "$image" | shasum -a 256 -c
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$utm/Info.plist")" = 4.7.5 ]
[ ! -e "$disk" ] || { echo 'Existing VM disk: move it aside before a fresh run' >&2; exit 1; }
gzip -dc "$image" > "$disk"
clang -Wall -Wextra -Werror -Wl,-rpath,"$fw" "$base/tools/openwrt-lab-utm.c" -o "$work/qemu"
exec "$work/qemu" "$fw/qemu-aarch64-softmmu.framework/Versions/A/qemu-aarch64-softmmu" \
	-L "$utm/Resources/qemu" -M virt -accel tcg,thread=single -cpu cortex-a53 -smp 1 -m 512 -display none -serial stdio -monitor none \
	-nic none -virtfs "local,path=$payload,mount_tag=pkclab,security_model=none,readonly=on" \
	-bios "$utm/Resources/qemu/edk2-aarch64-code.fd" \
	-drive "if=none,id=lab,format=raw,file=$disk" -device virtio-blk-pci,drive=lab
