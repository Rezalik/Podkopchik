#!/bin/sh
# Complete source overlay, not a fabricated APK. Never includes user data.
set -eu
umask 077
[ "$#" = 1 ] || { echo 'Usage: tools/build-awg-stage23.sh /absolute/path/bundle.tar.gz' >&2; exit 2; }
case "$1" in /*) out="$1" ;; *) exit 2 ;; esac
[ ! -e "$out" ] || { echo 'Refusing to overwrite a bundle' >&2; exit 1; }
base="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT HUP INT TERM
cp -R "$base/root/." "$stage/"
rm -f "$stage/etc/config/podkopchik"
rmdir "$stage/etc/config"
test ! -e "$stage/etc/podkopchik/awg"
for dir in usr/share/ucode/luci/i18n usr/lib/lua/luci/i18n; do
	mkdir -p "$stage/$dir"
	cp "$base/i18n/ru/podkopchik.ru.lmo" "$stage/$dir/"
done
mkdir -p "$stage/usr/share/podkopchik/tools"
for tool in awg-preflight.sh awg-rollback.sh; do cp "$base/tools/$tool" "$stage/usr/share/podkopchik/tools/"; done
find "$stage" -name .DS_Store -delete
find "$stage" -type d -exec chmod 755 {} \;
find "$stage" -type f -exec chmod 644 {} \;
find "$stage/usr/libexec/podkopchik" -name '*.sh' -exec chmod 755 {} \;
chmod 755 "$stage/etc/init.d/podkopchik" "$stage/usr/bin/podkopchikctl" "$stage/usr/libexec/rpcd/podkopchik.awg"
if tar --version 2>/dev/null | grep -q bsdtar; then
	COPYFILE_DISABLE=1 tar --uid 0 --gid 0 --uname root --gname root -czf "$out" -C "$stage" .
else tar --owner=0 --group=0 -czf "$out" -C "$stage" .; fi
sha256sum "$out"
