#!/bin/sh

set -u

APP="podkopchik"
BASE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR="$BASE_DIR/root"
CONFIG="/etc/config/$APP"

die() {
	echo "podkopchik install: $*" >&2
	exit 1
}

warn() {
	echo "podkopchik install: warning: $*" >&2
}

need_root() {
	[ "$(id -u)" = "0" ] || die "run as root on OpenWrt"
}

check_openwrt() {
	[ -r /etc/openwrt_release ] || die "this installer is for OpenWrt"
	. /etc/openwrt_release
	case "${DISTRIB_RELEASE:-}" in
		24.10*|25.*|26.*) ;;
		*) warn "OpenWrt ${DISTRIB_RELEASE:-unknown} detected; Podkopchik targets OpenWrt 24.10+" ;;
	esac
	command -v opkg >/dev/null 2>&1 || die "opkg is required"
}

install_deps() {
	pkgs="luci-base rpcd ucode ucode-mod-fs ucode-mod-uci ucode-mod-ubus curl ca-bundle jsonfilter nftables kmod-nft-tproxy firewall4 dnsmasq xray-core"
	opkg update || warn "opkg update failed; trying installed packages anyway"
	for pkg in $pkgs; do
		if ! opkg status "$pkg" >/dev/null 2>&1; then
			opkg install "$pkg" || warn "could not install dependency $pkg"
		fi
	done
}

install_tree() {
	[ -d "$ROOT_DIR" ] || die "missing root payload: $ROOT_DIR"
	mkdir -p /etc/podkopchik /tmp/podkopchik

	if [ -f "$CONFIG" ]; then
		tmpdir="/tmp/podkopchik-install.$$"
		payload="$tmpdir/payload"
		backup="$tmpdir/podkopchik.config"
		restore_existing_config() {
			[ -f "$backup" ] && cp "$backup" "$CONFIG" >/dev/null 2>&1 || true
			rm -rf "$tmpdir"
		}

		mkdir -p "$payload" || die "could not create temporary install directory"
		cp "$CONFIG" "$backup" || die "could not preserve existing config"
		trap 'restore_existing_config' HUP INT TERM EXIT
		( cd "$ROOT_DIR" && tar -cf - . ) | ( cd "$payload" && tar -xf - ) || die "could not stage files"
		rm -f "$payload/etc/config/podkopchik"
		( cd "$payload" && tar -cf - . ) | ( cd / && tar -xf - ) || die "could not install files"
		cp "$backup" "$CONFIG" || die "could not restore existing config"
		trap - HUP INT TERM EXIT
		rm -rf "$tmpdir"
	else
		( cd "$ROOT_DIR" && tar -cf - . ) | ( cd / && tar -xf - ) || die "could not install files"
	fi

	chmod 755 /etc/init.d/podkopchik /usr/bin/podkopchikctl
	chmod 755 /usr/libexec/podkopchik/*.sh /usr/libexec/podkopchik/*.uc
	chmod 600 "$CONFIG"
}

install_i18n() {
	if [ -f "$BASE_DIR/i18n/ru/podkopchik.ru.lmo" ]; then
		mkdir -p /usr/lib/lua/luci/i18n
		cp "$BASE_DIR/i18n/ru/podkopchik.ru.lmo" /usr/lib/lua/luci/i18n/podkopchik.ru.lmo || die "could not install Russian translation catalog"
		chmod 644 /usr/lib/lua/luci/i18n/podkopchik.ru.lmo
	fi
}

restart_luci() {
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
	/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
}

start_service() {
	/etc/init.d/podkopchik enable >/dev/null 2>&1 || true
	/etc/init.d/podkopchik start >/dev/null 2>&1 || warn "service did not start; configure proxies and run /etc/init.d/podkopchik restart"
}

need_root
check_openwrt
install_deps
install_tree
install_i18n
restart_luci
start_service

echo "Podkopchik installed. No reboot was performed."
