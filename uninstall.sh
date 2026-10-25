#!/bin/sh

set -u

APP="podkopchik"
PURGE=0
DESTDIR="${PODKOPCHIK_INSTALL_ROOT:-}"
BASE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
path() { printf '%s%s' "$DESTDIR" "$1"; }

for arg in "$@"; do
	case "$arg" in
		--purge) PURGE=1 ;;
		-h|--help)
			echo "Usage: uninstall.sh [--purge]"
			exit 0
			;;
		*) echo "Unknown argument: $arg" >&2; exit 2 ;;
	esac
done

[ "${PODKOPCHIK_INSTALL_ASSUME_ROOT:-0}" = 1 ] || [ "$(id -u)" = "0" ] || {
	echo "podkopchik uninstall: run as root on OpenWrt" >&2
	exit 1
}

helper="$(path /usr/libexec/podkopchik/packages.sh)"
[ -f "$helper" ] || helper="$BASE_DIR/root/usr/libexec/podkopchik/packages.sh"
REGISTERED=""
if [ -f "$helper" ]; then
	. "$helper"
	pkg_detect || exit 1
	for package in luci-i18n-podkopchik-ru luci-app-podkopchik; do
		if pkg_installed "$package"; then REGISTERED="$REGISTERED $package"; fi
	done
fi

umask 077
backup=""
if [ -f "$(path /etc/config/podkopchik)" ]; then
	backup="$(mktemp "${TMPDIR:-/tmp}/podkopchik-uninstall.XXXXXX")" || exit 1
	cp -p "$(path /etc/config/podkopchik)" "$backup" || { rm -f "$backup"; exit 1; }
fi
finish() {
	rc=$?
	trap - EXIT HUP INT TERM
	if [ -n "$backup" ] && { [ "$PURGE" = 0 ] || [ "$rc" != 0 ]; }; then
		cp -p "$backup" "$(path /etc/config/podkopchik)" || rc=1
	fi
	[ -z "$backup" ] || rm -f "$backup"
	exit "$rc"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM

"$(path /etc/init.d/podkopchik)" stop >/dev/null 2>&1 || true
"$(path /etc/init.d/podkopchik)" disable >/dev/null 2>&1 || true
# A test root must never execute routing helpers against the host network.
if [ -z "$DESTDIR" ]; then /usr/libexec/podkopchik/cleanup_rules.sh >/dev/null 2>&1 || true; fi

for package in $REGISTERED; do
	pkg_remove "$package" || { echo "podkopchik uninstall: $PKG_MANAGER removal failed: $package" >&2; exit 1; }
done

rm -f "$(path /etc/init.d/podkopchik)"
rm -f "$(path /usr/bin/podkopchikctl)"
rm -rf "$(path /usr/libexec/podkopchik)"
rm -f "$(path /usr/share/luci/menu.d/luci-app-podkopchik.json)"
rm -f "$(path /usr/share/rpcd/acl.d/luci-app-podkopchik.json)"
rm -f "$(path /usr/share/ucode/luci/i18n/podkopchik.ru.lmo)"
rm -f "$(path /usr/lib/lua/luci/i18n/podkopchik.ru.lmo)"
rm -rf "$(path /www/luci-static/resources/view/podkopchik)"
rm -f "$(path /etc/podkopchik/config.json)" "$(path /etc/podkopchik/config.json.prev)" "$(path /etc/podkopchik/config.generated.json)"
rm -rf "$(path /tmp/podkopchik)"

if [ "$PURGE" = "1" ]; then
	rm -f "$(path /etc/config/podkopchik)"
	rm -rf "$(path /etc/podkopchik)"
	rm -rf "$(path /usr/libexec/podkopchik-core)"
fi

if [ -z "$DESTDIR" ]; then
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
	/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
fi

if [ "$PURGE" = "1" ]; then
	echo "Podkopchik removed, including /etc/config/podkopchik."
else
	echo "Podkopchik removed. /etc/config/podkopchik was preserved."
fi
