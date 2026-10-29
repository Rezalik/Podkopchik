#!/bin/sh
# Independent procd-owned recovery timer. State/backups stay root-only.
set -eu
umask 077
mode="${1:-}"; dir="${2:-}"
fail() { echo "Stage4 watchdog: $*" >&2; exit 1; }
case "$dir" in /root/podkopchik-stage4-*) ;; *) fail 'invalid private state directory' ;; esac
[ "$(id -u)" = 0 ] || fail 'root required'
[ "$(cat /tmp/sysinfo/board_name)" = xiaomi,redmi-router-ax6000-stock ] || fail 'wrong board'
export GUARD_DIR="$dir"
ucode -e 'import * as f from "fs";let s=f.lstat(getenv("GUARD_DIR"));if(!s||s.type!="directory"||s.uid!=0||(s.mode&0o077))exit(1);' || fail 'unsafe state directory'
uptime_seconds() { cut -d. -f1 /proc/uptime; }
park() { while :; do sleep 5; done; }
check_snapshot() {
	archive="$dir/snapshot.tar.gz"
	tar -tzf "$archive" > "$dir/snapshot.paths" || return 1
	tar -tvzf "$archive" > "$dir/snapshot.types" || return 1
	if grep -Ev '^[-d]' "$dir/snapshot.types" | grep -q .; then return 1; fi
	while IFS= read -r path; do
		case "/$path/" in *'/../'*|*'/./'*) return 1 ;; esac
		case "$path" in ''|/*|*[!A-Za-z0-9_./-]*) return 1 ;; esac
		if [ "$(cat "$dir/kind")" = selftest ]; then
			[ "$path" = "${dir#/}/fixture" ] || return 1
			continue
		fi
		case "$path" in
		 etc/config/podkopchik|etc/podkopchik/|etc/podkopchik/*|etc/init.d/podkopchik|usr/bin/podkopchikctl|usr/libexec/podkopchik/|usr/libexec/podkopchik/*|usr/libexec/rpcd/podkopchik.awg|usr/share/podkopchik/tools/|usr/share/podkopchik/tools/*|usr/share/luci/menu.d/luci-app-podkopchik.json|usr/share/rpcd/acl.d/luci-app-podkopchik.json|www/luci-static/resources/view/podkopchik/|www/luci-static/resources/view/podkopchik/*|lib/upgrade/keep.d/podkopchik-awg|usr/share/ucode/luci/i18n/podkopchik.ru.lmo|usr/lib/lua/luci/i18n/podkopchik.ru.lmo|tmp/podkopchik/state.json) ;;
		 *) return 1 ;;
		esac
	done < "$dir/snapshot.paths"
}
recover_snapshot() {
	backup="$dir/snapshot.tar.gz"
	[ "$(sha256sum "$backup" | awk '{print $1}')" = "$(cat "$dir/snapshot.sha256")" ] || return 1
	check_snapshot || return 1
	if [ "$(cat "$dir/kind")" = selftest ]; then
		tar -xzf "$backup" -C /
		return
	fi
	# Stop only our installer worker; procd supervision is independent of SSH.
	ubus call service delete '{"name":"podkopchik-stage4-deploy"}' >/dev/null 2>&1 || true
	ubus call service delete '{"name":"podkopchik","instance":"health"}' >/dev/null 2>&1 || true
	i=0
	while [ "$(ubus call service list '{"name":"podkopchik"}' | jsonfilter -q -e '@.podkopchik.instances.health.running' 2>/dev/null)" = true ]; do
		[ "$i" -lt 12 ] || return 1
		sleep 1; i=$((i + 1))
	done
	sleep 2
	lock=/tmp/podkopchik/config-apply.lock
	i=0
	while [ -d "$lock" ] && [ "$(cat "$lock/stage4-owner" 2>/dev/null || true)" != "$dir" ] && [ "$i" -lt 30 ]; do
		sleep 2; i=$((i + 1))
	done
	if [ -d "$lock" ]; then
		[ "$(cat "$lock/stage4-owner" 2>/dev/null || true)" = "$dir" ] || return 1
		[ ! -f "$lock/connection-journal.json" ] || return 1
	else mkdir "$lock" || return 1; fi
	printf '%s\n' "$dir" > "$lock/stage4-owner"
	PODKOPCHIK_CONNECTION_APPLY="$(cat /proc/sys/kernel/random/uuid)"
	export PODKOPCHIK_CONNECTION_APPLY
	printf '%s\n' "$PODKOPCHIK_CONNECTION_APPLY" > "$lock/connection-token"
	# The snapshot is locally prepared and checksum-verified, never user input.
	# Keep current interception/guards until the old controller replaces it.
	if ! tar -xzf "$backup" -C / || ! podkopchikctl apply; then return 1; fi
	if [ -f "$dir/audit-owned" ] && nft -j list table inet podkopchik_stage4_audit 2>/dev/null |
		grep -q 'podkopchik-stage4-audit'; then
		nft delete table inet podkopchik_stage4_audit || return 1
	fi
	/etc/init.d/rpcd restart
	/etc/init.d/uhttpd restart
	rm -f "$lock/connection-token" "$lock/stage4-owner"
	rmdir "$lock"
}
case "$mode" in
 arm)
	seconds="${3:-}"
	case "$seconds" in ''|*[!0-9]*) fail 'invalid timeout' ;; esac
	[ "$seconds" -ge 5 ] && [ "$seconds" -le 1800 ] || fail 'timeout must be 5..1800 seconds'
	[ ! -e "$dir/deadline" ] || fail 'already armed'
	[ "$(sha256sum "$dir/snapshot.tar.gz" | awk '{print $1}')" = "$(cat "$dir/snapshot.sha256")" ] || fail 'snapshot checksum mismatch'
	case "$(cat "$dir/kind")" in selftest|restore) ;; *) fail 'invalid snapshot kind' ;; esac
	check_snapshot || fail 'unsafe snapshot: root/parent directory entries or unrelated files'
	if ubus call service list '{"name":"podkopchik-stage4-watchdog"}' | grep -q '"pid"'; then fail 'another guard is running'; fi
	printf '%s\n' "$(($(uptime_seconds) + seconds))" > "$dir/deadline"
	ucode -e 'let d=getenv("GUARD_DIR");printf("%J",{name:"podkopchik-stage4-watchdog",instances:{guard:{command:["/bin/sh",d+"/watchdog.sh","run",d],respawn:["3600","1","5"],stdout:false,stderr:false}}});' > "$dir/service.json"
	ubus call service set "$(cat "$dir/service.json")"
	echo 'Stage4 watchdog armed under procd; explicit commit required after verification'
	;;
 run)
	exec >> "$dir/watchdog.log" 2>&1
	while :; do
		[ ! -f "$dir/committed" ] || park
		[ ! -f "$dir/restored" ] || park
		if [ -f "$dir/recover-now" ] || [ "$(uptime_seconds)" -ge "$(cat "$dir/deadline")" ]; then
			ucode "$dir/guard-lock.uc" restore "$dir" || true
			[ ! -f "$dir/restore-failed" ] || park
		fi
		sleep 2
	done
	;;
 commit)
	ucode "$dir/guard-lock.uc" commit "$dir" || fail 'recovery already requested/running'
	ubus call service delete '{"name":"podkopchik-stage4-watchdog"}'
	echo 'Stage4 watchdog committed after operator verification'
	;;
 request)
	[ ! -f "$dir/committed" ] || fail 'already committed'
	: > "$dir/recover-now"
	echo 'Stage4 independent recovery requested'
	;;
 restore-locked) recover_snapshot ;;
 *) fail 'usage: watchdog.sh arm|run|commit|request STATE_DIR [SECONDS]' ;;
esac
