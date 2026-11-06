#!/bin/sh
# Workstation only. The guest verifies APKs using its original OpenWrt keys.
set -eu
umask 077
base="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$base/.build/universal-dns-vm"
payload="$work/payload"
release=https://downloads.openwrt.org/releases/25.12.6
target="$release/targets/armsr/armv8"
image=openwrt-25.12.6-armsr-armv8-generic-initramfs-kernel.bin
mkdir -p "$payload/base" "$payload/kernel" "$payload/source"
fetch() {
	[ -f "$2" ] && return
	curl --proto '=https' -fsSL --max-time 120 "$1" -o "$2.part"
	mv "$2.part" "$2"
}
fetch "$target/$image" "$work/openwrt-initramfs.bin"
printf '%s  %s\n' 2b1f0796ec31201b609643beca48de20d75f2879104a20adba327cbaf64b5f2b "$work/openwrt-initramfs.bin" | shasum -a 256 -c
for f in packages.adb ip-full-6.18.0-r2.apk libbpf1-1.6.2-r1.apk libelf1-0.192-r1.apk libpcap1-1.10.6-r1.apk tcpdump-mini-4.99.6-r1.apk; do
	fetch "$release/packages/aarch64_generic/base/$f" "$payload/base/$f"
done
for f in packages.adb kmod-veth-6.12.112-r1.apk kmod-nf-tproxy-6.12.112-r1.apk kmod-nft-tproxy-6.12.112-r1.apk; do
	fetch "$target/kmods/6.12.112-1-67e205f26d0458c4d12f1fd315216398/$f" "$payload/kernel/$f"
done
sh "$base/tools/build-native-dns.sh"
sh "$base/tools/build-native-stock-xray.sh"
xray="$base/.build/native-stock-xray/xray"
printf '%s  %s\n' b07ac0b0bc7c8ae09fefa5d93e3623ee32f0d52bba26cb809da82fede794461d "$xray" | shasum -a 256 -c
cp "$xray" "$payload/xray"
for f in podkopchik-native-dns native-dns.test SHA256SUMS; do cp "$base/.build/native-dns/$f" "$payload/"; done
for f in universal_plan native_pool awg awg_network fakedns_guard; do cp "$base/root/usr/libexec/podkopchik/$f.uc" "$payload/source/"; done
cp "$base/tests/native_dns_vm_plan.uc" "$payload/source/"
cp "$base/tools/native-dns-vm-test.sh" "$base/tools/setup-native-dns-guest.sh" "$payload/"
for f in native-vm-only.sh native-vm-watchdog.sh native-vm-detached-test.sh install-native-vm-boot.sh native-vm-boot.init native-vm-boot.sh; do
	cp "$base/tools/$f" "$payload/"
done
cp "$base/native/runtime/check-offload.sh" "$base/native/runtime/procd-dns.sh" "$base/native/runtime/trial-state.uc" "$payload/"
regression="$payload/regression"
mkdir -p "$regression/tests" "$regression/root/usr/libexec/podkopchik" "$regression/root/etc/init.d"
cp "$base/tests/"generate_*_smoke.sh "$base/tests/xray_udp_session_smoke.sh" "$regression/tests/"
for f in awg awg_network generate vless interception; do
	cp "$base/root/usr/libexec/podkopchik/$f.uc" "$regression/root/usr/libexec/podkopchik/"
done
cp "$base/root/etc/init.d/podkopchik" "$regression/root/etc/init.d/"
