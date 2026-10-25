#!/bin/sh
# Run on a Linux OpenWrt 25.12.6 SDK host. Does not deploy/install anything.
set -eu
[ "$#" = 1 ] || { echo 'Usage: sh tools/build-awg-apk.sh /path/to/OpenWrt-25.12.6-SDK' >&2; exit 2; }
[ "$(uname -s)" = Linux ] || { echo 'Native OpenWrt APK build requires a Linux SDK host, not macOS' >&2; exit 1; }
base="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
sdk="$(CDPATH= cd -- "$1" && pwd)"
grep -q '^CONFIG_USE_APK=y$' "$sdk/.config"
grep -q '^CONFIG_TARGET_mediatek_filogic=y$' "$sdk/.config"
test -f "$sdk/feeds/luci/luci.mk"
test -f "$sdk/include/package.mk"
test ! -e "$sdk/package/podkopchik"
mkdir "$sdk/package/podkopchik"
cp "$base/Makefile" "$sdk/package/podkopchik/"
cp -R "$base/root" "$base/po" "$sdk/package/podkopchik/"
mkdir -p "$sdk/package/podkopchik/root/usr/share/podkopchik/tools"
cp "$base/tools/awg-preflight.sh" "$base/tools/awg-rollback.sh" "$sdk/package/podkopchik/root/usr/share/podkopchik/tools/"
find "$sdk/package/podkopchik" -name .DS_Store -delete
make -C "$sdk" package/podkopchik/compile V=s
find "$sdk/bin/packages" -name '*podkopchik*.apk' -print
echo 'Verify package contents and sign using your approved SDK key before installation; no trust bypass'
