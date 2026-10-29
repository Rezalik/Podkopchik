#!/bin/sh
# Read-only unless --backup is explicitly requested. No package installation.
set -eu
umask 077
fail() { echo "AWG preflight: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || fail 'run on the approved AX6000 as root'
[ "$(cat /tmp/sysinfo/board_name)" = xiaomi,redmi-router-ax6000-stock ] || fail 'not the approved AX6000 stock board'
. /etc/openwrt_release
[ "$DISTRIB_RELEASE" = 25.12.6 ] || fail 'requires the verified OpenWrt 25.12.6 baseline'
[ "${DISTRIB_ARCH:-}" = aarch64_cortex-a53 ] || fail 'architecture mismatch'
[ "$(uname -r)" = 6.12.112 ] || fail 'kernel ABI baseline mismatch'
for tool in apk ip awg ucode curl nft jsonfilter netstat modprobe sha256sum; do
	command -v "$tool" >/dev/null || fail "missing $tool"
done
ip -V 2>&1 | grep -q iproute2 || fail 'ip-full is required'
awg --version | grep -q 'v3\.1\.' || fail 'AWG 3.1 tools are required'
apk info -e kmod-amneziawg >/dev/null || fail 'matching kmod-amneziawg is not installed'
apk info -e amneziawg-tools >/dev/null || fail 'amneziawg-tools is not installed'
[ -d /sys/module/amneziawg ] || fail 'matching AWG module must already be loaded; this read-only preflight does not load modules'
[ "$(cat /proc/sys/net/ipv4/conf/all/rp_filter)" = 0 ] || fail 'strict/global RPF is unsupported; no sysctl was changed'
ucode -e 'import * as fs from "fs"; import { cursor } from "uci"; let l=fs.open("/tmp/podkopchik-awg-preflight.lock","a+",0o600); if(!l || !l.lock("xn")) exit(1); l.close(); fs.unlink("/tmp/podkopchik-awg-preflight.lock");' || fail 'ucode fs/uci/flock unavailable'
. /usr/libexec/podkopchik/xray.sh
bin="$(xray_bin)"
[ -n "$bin" ] || fail 'selected Xray is missing'
"$bin" version | head -1
help="$("$bin" api statsquery --help 2>&1 || true)"
printf '%s\n' "$help" | grep -q 'usage: xray api statsquery' || fail 'Xray StatsService client is required'
printf '%s\n' "$help" | grep -q -- '--server=' || fail 'Xray StatsService client flags are missing'
for pid in $(netstat -lntp 2>/dev/null | awk '$4 ~ /:10085$/ {split($NF,p,"/");print p[1]}'); do
	case "$pid" in ''|*[!0-9]*) fail 'statistics port 10085 has an unknown owner' ;; esac
	case "$(tr '\000' ' ' < "/proc/$pid/cmdline")" in
		*' run -config /etc/podkopchik/config.json'*) ;;
		*) fail 'statistics port 10085 is occupied by another service' ;;
	esac
done
free="$(df -Pk /overlay | awk 'END {print $4}')"
[ "$free" -ge 12288 ] || fail 'less than 12 MiB free overlay space'
podkopchikctl validate-active >/dev/null || fail 'existing active configuration is not valid'
case "${1:---check}" in
 --check) [ "$#" -le 1 ] || fail 'unexpected arguments' ;;
 --backup)
	[ "$#" = 2 ] || fail 'usage: awg-preflight.sh --backup /root/NEW-NAME.tar.gz'
	case "$2" in /root/*) ;; *) fail 'backup must remain in /root on this router' ;; esac
	[ ! -e "$2" ] || fail 'backup path already exists'
	# Confidential config stays on-device. Never print its contents or send it
	# to the workstation as part of diagnostic output.
	set -- "$2" etc/config/podkopchik etc/podkopchik etc/init.d/podkopchik \
	 usr/bin/podkopchikctl usr/libexec/podkopchik usr/libexec/rpcd/podkopchik.awg \
	 usr/share/luci/menu.d/luci-app-podkopchik.json usr/share/rpcd/acl.d/luci-app-podkopchik.json \
	 www/luci-static/resources/view/podkopchik lib/upgrade/keep.d/podkopchik-awg
	archive="$1"; shift
	for path in usr/share/ucode/luci/i18n/podkopchik.ru.lmo usr/lib/lua/luci/i18n/podkopchik.ru.lmo; do
		[ ! -f "/$path" ] || set -- "$@" "$path"
	done
	# Add this as an explicit file, never repack a private staging directory:
	# archiving "." would restore its mode onto / and its parents onto /tmp.
	[ ! -f /tmp/podkopchik/state.json ] || set -- "$@" tmp/podkopchik/state.json
	[ ! -d /usr/share/podkopchik/tools ] || set -- "$@" usr/share/podkopchik/tools
	tar -czf "$archive" -C / "$@" || { rm -f "$archive"; fail 'backup failed'; }
	chmod 600 "$archive"
	sha256sum "$archive"
	;;
 *) fail 'usage: awg-preflight.sh [--check | --backup /root/NEW-NAME.tar.gz]' ;;
esac
echo 'AWG preflight OK; no interfaces, routes, packages or services changed'
