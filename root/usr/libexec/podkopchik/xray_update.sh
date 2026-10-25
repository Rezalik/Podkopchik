#!/bin/sh

set -eu
umask 077

LIB="${PODKOPCHIK_LIB:-/usr/libexec/podkopchik}"
TMP_DIR="${PODKOPCHIK_TMP_DIR:-/tmp/podkopchik}"
CONFIG_DIR="${PODKOPCHIK_CONFIG_DIR:-/etc/podkopchik}"
CONFIG="$CONFIG_DIR/config.json"
PROC_DIR="${PODKOPCHIK_PROC_DIR:-/proc}"
INIT="${PODKOPCHIK_INIT:-/etc/init.d/podkopchik}"
. "$LIB/xray.sh"

fail() { echo "podkopchik Xray: $*" >&2; exit 1; }
field() { sed -n "s/^$2=//p" "$1" | head -n 1; }
version() { "$1" version 2>/dev/null | awk 'NR == 1 && $1 == "Xray" { print $2 }'; }
fetch() { curl --proto '=https' --proto-redir '=https' -fsSL --connect-timeout 10 --max-time 120 --max-filesize 67108864 "$1" -o "$2"; }
number() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }

architecture() {
	case "$(uname -m)" in
		aarch64|arm64) echo linux-arm64-v8a ;;
		x86_64) echo linux-64 ;;
		*) fail "unsupported architecture for managed Xray update" ;;
	esac
}

free_space() {
	available="$(df -Pk "$1" | awk 'END { print $4 }')"
	number "$available" && [ "$available" -ge "$2" ] || fail "insufficient free space in $1 (need $2 KiB)"
}

package_latest() {
	opkg list xray-core | awk '$1 == "xray-core" && $2 == "-" { print $3; exit }'
}

check_update() {
	case "$channel" in package|official) ;; *) fail "source must be package or official" ;; esac
	arch="$(architecture)"
	check_file="$TMP_DIR/xray-$channel.check"
	check_tmp="$(mktemp "$TMP_DIR/xray-check.XXXXXX")"
	if [ "$channel" = package ]; then
		if ! awk '$1 == "option" && $2 == "check_signature" { enabled=(NF==2 || $3=="1" || $3 ~ /^#/) } END { exit !enabled }' "${PODKOPCHIK_OPKG_CONF:-/etc/opkg.conf}"; then
			rm -f "$check_tmp"; fail "opkg signature checking must be enabled before a package update"
		fi
		if ! opkg update >&2; then rm -f "$check_tmp"; fail "opkg feed refresh failed"; fi
		latest="$(package_latest)"
		[ -n "$latest" ] || { rm -f "$check_tmp"; fail "xray-core is missing from configured opkg feeds"; }
		printf 'latest=%s\n' "$latest" > "$check_tmp"
	else
		metadata="$(mktemp "$TMP_DIR/xray-release.XXXXXX")"
		if ! fetch https://api.github.com/repos/XTLS/Xray-core/releases/latest "$metadata"; then
			rm -f "$metadata" "$check_tmp"; fail "could not fetch official Xray release"
		fi
		latest="$(jsonfilter -q -i "$metadata" -e '@.tag_name')"
		case "$latest" in v[0-9]* ) ;; *) rm -f "$metadata" "$check_tmp"; fail "invalid release tag" ;; esac
		case "$latest" in *[!a-zA-Z0-9._-]*) rm -f "$metadata" "$check_tmp"; fail "invalid release tag" ;; esac
		asset="Xray-$arch.zip"
		i=0; asset_size=""; digest=""
		while [ "$i" -lt 256 ]; do
			name="$(jsonfilter -q -i "$metadata" -e "@.assets[$i].name" 2>/dev/null || true)"
			[ -n "$name" ] || break
			if [ "$name" = "$asset" ]; then
				asset_size="$(jsonfilter -q -i "$metadata" -e "@.assets[$i].size")"
				digest="$(jsonfilter -q -i "$metadata" -e "@.assets[$i].digest" 2>/dev/null || true)"
				break
			fi
			i=$((i + 1))
		done
		rm -f "$metadata"
		number "$asset_size" && [ "$asset_size" -gt 0 ] && [ "$asset_size" -le 67108864 ] || {
			rm -f "$check_tmp"; fail "matching official Linux asset missing or too large"
		}
		printf 'latest=%s\narchive_url=https://github.com/XTLS/Xray-core/releases/download/%s/%s\nsize=%s\ndigest=%s\n' \
			"$latest" "$latest" "$asset" "$asset_size" "$digest" > "$check_tmp"
	fi
	printf 'channel=%s\narchitecture=%s\nchecked_at=%s\n' "$channel" "$arch" "$(date +%s)" >> "$check_tmp"
	mv "$check_tmp" "$check_file"
}

