#!/bin/sh

set -eu

manager="${1:-opkg}"
tmp="tests/.tmp.install-workflow.$$"
rm -rf "$tmp"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT

make_mock_command() {
	dir="$1"
	name="$2"
	body="$3"
	printf '%s\n' "$body" > "$dir/$name"
	chmod +x "$dir/$name"
}

make_init_script() {
	rootfs="$1"
	name="$2"
	mkdir -p "$rootfs/etc/init.d"
	cat > "$rootfs/etc/init.d/$name" <<'EOF'
#!/bin/sh

case "${1:-}" in
	enabled|running) exit 1 ;;
	*) exit 0 ;;
esac
EOF
	chmod +x "$rootfs/etc/init.d/$name"
}

make_case() {
	name="$1"
	case_dir="$tmp/$name"
	rootfs="$case_dir/rootfs"
	bin="$case_dir/bin"

	mkdir -p \
		"$rootfs/etc/config" \
		"$rootfs/etc/init.d" \
		"$rootfs/overlay" \
		"$rootfs/tmp/sysinfo" \
		"$rootfs/usr/share/luci" \
		"$rootfs/usr/share/ucode/luci/i18n" \
		"$rootfs/usr/share/rpcd/acl.d" \
		"$rootfs/usr/lib/lua/luci/i18n" \
		"$rootfs/www/luci-static/resources" \
		"$bin"

	cat > "$rootfs/etc/openwrt_release" <<'EOF'
DISTRIB_ID='OpenWrt'
DISTRIB_RELEASE='24.10.4'
DISTRIB_REVISION='r0-test'
DISTRIB_TARGET='mediatek/filogic'
DISTRIB_ARCH='aarch64_cortex-a53'
EOF
	echo "GL.iNet Flint 2" > "$rootfs/tmp/sysinfo/model"
	if [ "$manager" = apk ]; then
		sed 's/24.10.4/25.12.6/' "$rootfs/etc/openwrt_release" > "$rootfs/etc/release.new"
		mv "$rootfs/etc/release.new" "$rootfs/etc/openwrt_release"
		echo "Xiaomi Redmi Router AX6000 (stock layout)" > "$rootfs/tmp/sysinfo/model"
	fi
	echo 'option check_signature' > "$case_dir/opkg.conf"

	make_init_script "$rootfs" rpcd
	make_init_script "$rootfs" uhttpd
	make_init_script "$rootfs" dnsmasq
	make_init_script "$rootfs" firewall

	: > "$case_dir/installed"
	: > "$case_dir/log"

	cat > "$bin/opkg" <<'EOF'
#!/bin/sh

cmd="${1:-}"
[ "$#" -gt 0 ] && shift

case "$cmd" in
	update)
		echo "opkg update" >> "$PODKOPCHIK_TEST_LOG"
		exit 0
		;;
	install)
		for pkg in "$@"; do
			echo "opkg install $pkg" >> "$PODKOPCHIK_TEST_LOG"
			if [ "${PODKOPCHIK_TEST_FAIL_PKG:-}" = "$pkg" ]; then
				exit 1
			fi
			grep -qx "$pkg" "$PODKOPCHIK_TEST_INSTALLED" 2>/dev/null || echo "$pkg" >> "$PODKOPCHIK_TEST_INSTALLED"
		done
		exit 0
		;;
	remove)
		echo "opkg remove $1" >> "$PODKOPCHIK_TEST_LOG"
		rm -f "$PODKOPCHIK_INSTALL_ROOT/etc/config/podkopchik"
		[ "${PODKOPCHIK_TEST_FAIL_REMOVE:-0}" != 1 ] || exit 1
		grep -vx "$1" "$PODKOPCHIK_TEST_INSTALLED" > "$PODKOPCHIK_TEST_INSTALLED.new"
		mv "$PODKOPCHIK_TEST_INSTALLED.new" "$PODKOPCHIK_TEST_INSTALLED"
		exit 0
		;;
	list-installed)
		pkg="${1:-}"
		if [ -n "$pkg" ] && grep -qx "$pkg" "$PODKOPCHIK_TEST_INSTALLED" 2>/dev/null; then
			echo "$pkg - 1"
		fi
		exit 0
		;;
	print-architecture)
		echo "aarch64_cortex-a53 10"
		echo "all 1"
		exit 0
		;;
	*)
		exit 0
		;;
