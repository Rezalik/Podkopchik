#!/bin/sh
set -eu
. /mnt/lab/native-vm-only.sh
ns="pkc-policy-uci-$$"
ip netns add "$ns"
trap 'ip netns del "$ns"' EXIT
ucode() {
	if [ -n "${UCI_CONFIG_DIR:-}" ]; then
		ip netns exec "$ns" sh -c 'mount --bind "$UCI_CONFIG_DIR" /etc/config && exec /usr/bin/ucode "$@"' ucode "$@"
	else command ucode "$@"; fi
}
cd /mnt/lab/regression
( . ./tests/generate_native_preview_smoke.sh )
