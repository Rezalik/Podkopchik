#!/bin/sh

set -u

APP="podkopchik"
BASE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR="$BASE_DIR/root"
DESTDIR="${PODKOPCHIK_INSTALL_ROOT:-}"
CONFIG="/etc/config/$APP"
CONFIG_PATH="${DESTDIR}${CONFIG}"
WORK_DIR="${PODKOPCHIK_INSTALL_WORK_DIR:-/tmp/podkopchik-install.$$}"
CONFIG_BACKUP="$WORK_DIR/podkopchik.config"
HAVE_CONFIG_BACKUP=0
INSTALL_FAILED=0
INSTALL_MODE="fresh install"
OVERLAY_FREE_MB="unknown"
HARD_MIN_OVERLAY_MB=15
RECOMMENDED_OVERLAY_MB=25
INSTALLED_DEPS=""
SKIPPED_DEPS=""
CONFLICTS_FOUND=""

DEPENDENCIES="
luci-base
rpcd
rpcd-mod-luci
uhttpd
ucode
ucode-mod-fs
ucode-mod-uci
ucode-mod-ubus
curl
ca-bundle
jsonfilter
nftables-json
kmod-nft-tproxy
firewall4
ip-full
dnsmasq
xray-core
"

CONFLICT_PACKAGES="
podkop
luci-app-podkop
sing-box
passwall
luci-app-passwall
openclash
luci-app-openclash
mihomo
clash
v2rayA
v2raya
"

CONFLICT_SERVICES="
podkop
sing-box
passwall
openclash
mihomo
clash
v2rayA
v2raya
xray
"

CONFLICT_CONFIGS="
/etc/config/podkop
/etc/config/sing-box
/etc/config/passwall
/etc/config/openclash
/etc/config/mihomo
/etc/config/clash
/etc/config/v2rayA
/etc/config/v2raya
/etc/config/xray
"

path() {
	printf '%s%s' "$DESTDIR" "$1"
}

info() {
	echo "podkopchik install: $*"
}

die() {
	INSTALL_FAILED=1
	echo "podkopchik install: $*" >&2
	exit 1
}

warn() {
	echo "podkopchik install: warning: $*" >&2
}

cleanup() {
	if [ "$INSTALL_FAILED" = "1" ] && [ "$HAVE_CONFIG_BACKUP" = "1" ] && [ -f "$CONFIG_BACKUP" ]; then
		cp "$CONFIG_BACKUP" "$CONFIG_PATH" >/dev/null 2>&1 || true
	fi
	rm -rf "$WORK_DIR"
}

trap cleanup EXIT
trap 'INSTALL_FAILED=1; cleanup; exit 1' HUP INT TERM

need_root() {
	[ "${PODKOPCHIK_INSTALL_ASSUME_ROOT:-0}" = "1" ] && return 0
	[ "$(id -u)" = "0" ] || die "run as root on OpenWrt"
}

read_first_line() {
	file="$(path "$1")"
	[ -r "$file" ] && sed -n '1p' "$file" 2>/dev/null || true
}

load_openwrt_release() {
	release_file="$(path /etc/openwrt_release)"
	[ -r "$release_file" ] || die "this installer is for OpenWrt"
	# shellcheck disable=SC1090
	. "$release_file"
	case "${DISTRIB_RELEASE:-}" in
		24.10*|25.*|26.*) ;;
		*) warn "OpenWrt ${DISTRIB_RELEASE:-unknown} detected; Podkopchik targets OpenWrt 24.10+" ;;
	esac
}

package_installed() {
	pkg="$1"
	opkg list-installed "$pkg" 2>/dev/null | grep -q "^$pkg[[:space:]]*-"
}

dependency_present() {
	pkg="$1"
	case "$pkg" in
		dnsmasq)
			[ -x "$(path /etc/init.d/dnsmasq)" ] || command -v dnsmasq >/dev/null 2>&1 || package_installed "$pkg"
			;;
		firewall4)
			[ -x "$(path /etc/init.d/firewall)" ] || package_installed "$pkg"
			;;
		rpcd)
			[ -x "$(path /etc/init.d/rpcd)" ] || command -v rpcd >/dev/null 2>&1 || package_installed "$pkg"
			;;
		uhttpd)
			[ -x "$(path /etc/init.d/uhttpd)" ] || command -v uhttpd >/dev/null 2>&1 || package_installed "$pkg"
			;;
		*)
			package_installed "$pkg"
			;;
	esac
}

