#!/bin/sh

# Shared package operations. Never use an unqualified system-wide upgrade.
pkg_detect() {
	local release_file release
	release_file="${PODKOPCHIK_OPENWRT_RELEASE:-${PODKOPCHIK_INSTALL_ROOT:-}/etc/openwrt_release}"
	release="$( ( . "$release_file"; printf '%s' "${DISTRIB_RELEASE:-}" ) 2>/dev/null || true)"
	case "$release" in
		24.10|24.10.*) PKG_MANAGER=opkg ;;
		25.12|25.12.*) PKG_MANAGER=apk ;;
		*)
			if command -v apk >/dev/null 2>&1 && ! command -v opkg >/dev/null 2>&1; then PKG_MANAGER=apk
			elif command -v opkg >/dev/null 2>&1 && ! command -v apk >/dev/null 2>&1; then PKG_MANAGER=opkg
			else echo 'podkopchik: cannot determine package manager for this OpenWrt release' >&2; return 1; fi
			;;
	esac
	command -v "$PKG_MANAGER" >/dev/null 2>&1 || {
		echo "podkopchik: $PKG_MANAGER is required for OpenWrt $release" >&2
		return 1
	}
}

pkg_installed() {
	case "$PKG_MANAGER" in
		opkg) opkg list-installed "$1" 2>/dev/null | awk -v name="$1" '$1==name && $2=="-" { found=1 } END { exit !found }' ;;
		apk) apk info --exists "$1" >/dev/null 2>&1 ;;
	esac
}

pkg_version() {
	case "$PKG_MANAGER" in
		opkg) opkg list-installed "$1" 2>/dev/null | awk -v name="$1" '$1==name && $2=="-" { print $3; exit }' ;;
		apk) apk query --from installed --match name --fields version --format json "$1" | jsonfilter -e '@[0].version' ;;
	esac
}

pkg_available() {
	case "$PKG_MANAGER" in
		opkg) opkg list "$1" | awk -v name="$1" '$1==name && $2=="-" { print $3; exit }' ;;
		apk) apk query --from repositories --match name --fields version --format json "$1" | jsonfilter -e '@[0].version' ;;
	esac
}

pkg_refresh() { "$PKG_MANAGER" update; }
pkg_install() {
	case "$PKG_MANAGER" in opkg) opkg install "$1" ;; apk) apk add "$1" ;; esac
}
pkg_upgrade() { "$PKG_MANAGER" upgrade "$1"; }
pkg_remove() {
	case "$PKG_MANAGER" in opkg) opkg remove "$1" ;; apk) apk del "$1" ;; esac
}

pkg_owns() {
	case "$PKG_MANAGER" in
		opkg) opkg files "$1" 2>/dev/null | grep -Fx "$2" >/dev/null ;;
		apk) apk info --contents "$1" 2>/dev/null | awk -v wanted="$2" '
			{ path=$0; if (substr(path,1,1)!="/") path="/"path; if (path==wanted) found=1 }
			END { exit !found }' ;;
	esac
}

pkg_check_signatures() {
	# apk verifies signatures by default. Never pass --allow-untrusted, nor use
	# user-provided global options which could disable its verification.
	[ "$PKG_MANAGER" = opkg ] || return 0
	awk '$1 == "option" && $2 == "check_signature" { enabled=(NF==2 || $3=="1" || $3 ~ /^#/) } END { exit !enabled }' \
		"${PODKOPCHIK_OPKG_CONF:-/etc/opkg.conf}"
}