esac
EOF
	chmod +x "$bin/opkg"
	if [ "$manager" = apk ]; then
		mv "$bin/opkg" "$bin/opkg-mock"
		cat > "$bin/apk" <<'EOF'
#!/bin/sh
echo "apk $*" >> "$PODKOPCHIK_TEST_LOG"
case "$1" in
 update) exec "$PODKOPCHIK_TEST_BIN/opkg-mock" update ;;
 add) shift; exec "$PODKOPCHIK_TEST_BIN/opkg-mock" install "$@" ;;
 del) shift; exec "$PODKOPCHIK_TEST_BIN/opkg-mock" remove "$@" ;;
 info) [ "$2" = --exists ] || exit 2; grep -qx "$3" "$PODKOPCHIK_TEST_INSTALLED" ;;
 *) exit 2 ;;
esac
EOF
		chmod +x "$bin/apk"
	fi

	cat > "$bin/ip" <<'EOF'
#!/bin/sh

if [ "${1:-}" = "-V" ]; then
	if grep -qx "ip-full" "$PODKOPCHIK_TEST_INSTALLED" 2>/dev/null; then
		echo "ip utility, iproute2-6.11.0"
	else
		echo "BusyBox v1.36.1 (OpenWrt) multi-call binary."
	fi
	exit 0
fi

exit 0
EOF
	chmod +x "$bin/ip"

	for cmd in nft ucode xray curl wget jsonfilter rpcd uhttpd dnsmasq; do
		make_mock_command "$bin" "$cmd" '#!/bin/sh
exit 0'
	done

	echo "$case_dir"
}

run_case() {
	case_dir="$1"
	free_kb="$2"
	shift 2
	rootfs="$case_dir/rootfs"
	bin="$case_dir/bin"
	out="$case_dir/out"
	err="$case_dir/err"

	PATH="$bin:$PATH" \
	PODKOPCHIK_TEST_LOG="$case_dir/log" \
	PODKOPCHIK_TEST_INSTALLED="$case_dir/installed" \
	PODKOPCHIK_TEST_BIN="$bin" \
	PODKOPCHIK_OPKG_CONF="$case_dir/opkg.conf" \
	PODKOPCHIK_INSTALL_ROOT="$rootfs" \
	PODKOPCHIK_INSTALL_ASSUME_ROOT=1 \
	PODKOPCHIK_INSTALL_OVERLAY_FREE_KB="$free_kb" \
	"$@" sh install.sh > "$out" 2> "$err"
}

success_case="$(make_case success)"
run_case "$success_case" 51200 env
grep -q "opkg install ip-full" "$success_case/log"
! grep -q "Missing required dependency: ip-full" "$success_case/err"
test -x "$success_case/rootfs/usr/bin/podkopchikctl"
test -x "$success_case/rootfs/usr/libexec/rpcd/podkopchik.awg"
test -f "$success_case/rootfs/lib/upgrade/keep.d/podkopchik-awg"
test -f "$success_case/rootfs/usr/share/ucode/luci/i18n/podkopchik.ru.lmo"
test -f "$success_case/rootfs/usr/lib/lua/luci/i18n/podkopchik.ru.lmo"
grep -q "default /etc/config/podkopchik created" "$success_case/out"
update_line="$(grep -n "opkg update" "$success_case/log" | cut -d: -f1 | head -n 1)"
install_line="$(grep -n "opkg install" "$success_case/log" | cut -d: -f1 | head -n 1)"
[ "$update_line" -lt "$install_line" ]

low_space_case="$(make_case low-space)"
if run_case "$low_space_case" 10240 env; then
	echo "FAIL: low overlay space did not stop installer"
	exit 1
fi
grep -q "Недостаточно места в /overlay" "$low_space_case/err"
! grep -q "opkg update" "$low_space_case/log"