status() {
	bin="$(xray_bin || true)"
	installed=""
	[ -z "$bin" ] || installed="$(version "$bin")"
	installed_source="$(xray_source)"
	if [ "$installed_source" = package ] && ! opkg files xray-core 2>/dev/null | grep -Fx "$bin" >/dev/null; then
		installed_source=system
	fi
	printf 'installed=%s\nsource=%s\narchitecture=%s\n' "${installed:-unknown}" "$installed_source" "$(uname -m)"
	for source in package official; do
		file="$TMP_DIR/xray-$source.check"
		if [ -s "$file" ]; then
			printf '%s_latest=%s\n%s_checked_at=%s\n' "$source" "$(field "$file" latest)" "$source" "$(field "$file" checked_at)"
		fi
	done
	if [ -d "$TMP_DIR/xray-update.lock" ] && [ "$(cat "$TMP_DIR/xray-update.lock/pid" 2>/dev/null || true)" != "$$" ]; then echo status=updating
	elif [ -s "$CORE_DIR/last-status" ]; then cat "$CORE_DIR/last-status"
	else echo status=not_checked; fi
	if [ -f "$TMP_DIR/xray-job.state" ]; then
		cat "$TMP_DIR/xray-job.state"
		if [ "$(field "$TMP_DIR/xray-job.state" job_status)" = running ]; then
			started="$(field "$TMP_DIR/xray-job.state" job_started)"
			owner="$(cat "$TMP_DIR/xray-job.lock/pid" 2>/dev/null || true)"
			alive=0
			if number "$owner" && [ "$owner" -gt 1 ] && kill -0 "$owner" 2>/dev/null; then alive=1; fi
			if number "$started" && [ "$(date +%s)" -gt "$((started + 5))" ] && [ "$alive" = 0 ]; then
				echo 'job_status=failed'
				echo 'job_message=Xray worker was interrupted; inspect update locks and the retained previous binary.'
			fi
		fi
	fi
}

lock_update() {
	mkdir "$TMP_DIR/xray-update.lock" 2>/dev/null || fail "another Xray update is running"
	have_update=1
	printf '%s\n' "$$" > "$TMP_DIR/xray-update.lock/pid"
	mkdir "$TMP_DIR/config-apply.lock" 2>/dev/null || fail "config apply is running; retry later"
	have_apply=1
	mkdir "$TMP_DIR/health-check.lock" 2>/dev/null || fail "health check is running; retry after it finishes"
	have_health=1
	printf '%s\n' "$$" > "$TMP_DIR/health-check.lock/pid"
}

select_source() {
	printf '%s\n' "$1" > "$CORE_DIR/selected.new"
	mv "$CORE_DIR/selected.new" "$CORE_DIR/selected"
}

main_pid() {
	main_count=0; selected_pid=""
	for proc in "$PROC_DIR"/[0-9]*; do
		[ -r "$proc/cmdline" ] || continue
		cmd="$(tr '\000' ' ' < "$proc/cmdline")"
		case "$cmd" in
			*" run -config $CONFIG "|*" run -config $CONFIG")
				main_count=$((main_count + 1))
				[ "$(readlink "$proc/exe")" != "$(xray_bin)" ] || selected_pid="${proc##*/}"
				;;
		esac
	done
	[ "$main_count" = 1 ] && [ -n "$selected_pid" ] || return 1
	echo "$selected_pid"
}

