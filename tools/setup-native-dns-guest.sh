#!/bin/sh
# Install signed dependencies only in the NIC-free disposable QEMU guest.
set -eu
umask 077
. /mnt/lab/native-vm-only.sh
[ "$(uname -r)" = 6.12.112 ]
cd /mnt/lab
sha256sum -c SHA256SUMS
printf '%s\n' 'b07ac0b0bc7c8ae09fefa5d93e3623ee32f0d52bba26cb809da82fede794461d  xray' | sha256sum -c
printf '%s\n' /mnt/lab/base/packages.adb /mnt/lab/kernel/packages.adb /mnt/lab/packages/packages.adb >/tmp/pkc-lab-repositories
apk --repositories-file /tmp/pkc-lab-repositories --no-cache --no-progress add ip-full kmod-veth kmod-nft-tproxy tcpdump-mini curl
modprobe veth
if [ "${PKC_VM_PERMANENT:-0}" = 1 ]; then
	ucode -c -o /tmp/pkc-native-runtime.ucb -L /mnt/lab/permanent/usr/libexec/podkopchik /mnt/lab/permanent/usr/libexec/podkopchik/native_runtime.uc
	sh ./native-dns-vm-test.sh
	exit
fi
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
sh ./ax6000-recovery-vm-test.sh
sh ./ax6000-virtual-watch-vm-test.sh
sh ./virtual-pilot-vm-test.sh
ucode -L /mnt/lab/source /mnt/lab/source/fakedns_guard_smoke.uc
ucode -L /mnt/lab/source /mnt/lab/source/universal_selection_smoke.uc
ucode -L /mnt/lab/source /mnt/lab/source/native_classification_smoke.uc
sh ./ax6000-fakedns-guard-trial-vm-test.sh
sh ./fakedns-egress-vm-test.sh
sh ./native-apply-vm-test.sh
sh ./native-dns-vm-test.sh
