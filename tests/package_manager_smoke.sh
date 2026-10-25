#!/bin/sh
set -eu
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export PODKOPCHIK_OPENWRT_RELEASE="$tmp/release"
mkdir "$tmp/bin"
export PATH="$tmp/bin:$PATH"
for name in apk opkg; do
	printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/$name"
	chmod +x "$tmp/bin/$name"
done
. root/usr/libexec/podkopchik/packages.sh
echo "DISTRIB_RELEASE='24.10.1'" > "$tmp/release"
pkg_detect
[ "$PKG_MANAGER" = opkg ]
echo "DISTRIB_RELEASE='25.12.6'" > "$tmp/release"
pkg_detect
[ "$PKG_MANAGER" = apk ]
echo "DISTRIB_RELEASE='unknown'" > "$tmp/release"
if pkg_detect 2>/dev/null; then echo 'FAIL: ambiguous managers accepted'; exit 1; fi
rm "$tmp/bin/opkg"
pkg_detect
[ "$PKG_MANAGER" = apk ]
echo "DISTRIB_RELEASE='24.10.1'" > "$tmp/release"
if pkg_detect 2>/dev/null; then echo 'FAIL: 24.10 silently fell back to apk'; exit 1; fi
echo 'package manager detection smoke OK'