validate_candidate() {
	header="$(dd if="$1" bs=1 count=20 2>/dev/null | od -An -v -tx1 | tr -d ' \n')"
	case "$(architecture):$header" in
		linux-arm64-v8a:7f454c46020101*b700|linux-64:7f454c46020101*3e00) ;;
		*) fail "candidate is not a matching Linux ELF executable" ;;
	esac
	[ -n "$(version "$1")" ] || fail "candidate executable failed xray version"
	"$1" run -test -config "$CONFIG" > "$work/validation.log" 2>&1 || fail "candidate rejected active configuration; active binary was preserved"
}

snapshot_runtime() {
	nft -s list table inet podkopchik > "$work/nft.before" || fail "Podkopchik nft table is missing"
	ip rule show > "$work/ip.before" || fail "cannot inspect policy routing"
	ip route show table 10991 > "$work/route.before" || fail "cannot inspect Podkopchik routing table"
	ip route show default > "$work/default.before" || fail "cannot inspect default route"
	ip -6 route show default > "$work/default6.before" || fail "cannot inspect IPv6 default route"
	[ -s "$work/route.before" ] || fail "Podkopchik local route is missing"
	cp "$CONFIG" "$work/config.before"
}

verify_runtime() {
	tries=0
	while [ "$tries" -lt 10 ]; do
		if main_pid >/dev/null; then break; fi
		sleep 1; tries=$((tries + 1))
	done
	pid="$(main_pid)" || return 1
	sleep 2
	[ "$(main_pid)" = "$pid" ] || return 1
	nft -s list table inet podkopchik > "$work/nft.after" || return 1
	ip rule show > "$work/ip.after" || return 1
	ip route show table 10991 > "$work/route.after" || return 1
	ip route show default > "$work/default.after" || return 1
	ip -6 route show default > "$work/default6.after" || return 1
	cmp -s "$work/nft.before" "$work/nft.after" && cmp -s "$work/ip.before" "$work/ip.after" &&
		cmp -s "$work/route.before" "$work/route.after" && cmp -s "$work/config.before" "$CONFIG" &&
		cmp -s "$work/default.before" "$work/default.after" && cmp -s "$work/default6.before" "$work/default6.after" || return 1
	port="$(uci -q get podkopchik.main.transparent_port 2>/dev/null || echo 12345)"
	netstat -lntp 2>/dev/null | grep -E ":$port[[:space:]].*[[:space:]]$pid/" >/dev/null || return 1
	if [ "$(uci -q get podkopchik.main.fakedns_enabled 2>/dev/null || echo 0)" = 1 ]; then
		port="$(uci -q get podkopchik.main.fakedns_port 2>/dev/null || echo 1053)"
		netstat -lnup 2>/dev/null | grep -E ":$port[[:space:]].*[[:space:]]$pid/" >/dev/null || return 1
		listen="$(uci -q get podkopchik.main.fakedns_listen 2>/dev/null || true)"
		case "$listen" in ''|0.0.0.0|::) listen=127.0.0.1 ;; esac
		nslookup -timeout=3 -retry=1 -port="$port" x.com "$listen" > "$work/fakedns.answer" 2>/dev/null || return 1
		pool="$(uci -q get podkopchik.main.fakedns_pool_v4 2>/dev/null || echo 198.18.0.0/15)"
		awk -v pool="$pool" '
		 function ipnum(s, p, i, n) {
		  if (split(s, p, ".") != 4) return -1;
		  for (i=1; i<=4; i++) { if (p[i] !~ /^[0-9]+$/ || p[i]>255) return -1; n=n*256+p[i]; }
		  return n;
		 }
		 BEGIN { split(pool, p, "/"); base=ipnum(p[1]); bits=p[2]; scale=2^(32-bits); }
		 /Address/ { for (i=1; i<=NF; i++) {
		  addr=$i; sub(/#.*/, "", addr); value=ipnum(addr);
		  if (base>=0 && bits>=0 && bits<=32 && value>=0 && int(value/scale)==int(base/scale)) found=1;
		 } }
		 END { exit !found }
		' "$work/fakedns.answer" || return 1
	fi
	"$LIB/connection_check.sh" primary > "$work/probe.json" || return 1
	[ "$(jsonfilter -q -i "$work/probe.json" -e '@.status')" = up ]
}

