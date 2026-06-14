#!/bin/sh

set -eu

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

update_case="$(make_case update)"
cat > "$update_case/rootfs/etc/config/podkopchik" <<'EOF'
config settings 'main'
	option user_marker 'preserve-me'
EOF
run_case "$update_case" 51200 env
grep -q "preserve-me" "$update_case/rootfs/etc/config/podkopchik"
grep -q "Mode: update" "$update_case/out"
grep -q "existing /etc/config/podkopchik preserved" "$update_case/out"

failure_case="$(make_case dependency-failure)"
if run_case "$failure_case" 51200 env PODKOPCHIK_TEST_FAIL_PKG=ip-full; then
	echo "FAIL: dependency failure did not stop installer"
	exit 1
fi
grep -q "could not install dependency: ip-full" "$failure_case/err"
grep -q "Command failed: opkg install ip-full" "$failure_case/err"
grep -q "kernel kmod compatibility" "$failure_case/err"

echo "installer workflow smoke OK"
