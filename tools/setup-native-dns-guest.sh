#!/bin/sh
# Install signed dependencies only in the NIC-free disposable QEMU guest.
set -eu
umask 077
[ "$(tr -d '\000' </proc/device-tree/model)" = linux,dummy-virt ]
[ "$(ls /sys/class/net)" = lo ]
[ "$(uname -r)" = 6.12.112 ]
cd /mnt/lab
sha256sum -c SHA256SUMS
printf '%s\n' 'f9fd8632e0a8e651fcfb5d5f1de9288e163c5ffff09da6a38d7fccfd064b75a0  xray' | sha256sum -c
printf '%s\n' /mnt/lab/base/packages.adb /mnt/lab/kernel/packages.adb >/tmp/pkc-lab-repositories
apk --repositories-file /tmp/pkc-lab-repositories --no-cache --no-progress add ip-full kmod-veth kmod-nft-tproxy tcpdump-mini
modprobe veth
./native-dns.test -test.v
(
	cd /mnt/lab/regression
	ns="pkc-regression-$$"
	ip netns add "$ns"
	trap 'ip netns del "$ns"' EXIT
	ucode() {
		if [ -n "${UCI_CONFIG_DIR:-}" ]; then
			ip netns exec "$ns" sh -c 'mount --bind "$UCI_CONFIG_DIR" /etc/config && exec /usr/bin/ucode "$@"' ucode "$@"
		else
			command ucode "$@"
		fi
	}
	for t in tests/generate_*_smoke.sh; do ( . "./$t" ); done
	XRAY_TEST_BIN=/mnt/lab/xray sh tests/xray_udp_session_smoke.sh
)
sh ./native-dns-vm-test.sh
