#!/bin/sh
# Device checks only: no installs, service changes, network writes or backups.
set -eu
fail() { echo "Native routing preflight: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || fail 'requires root to inspect nftables'
[ "$(cat /tmp/sysinfo/board_name)" = xiaomi,redmi-router-ax6000-stock ] || fail 'unsupported board'
[ "$(uname -m)" = aarch64 ] && [ "$(uname -r)" = 6.12.112 ] || fail 'unsupported kernel or architecture'
. /etc/openwrt_release
[ "$DISTRIB_RELEASE" = 25.12.6 ] && [ "$DISTRIB_ARCH" = aarch64_cortex-a53 ] || fail 'unsupported OpenWrt build'
for c in ip nft ucode uci ubus fw4 jsonfilter sha256sum; do command -v "$c" >/dev/null || fail "missing $c"; done
ip -V 2>&1 | grep -q iproute2 || fail 'ip-full is required'
base="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
(cd "$base" && sha256sum -c SHA256SUMS) || fail 'candidate payload mismatch'
sh "$base/check-offload.sh"
free=$(df -Pk /overlay | awk 'END {print $4}')
[ "$free" -ge 13312 ] || fail 'less than 13 MiB free on overlay'
tmp=$(df -Pk /tmp | awk 'END {print $4}')
[ "$tmp" -ge 12288 ] || fail 'less than 12 MiB free in /tmp'
echo 'Space floors passed; account for the exact candidate and recovery bundle before staging.'
echo 'Read-only candidate checks passed. This does not authorize or perform activation.'