overlay_free_kb() {
	if [ -n "${PODKOPCHIK_INSTALL_OVERLAY_FREE_KB:-}" ]; then
		echo "$PODKOPCHIK_INSTALL_OVERLAY_FREE_KB"
		return
	fi

	df -k /overlay 2>/dev/null | awk 'NR == 2 { print $4 }'
}

check_overlay_space() {
	[ -d "$(path /overlay)" ] || die "/overlay is not available"

	free_kb="$(overlay_free_kb)"
	case "$free_kb" in
		''|*[!0-9]*) die "could not determine free space in /overlay" ;;
	esac

	OVERLAY_FREE_MB=$((free_kb / 1024))
	if [ "$OVERLAY_FREE_MB" -lt "$HARD_MIN_OVERLAY_MB" ]; then
		die "Недостаточно места в /overlay. Свободно ${OVERLAY_FREE_MB} MB, нужно минимум ${HARD_MIN_OVERLAY_MB} MB. Удалите старые пакеты или освободите место."
	fi

	if [ "$OVERLAY_FREE_MB" -lt "$RECOMMENDED_OVERLAY_MB" ]; then
		warn "only ${OVERLAY_FREE_MB} MB free in /overlay; ${RECOMMENDED_OVERLAY_MB} MB is recommended"
	fi
}

component_state() {
	name="$1"
	check="$2"
	if eval "$check"; then
		printf '%s: present\n' "$name"
	else
		printf '%s: missing, will install or verify\n' "$name"
	fi
}

print_system_report() {
	model="$(read_first_line /tmp/sysinfo/model)"
	[ -n "$model" ] || model="unknown"
	openwrt="${DISTRIB_RELEASE:-unknown}"
	target="${DISTRIB_TARGET:-unknown}"
	arch="${DISTRIB_ARCH:-unknown}"
	kernel="$(uname -r 2>/dev/null || echo unknown)"

	if [ -f "$CONFIG_PATH" ]; then
		INSTALL_MODE="update"
	else
		INSTALL_MODE="fresh install"
	fi

	echo "Podkopchik installer preflight"
	echo "  Model: $model"
	echo "  OpenWrt version: $openwrt"
	echo "  Target: $target"
	echo "  Arch: $arch"
	echo "  Kernel: $kernel"
	echo "  Overlay free: ${OVERLAY_FREE_MB} MB"
	echo "  Install mode: $INSTALL_MODE"
	component_state "  LuCI" "[ -d \"$(path /usr/share/luci)\" ]"
	component_state "  rpcd" "[ -x \"$(path /etc/init.d/rpcd)\" ] || command -v rpcd >/dev/null 2>&1"
	component_state "  uhttpd" "[ -x \"$(path /etc/init.d/uhttpd)\" ] || command -v uhttpd >/dev/null 2>&1"
	component_state "  nft" "command -v nft >/dev/null 2>&1"
	component_state "  firewall4" "[ -x \"$(path /etc/init.d/firewall)\" ] || package_installed firewall4"
	component_state "  dnsmasq" "[ -x \"$(path /etc/init.d/dnsmasq)\" ] || command -v dnsmasq >/dev/null 2>&1"
}

add_conflict() {
	item="$1"
	if [ -z "$CONFLICTS_FOUND" ]; then
		CONFLICTS_FOUND="$item"
	else
		CONFLICTS_FOUND="$CONFLICTS_FOUND
$item"
	fi
}

service_active_or_installed() {
	svc="$1"
	init="$(path "/etc/init.d/$svc")"
	[ -x "$init" ] || return 1
	"$init" enabled >/dev/null 2>&1 && return 0
	"$init" running >/dev/null 2>&1 && return 0
	[ "$svc" = "xray" ] && return 0
	return 1
}

check_conflicts() {
	for pkg in $CONFLICT_PACKAGES; do
		if package_installed "$pkg"; then
			add_conflict "package: $pkg"
		fi
	done

	for svc in $CONFLICT_SERVICES; do
		if service_active_or_installed "$svc"; then
			add_conflict "service: $svc"
		fi
	done

	for cfg in $CONFLICT_CONFIGS; do
		if [ -e "$(path "$cfg")" ]; then
			add_conflict "config: $cfg"
		fi
	done

	if [ -n "$CONFLICTS_FOUND" ]; then
		echo "podkopchik install: conflicting proxy applications were found:" >&2
		printf '%s\n' "$CONFLICTS_FOUND" | sed 's/^/  - /' >&2
		die "stop or remove these services manually, then rerun the installer. Existing /etc/config/podkopchik is treated as update mode and is not a conflict."
	fi

	info "conflict check passed"
}

