#!/bin/sh

set -u

APP="podkopchik"
PURGE=0

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

[ "$(id -u)" = "0" ] || {
	echo "podkopchik uninstall: run as root on OpenWrt" >&2
	exit 1
}

/etc/init.d/podkopchik stop >/dev/null 2>&1 || true
/etc/init.d/podkopchik disable >/dev/null 2>&1 || true
/usr/libexec/podkopchik/cleanup_rules.sh >/dev/null 2>&1 || true

rm -f /etc/init.d/podkopchik
rm -f /usr/bin/podkopchikctl
rm -rf /usr/libexec/podkopchik
rm -f /usr/share/luci/menu.d/luci-app-podkopchik.json
rm -f /usr/share/rpcd/acl.d/luci-app-podkopchik.json
rm -rf /www/luci-static/resources/view/podkopchik
rm -f /etc/podkopchik/config.json /etc/podkopchik/config.json.prev /etc/podkopchik/config.generated.json
rm -rf /tmp/podkopchik

if [ "$PURGE" = "1" ]; then
	rm -f /etc/config/podkopchik
	rm -rf /etc/podkopchik
fi

/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

if [ "$PURGE" = "1" ]; then
	echo "Podkopchik removed, including /etc/config/podkopchik."
else
	echo "Podkopchik removed. /etc/config/podkopchik was preserved."
fi