rollback_binary() {
	restore_file="$recovery_dir/xray"
	restore_selector="$recovery_dir/selected"
	# After successful promotion, previous/ already contains this transaction's copy.
	if [ ! -s "$restore_file" ]; then
		restore_file="$CORE_DIR/previous/xray"
		restore_selector="$CORE_DIR/previous/selected"
	fi
	[ -s "$restore_file" ] || return 1
	# Rename the reserved copy: recovery must work even when opkg filled the disk.
	mv "$restore_file" "$CORE_DIR/xray" && mv "$restore_selector" "$CORE_DIR/selected" || return 1
	"$INIT" core_restart || return 1
	tries=0
	while [ "$tries" -lt 10 ]; do
		main_pid >/dev/null && return 0
		sleep 1; tries=$((tries + 1))
	done
	return 1
}

finish() {
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "${switch_pending:-0}" = 1 ]; then
		if rollback_binary; then
			echo status=rolled_back > "$CORE_DIR/last-status"
			echo "podkopchik Xray: update failed; previous executable restored" >&2
		else
			echo status=rollback_failed > "$CORE_DIR/last-status"
			echo "podkopchik Xray: rollback startup failed; previous binary is retained for recovery" >&2
		fi
		rc=1
	elif [ "$rc" != 0 ] && [ "${have_update:-0}" = 1 ]; then
		echo status=failed > "$CORE_DIR/last-status"
	fi
	[ -z "${work:-}" ] || rm -rf "$work"
	[ -z "${recovery_dir:-}" ] || rm -rf "$recovery_dir"
	if [ "${have_health:-0}" = 1 ]; then rm -f "$TMP_DIR/health-check.lock/pid"; rmdir "$TMP_DIR/health-check.lock"; fi
	[ "${have_apply:-0}" != 1 ] || rmdir "$TMP_DIR/config-apply.lock"
	if [ "${have_update:-0}" = 1 ]; then rm -f "$TMP_DIR/xray-update.lock/pid"; rmdir "$TMP_DIR/xray-update.lock"; fi
	exit "$rc"
}