run_opkg_update() {
	info "running opkg update"
	opkg update || die "opkg update failed. Check internet access, OpenWrt repositories, DNS, and free space."
}

install_dependency() {
	pkg="$1"
	if dependency_present "$pkg"; then
		info "Dependency already installed: $pkg"
		SKIPPED_DEPS="$SKIPPED_DEPS $pkg"
		return
	fi

	info "Installing dependency: $pkg"
	if ! opkg install "$pkg"; then
		die "could not install dependency: $pkg. Command failed: opkg install $pkg. Hint: check OpenWrt repositories, internet access, free /overlay space, and kernel kmod compatibility."
	fi
	INSTALLED_DEPS="$INSTALLED_DEPS $pkg"
}

install_deps() {
	run_opkg_update
	for pkg in $DEPENDENCIES; do
		install_dependency "$pkg"
	done
}

validate_ip_full() {
	if ! package_installed ip-full; then
		die "Missing required dependency: ip-full. BusyBox ip is not sufficient for fwmark policy routing."
	fi

	case "$(ip -V 2>&1 || true)" in
		*iproute2*) ;;
		*) die "Missing required dependency: ip-full. BusyBox ip is not sufficient for fwmark policy routing." ;;
	esac
}

validate_dependencies() {
	validate_ip_full
	command -v nft >/dev/null 2>&1 || die "nft command not found after dependency installation"
	command -v ucode >/dev/null 2>&1 || die "ucode command not found after dependency installation"
	command -v xray >/dev/null 2>&1 || command -v xray-core >/dev/null 2>&1 || die "xray command not found after dependency installation"
	command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || die "curl or wget is required for downloads"
	[ -d "$(path /usr/share/luci)" ] || die "LuCI path not found after dependency installation: /usr/share/luci"
	[ -x "$(path /etc/init.d/rpcd)" ] || die "rpcd init script not found after dependency installation"
	[ -x "$(path /etc/init.d/uhttpd)" ] || die "uhttpd init script not found after dependency installation"
	info "dependency validation passed"
}

download_file() {
	url="$1"
	out="$2"
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "$url" -o "$out"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$out" "$url"
	else
		return 1
	fi
}

ensure_payload() {
	if [ -d "$ROOT_DIR" ] && [ -f "$ROOT_DIR/usr/bin/podkopchikctl" ]; then
		return
	fi

	repo="${PODKOPCHIK_INSTALL_REPO:-rezalik/Podkopchik}"
	branch="${PODKOPCHIK_INSTALL_BRANCH:-main}"
	archive_url="${PODKOPCHIK_INSTALL_ARCHIVE_URL:-https://github.com/$repo/archive/refs/heads/$branch.tar.gz}"
	archive="$WORK_DIR/podkopchik-source.tar.gz"
	extract_dir="$WORK_DIR/source"

	info "root payload not found next to installer; downloading $archive_url"
	mkdir -p "$extract_dir" || die "could not create temporary source directory"
	download_file "$archive_url" "$archive" || die "could not download Podkopchik source archive"
	tar -xzf "$archive" -C "$extract_dir" || die "could not extract Podkopchik source archive"

	payload_ctl="$(find "$extract_dir" -path '*/root/usr/bin/podkopchikctl' -type f | head -n 1)"
	[ -n "$payload_ctl" ] || die "downloaded archive does not contain Podkopchik root payload"
	BASE_DIR="${payload_ctl%/root/usr/bin/podkopchikctl}"
	ROOT_DIR="$BASE_DIR/root"
}

install_payload_dir() {
	payload="$1"
	dest_root="${DESTDIR:-/}"
	( cd "$payload" && tar -cf - . ) | ( cd "$dest_root" && tar -xf - ) || die "could not install files"
}

