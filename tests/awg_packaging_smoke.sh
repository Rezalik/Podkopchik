#!/bin/sh
set -eu
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
if sh tools/build-awg-stage1.sh "$tmp/unsafe.tar.gz" >/dev/null 2>&1; then
	echo 'FAIL: partial Stage 1 bundle was allowed with mixed runtime'; exit 1
fi
sh tools/build-awg-stage23.sh "$tmp/awg.tar.gz" >/dev/null
tar -tvzf "$tmp/awg.tar.gz" | awk '$2 == "root/root" || $2 == "0/0" || ($3 == "root" && $4 == "root") { next } { bad=1 } END { exit bad }'
mkdir "$tmp/payload"
tar -xzf "$tmp/awg.tar.gz" -C "$tmp/payload"
test -x "$tmp/payload/usr/libexec/rpcd/podkopchik.awg"
test -f "$tmp/payload/lib/upgrade/keep.d/podkopchik-awg"
test ! -f "$tmp/payload/etc/config/podkopchik"
test ! -d "$tmp/payload/etc/podkopchik/awg"
test -f "$tmp/payload/usr/libexec/podkopchik/awg_network.uc"
test -f "$tmp/payload/usr/libexec/podkopchik/awg_manage.uc"
test -f "$tmp/payload/usr/share/podkopchik/tools/awg-rollback.sh"
test -x "$tmp/payload/etc/init.d/podkopchik"
test -x "$tmp/payload/usr/libexec/podkopchik/health_check.sh"
cmp i18n/ru/podkopchik.ru.lmo "$tmp/payload/usr/share/ucode/luci/i18n/podkopchik.ru.lmo"
if sh tools/build-awg-stage23.sh "$tmp/awg.tar.gz" >/dev/null 2>&1; then
	echo 'FAIL: existing bundle overwritten'; exit 1
fi
echo 'AWG overlay bundle isolation and executable-mode smoke OK'
