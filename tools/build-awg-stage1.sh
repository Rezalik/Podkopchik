#!/bin/sh
set -eu
umask 077
[ "$#" = 1 ] || { echo 'Usage: tools/build-awg-stage1.sh /absolute/path/bundle.tar.gz' >&2; exit 1; }
case "$1" in /*) out="$1" ;; *) echo 'Output path must be absolute' >&2; exit 1 ;; esac
[ ! -e "$out" ] || { echo 'Refusing to overwrite an existing bundle' >&2; exit 1; }
base="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT HUP INT TERM
for file in \
  usr/libexec/podkopchik/awg.uc \
  usr/libexec/podkopchik/awg_rpc.uc \
  usr/libexec/rpcd/podkopchik.awg \
  usr/share/rpcd/acl.d/luci-app-podkopchik.json \
  usr/share/luci/menu.d/luci-app-podkopchik.json \
  www/luci-static/resources/view/podkopchik/awg.js \
  lib/upgrade/keep.d/podkopchik-awg; do
	mkdir -p "$stage/$(dirname "$file")"
	cp "$base/root/$file" "$stage/$file"
	chmod 644 "$stage/$file"
done
chmod 755 "$stage/usr/libexec/rpcd/podkopchik.awg"
for dir in usr/share/ucode/luci/i18n usr/lib/lua/luci/i18n; do
	mkdir -p "$stage/$dir"
	cp "$base/i18n/ru/podkopchik.ru.lmo" "$stage/$dir/podkopchik.ru.lmo"
	chmod 644 "$stage/$dir/podkopchik.ru.lmo"
done
# Only public application files, never /etc/podkopchik/awg or user fixtures.
find "$stage" -type d -exec chmod 755 {} \;
if tar --version 2>/dev/null | grep -q bsdtar; then
	COPYFILE_DISABLE=1 tar --uid 0 --gid 0 --uname root --gname root -czf "$out" -C "$stage" .
else
	tar --owner=0 --group=0 -czf "$out" -C "$stage" .
fi
echo "$out"
