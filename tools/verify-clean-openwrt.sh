#!/bin/sh
set -eu

# Opt-in acceptance for a disposable x86_64 VM, never the physical AX6000.
[ "${PODKOPCHIK_TEST_VM:-}" = disposable ] || {
	echo 'Refusing: set PODKOPCHIK_TEST_VM=disposable only inside a disposable VM' >&2; exit 1;
}
. /etc/openwrt_release
[ "$DISTRIB_RELEASE" = 25.12.6 ] && [ "$DISTRIB_TARGET" = x86/64 ] || {
	echo 'Refusing: requires OpenWrt 25.12.6 x86/64 VM, not a physical router' >&2; exit 1;
}
[ ! -e /etc/config/podkopchik ] || { echo 'Refusing: Podkopchik already configured' >&2; exit 1; }
cd "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT HUP INT TERM
sha256sum /etc/config/network /etc/config/firewall /etc/config/dropbear > "$work/network.before"
sh install.sh
sha256sum /etc/config/network /etc/config/firewall /etc/config/dropbear > "$work/network.after"
cmp "$work/network.before" "$work/network.after"
test "$(uci -q get podkopchik.main.routing_enabled)" = 0
test "$(uci -q get podkopchik.main.fakedns_enabled)" = 0
! nft list table inet podkopchik >/dev/null 2>&1
podkopchikctl validate
podkopchikctl generate
xray run -test -config /etc/podkopchik/config.generated.json
podkopchikctl xray-status
cp -p /etc/config/podkopchik "$work/config.expected"
sh install.sh
cmp "$work/config.expected" /etc/config/podkopchik
sh uninstall.sh
cmp "$work/config.expected" /etc/config/podkopchik
sh install.sh
cmp "$work/config.expected" /etc/config/podkopchik
echo 'Clean 25.12.6 VM install/reinstall/uninstall acceptance PASS; LAN proxy egress still requires a configured test proxy'