conflict_case="$(make_case conflict)"
touch "$conflict_case/rootfs/etc/config/podkop"
if run_case "$conflict_case" 51200 env; then
	echo "FAIL: conflict did not stop installer"
	exit 1
fi
grep -q "conflicting proxy applications were found" "$conflict_case/err"
grep -q "config: /etc/config/podkop" "$conflict_case/err"
! grep -q "opkg update" "$conflict_case/log"

xray_disabled_case="$(make_case xray-disabled)"
cat > "$xray_disabled_case/rootfs/etc/config/xray" <<'EOF'
config xray 'enabled'
	option enabled '0'
EOF
make_init_script "$xray_disabled_case/rootfs" xray
run_case "$xray_disabled_case" 51200 env
grep -q "Podkopchik install summary" "$xray_disabled_case/out"

xray_enabled_case="$(make_case xray-enabled)"
cat > "$xray_enabled_case/rootfs/etc/config/xray" <<'EOF'
config xray 'enabled'
	option enabled '1'
EOF
make_init_script "$xray_enabled_case/rootfs" xray
if run_case "$xray_enabled_case" 51200 env; then
	echo "FAIL: enabled standalone xray did not stop installer"
	exit 1
fi
grep -q "service: xray" "$xray_enabled_case/err"
! grep -q "opkg update" "$xray_enabled_case/log"

update_case="$(make_case update)"
cat > "$update_case/rootfs/etc/config/podkopchik" <<'EOF'
config settings 'main'
	option user_marker 'preserve-me'
EOF
mkdir -p "$update_case/rootfs/usr/libexec/podkopchik-core"
printf '%s\n' official > "$update_case/rootfs/usr/libexec/podkopchik-core/selected"
printf '%s\n' keep-official-binary > "$update_case/rootfs/usr/libexec/podkopchik-core/xray"
mkdir -p "$update_case/rootfs/etc/podkopchik/awg"
chmod 700 "$update_case/rootfs/etc/podkopchik/awg"
printf '%s\n' synthetic-awg-storage-marker > "$update_case/rootfs/etc/podkopchik/awg/profile.conf"
chmod 600 "$update_case/rootfs/etc/podkopchik/awg/profile.conf"
run_case "$update_case" 51200 env
grep -q "preserve-me" "$update_case/rootfs/etc/config/podkopchik"
grep -q "Mode: update" "$update_case/out"
grep -q "existing /etc/config/podkopchik preserved" "$update_case/out"
cp "$update_case/rootfs/etc/config/podkopchik" "$update_case/config.expected"
run_case "$update_case" 51200 env
cmp "$update_case/config.expected" "$update_case/rootfs/etc/config/podkopchik"
grep -qx official "$update_case/rootfs/usr/libexec/podkopchik-core/selected"
grep -qx keep-official-binary "$update_case/rootfs/usr/libexec/podkopchik-core/xray"
grep -qx synthetic-awg-storage-marker "$update_case/rootfs/etc/podkopchik/awg/profile.conf"
test "$(find "$update_case/rootfs/etc/podkopchik/awg" -type f -perm 600 | wc -l | tr -d ' ')" = 1

failure_case="$(make_case dependency-failure)"
if run_case "$failure_case" 51200 env PODKOPCHIK_TEST_FAIL_PKG=ip-full; then
	echo "FAIL: dependency failure did not stop installer"
	exit 1
fi
grep -q "could not install dependency: ip-full" "$failure_case/err"
if [ "$manager" = apk ]; then
	grep -q "Command failed: apk add ip-full" "$failure_case/err"
else
	grep -q "Command failed: opkg install ip-full" "$failure_case/err"
fi
grep -q "kernel kmod compatibility" "$failure_case/err"

grep -q "Package manager: $manager" "$success_case/out"
if [ "$manager" = apk ]; then grep -q '^apk add ip-full$' "$success_case/log"; fi