install_tree() {
	[ -d "$ROOT_DIR" ] || die "missing root payload: $ROOT_DIR"
	mkdir -p "$(path /etc/podkopchik)" "$(path /tmp/podkopchik)" || die "could not create Podkopchik directories"

	if [ -f "$CONFIG_PATH" ]; then
		stage="$WORK_DIR/payload"
		mkdir -p "$stage" || die "could not create temporary install directory"
		cp "$CONFIG_PATH" "$CONFIG_BACKUP" || die "could not preserve existing config"
		HAVE_CONFIG_BACKUP=1
		( cd "$ROOT_DIR" && tar -cf - . ) | ( cd "$stage" && tar -xf - ) || die "could not stage files"
		rm -f "$stage/etc/config/podkopchik"
		install_payload_dir "$stage"
		cp "$CONFIG_BACKUP" "$CONFIG_PATH" || die "could not restore existing config"
		info "existing /etc/config/podkopchik preserved"
	else
		install_payload_dir "$ROOT_DIR"
		info "default /etc/config/podkopchik created"
	fi

	chmod 755 "$(path /etc/init.d/podkopchik)" "$(path /usr/bin/podkopchikctl)" || die "could not set executable permissions"
	chmod 755 "$(path /usr/libexec/podkopchik)"/*.sh "$(path /usr/libexec/podkopchik)"/*.uc || die "could not set helper permissions"
	[ -f "$CONFIG_PATH" ] && chmod 600 "$CONFIG_PATH"
}

install_i18n() {
	if [ -f "$BASE_DIR/i18n/ru/podkopchik.ru.lmo" ]; then
		mkdir -p "$(path /usr/lib/lua/luci/i18n)" || die "could not create LuCI i18n directory"
		cp "$BASE_DIR/i18n/ru/podkopchik.ru.lmo" "$(path /usr/lib/lua/luci/i18n/podkopchik.ru.lmo)" || die "could not install Russian translation catalog"
		chmod 644 "$(path /usr/lib/lua/luci/i18n/podkopchik.ru.lmo)"
	fi
}

restart_luci() {
	[ -n "$DESTDIR" ] && {
		info "test root detected; skipping rpcd/uhttpd restart"
		return
	}
	/etc/init.d/rpcd restart >/dev/null 2>&1 || warn "could not restart rpcd"
	/etc/init.d/uhttpd restart >/dev/null 2>&1 || warn "could not restart uhttpd"
	rm -rf /tmp/luci-* 2>/dev/null || true
}

start_service() {
	[ -n "$DESTDIR" ] && {
		info "test root detected; skipping service enable/start"
		return
	}
	/etc/init.d/podkopchik enable >/dev/null 2>&1 || warn "could not enable podkopchik service"
	/etc/init.d/podkopchik start >/dev/null 2>&1 || warn "service did not start; configure proxies and run /etc/init.d/podkopchik restart"
}

post_install_checks() {
	[ -n "$DESTDIR" ] && {
		info "test root detected; skipping post-install runtime checks"
		return
	}
	if podkopchikctl validate; then
		info "podkopchikctl validate: PASS"
	else
		warn "podkopchikctl validate failed; configure proxy links and check Xray before applying routing"
	fi
	podkopchikctl status || warn "podkopchikctl status failed"
}

print_summary() {
	echo
	echo "Podkopchik install summary"
	echo "  Mode: $INSTALL_MODE"
	echo "  OpenWrt: ${DISTRIB_RELEASE:-unknown}"
	echo "  Model: $(read_first_line /tmp/sysinfo/model || true)"
	echo "  Dependencies installed:${INSTALLED_DEPS:- none}"
	echo "  Dependencies already present:${SKIPPED_DEPS:- none}"
	echo "  Conflicts checked: yes"
	echo "  Files installed: yes"
	if [ "$INSTALL_MODE" = "update" ]; then
		echo "  Config: preserved existing /etc/config/podkopchik"
	else
		echo "  Config: created default /etc/config/podkopchik"
	fi
	echo
	echo "Next steps:"
	echo "  1. Open LuCI: Services -> Podkopchik."
	echo "  2. Add a VLESS proxy link and choose one main proxy."
	echo "  3. Optional: enable FakeDNS if your app routing needs it."
	echo "  4. Optional: add Presets for Telegram, YouTube, X / Twitter, and other services."
	echo "  5. Click Save & Apply."
	echo
	echo "No reboot was performed."
}

need_root
command -v opkg >/dev/null 2>&1 || die "opkg is required"
load_openwrt_release
check_overlay_space
print_system_report
check_conflicts
install_deps
validate_dependencies
ensure_payload
install_tree
install_i18n
restart_luci
start_service
post_install_checks
print_summary
