#!/bin/sh
# Destructive only to an isolated, no-NIC, disposable OpenWrt VM filesystem.
set -eu
if [ ! -f /proc/device-tree/model ]; then
	echo 'SKIP: static install/restore needs a disposable OpenWrt VM'
	exit 0
fi
case "$(tr -d '\000' < /proc/device-tree/model)" in *dummy-virt*) ;; *) echo 'SKIP: disposable OpenWrt VM only'; exit 0 ;; esac
[ ! -d /sys/class/net/eth0 ]
umask 077
work=$(mktemp -d /tmp/pkc-luci-update.XXXXXX)
tar -xzf /mnt/lab/luci-alignment.tar.gz -C "$work"
cp -R /mnt/lab/regression/root/usr/libexec/podkopchik /usr/libexec/
mkdir -p /tmp/sysinfo /etc/podkopchik-native-emergency
printf '%s\n' xiaomi,redmi-router-ax6000-stock > /tmp/sysinfo/board_name
# This fixture checks static installation, not the independently tested rescue.
printf '%s\n' 'if (ARGV[0]!="verify") die("unexpected rescue action");' > /etc/podkopchik-native-emergency/recovery.uc
touch /etc/config/podkopchik
uci set podkopchik.main=settings
uci set podkopchik.main.routing_engine=native
uci set podkopchik.main.native_classification_mode=compatible
uci set podkopchik.main.native_migration_restrict_unknown=0
uci commit podkopchik
mkdir -p /www/luci-static/resources/view/podkopchik
printf '%s\n' baseline-ui > /www/luci-static/resources/view/podkopchik/status.js
before=$(sha256sum /etc/config/podkopchik)
sh "$work/install.sh" check "$work"
sh "$work/install.sh" install "$work"
test -f /www/luci-static/resources/podkopchik/routing.js
grep -q 'Active routing policy' /www/luci-static/resources/view/podkopchik/status.js
test "$(sha256sum /etc/config/podkopchik)" = "$before"
sh "$work/install.sh" restore "$work"
test "$(cat /www/luci-static/resources/view/podkopchik/status.js)" = baseline-ui
test ! -e /www/luci-static/resources/podkopchik/routing.js
test "$(sha256sum /etc/config/podkopchik)" = "$before"
echo 'LUCI_STATIC_INSTALL_RESTORE_PASS'