install_update() {
	[ "$(uci -q get podkopchik.main.routing_enabled 2>/dev/null || echo 0)" = 1 ] || fail "apply working routing with a main proxy before updating Xray"
	[ -s "$CONFIG" ] || fail "active configuration is missing"
	lock_update
	work="$(mktemp -d "$TMP_DIR/xray-update.XXXXXX")"
	old_bin="$(xray_bin)" || fail "active Xray binary is missing"
	main_pid >/dev/null || fail "main Xray is not running; restore service before updating"
	old_size="$(wc -c < "$old_bin" | tr -d ' ')"
	# Reserve room for rollback, staging and extraction. No full-router backup.
	free_space "$CORE_DIR" "$((old_size / 1024 + 8192))"
	free_space "$TMP_DIR" "$((old_size / 1024 + 196608))"
	recovery_dir="$(mktemp -d "$CORE_DIR/recovery.XXXXXX")"
	printf '%s\n' rollback > "$recovery_dir/selected"
	cp "$old_bin" "$recovery_dir/xray"
	chmod 755 "$recovery_dir/xray"
	snapshot_runtime
	if [ "$action" = xray-rollback ]; then
		[ -x "$CORE_DIR/previous/xray" ] || fail "no previous Xray binary is available"
		cp "$CORE_DIR/previous/xray" "$work/candidate"
		new_source=rollback
	elif [ "$channel" = official ]; then
		command -v unzip >/dev/null 2>&1 || fail "unzip is required; install the OpenWrt unzip package"
		check_update
		url="$(field "$check_file" archive_url)"
		fetch "$url" "$work/release.zip" || fail "release download failed"
		expected_size="$(field "$check_file" size)"
		[ "$(wc -c < "$work/release.zip" | tr -d ' ')" = "$expected_size" ] || fail "release size mismatch"
		digest="$(field "$check_file" digest)"
		case "$digest" in sha256:*) expected="${digest#sha256:}" ;; *)
			fetch "$url.dgst" "$work/checksum" || fail "release checksum is unavailable"
			expected="$(awk 'toupper($0) ~ /^SHA(2-)?256[[:space:]]*=/ { print $NF }' "$work/checksum")"
			;;
		esac
		[ "${#expected}" = 64 ] || fail "invalid SHA256 metadata"
		case "$expected" in *[!a-fA-F0-9]*) fail "invalid SHA256 metadata" ;; esac
		actual="$(sha256sum "$work/release.zip" | awk '{print $1}')"
		[ "$(printf '%s' "$expected" | tr A-F a-f)" = "$actual" ] || fail "release SHA256 mismatch"
		# Extract one fixed member, never arbitrary archive paths or bundled geodata.
		( ulimit -f 131072; unzip -p "$work/release.zip" xray ) > "$work/candidate" || fail "could not extract bounded Xray executable (unzip is required)"
		[ "$(wc -c < "$work/candidate")" -le 134217728 ] || fail "candidate executable is too large"
		chmod 755 "$work/candidate"
		new_source=official
	else
		[ "$channel" = package ] || fail "source must be package or official"
		check_update
		# Only opkg may replace its package-owned file. The technical copy above
		# permits runtime rollback even when the previous IPK is no longer in feeds.
		switch_pending=1
		opkg upgrade xray-core > "$work/opkg.log" 2>&1 || fail "opkg xray-core upgrade failed; restoring previous runtime binary"
		package_bin="$(command -v xray || command -v xray-core)"
		cp "$package_bin" "$work/candidate"
		new_source=package
	fi
	validate_candidate "$work/candidate"
	if [ "$new_source" = official ]; then
		[ "$(version "$work/candidate")" = "${latest#v}" ] || fail "candidate version differs from the verified release"
	fi
	if [ "$new_source" != package ]; then
		new_size="$(wc -c < "$work/candidate" | tr -d ' ')"
		free_space "$CORE_DIR" "$((new_size / 1024 + 8192))"
	fi
	switch_pending=1
	if [ "$new_source" != package ]; then
		cp "$work/candidate" "$CORE_DIR/xray.new"
		chmod 755 "$CORE_DIR/xray.new"
		mv "$CORE_DIR/xray.new" "$CORE_DIR/xray"
	fi
	select_source "$new_source"
	"$INIT" core_restart || fail "Xray instance could not restart"
	verify_runtime || fail "new Xray runtime or main proxy check failed"
	rm -rf "$CORE_DIR/previous"
	mv "$recovery_dir" "$CORE_DIR/previous"
	printf 'status=verified\n' > "$CORE_DIR/last-status"
	switch_pending=0
	logger -t podkopchik "Xray core update verified; source=$new_source"
	status
}

action="${1:-xray-status}"
channel="${2:-package}"
mkdir -p "$TMP_DIR"
case "$action" in
	xray-status) status ;;
	xray-check) check_update; cat "$check_file" ;;
	xray-install|xray-rollback)
		mkdir -p "$CORE_DIR"
		trap finish EXIT
		trap 'exit 130' INT
		trap 'exit 143' HUP TERM
		install_update
		;;
	*) fail "unknown Xray update action" ;;
esac