# The raw single-file entry point must bootstrap packages.sh before using it.
raw_case="$(make_case raw-bootstrap)"
mkdir -p "$raw_case/source/Podkopchik" "$raw_case/entry"
cp install.sh "$raw_case/entry/install.sh"
cp -R root i18n "$raw_case/source/Podkopchik/"
tar -czf "$raw_case/archive.tar.gz" -C "$raw_case/source" Podkopchik
cat > "$raw_case/bin/curl" <<'EOF'
#!/bin/sh
previous=''
for argument in "$@"; do
 if [ "$previous" = -o ]; then cp "$PODKOPCHIK_TEST_ARCHIVE" "$argument"; exit; fi
 previous="$argument"
done
exit 1
EOF
chmod +x "$raw_case/bin/curl"
PATH="$raw_case/bin:$PATH" PODKOPCHIK_TEST_BIN="$raw_case/bin" \
PODKOPCHIK_TEST_ARCHIVE="$raw_case/archive.tar.gz" \
PODKOPCHIK_TEST_LOG="$raw_case/log" PODKOPCHIK_TEST_INSTALLED="$raw_case/installed" \
PODKOPCHIK_INSTALL_ROOT="$raw_case/rootfs" PODKOPCHIK_INSTALL_ASSUME_ROOT=1 \
PODKOPCHIK_INSTALL_OVERLAY_FREE_KB=51200 PODKOPCHIK_OPKG_CONF="$raw_case/opkg.conf" \
PODKOPCHIK_INSTALL_WORK_DIR="$raw_case/work" sh "$raw_case/entry/install.sh" > "$raw_case/out" 2> "$raw_case/err"
test -f "$raw_case/rootfs/usr/libexec/podkopchik/packages.sh"
grep -q "Package manager: $manager" "$raw_case/out"

uninstall_case() {
	case_dir="$1"
	shift
	PATH="$case_dir/bin:$PATH" \
	PODKOPCHIK_TEST_BIN="$case_dir/bin" \
	PODKOPCHIK_TEST_LOG="$case_dir/log" \
	PODKOPCHIK_TEST_INSTALLED="$case_dir/installed" \
	PODKOPCHIK_INSTALL_ROOT="$case_dir/rootfs" \
	PODKOPCHIK_INSTALL_ASSUME_ROOT=1 \
	"$@" sh uninstall.sh > "$case_dir/uninstall.out" 2> "$case_dir/uninstall.err"
}
echo luci-app-podkopchik >> "$update_case/installed"
if uninstall_case "$update_case" env PODKOPCHIK_TEST_FAIL_REMOVE=1; then
	echo 'FAIL: package removal failure was ignored'; exit 1
fi
cmp "$update_case/config.expected" "$update_case/rootfs/etc/config/podkopchik"
uninstall_case "$update_case" env
cmp "$update_case/config.expected" "$update_case/rootfs/etc/config/podkopchik"
grep -qx official "$update_case/rootfs/usr/libexec/podkopchik-core/selected"
test ! -e "$update_case/rootfs/usr/bin/podkopchikctl"
test ! -e "$update_case/rootfs/usr/libexec/rpcd/podkopchik.awg"
test ! -e "$update_case/rootfs/lib/upgrade/keep.d/podkopchik-awg"
grep -qx synthetic-awg-storage-marker "$update_case/rootfs/etc/podkopchik/awg/profile.conf"
uninstall_case "$update_case" env
mkdir -p "$success_case/rootfs/etc/podkopchik/awg"
printf '%s\n' synthetic-awg-storage-marker > "$success_case/rootfs/etc/podkopchik/awg/profile.conf"
PATH="$success_case/bin:$PATH" PODKOPCHIK_TEST_BIN="$success_case/bin" \
PODKOPCHIK_TEST_LOG="$success_case/log" PODKOPCHIK_TEST_INSTALLED="$success_case/installed" \
PODKOPCHIK_INSTALL_ROOT="$success_case/rootfs" PODKOPCHIK_INSTALL_ASSUME_ROOT=1 sh uninstall.sh --purge > /dev/null
test ! -e "$success_case/rootfs/etc/config/podkopchik"
test ! -e "$success_case/rootfs/etc/podkopchik/awg"
echo "installer workflow smoke OK ($manager)"
