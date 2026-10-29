#!/bin/sh
# Explicit AX6000 overlay deployment. Not called by normal install/update.
set -eu
umask 077
fail() { echo "AWG stage4: $*" >&2; exit 1; }
[ "$#" = 3 ] || fail 'usage: awg-stage4-install.sh --check|--install|--rollback /root/ARCHIVE SHA256'
mode="$1"; archive="$2"; digest="$3"
case "$mode" in --check|--install|--rollback) ;; *) fail 'invalid mode' ;; esac
case "$archive" in /root/*) ;; *) fail 'archive must stay on this router under /root' ;; esac
[ "$(id -u)" = 0 ] || fail 'root required'
[ "$(cat /tmp/sysinfo/board_name)" = xiaomi,redmi-router-ax6000-stock ] || fail 'wrong router'
[ "$(sha256sum "$archive" | awk '{print $1}')" = "$digest" ] || fail 'archive checksum mismatch'
base="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
sh "$base/awg-preflight.sh" --check
work="$(mktemp -d /tmp/podkopchik-stage4.XXXXXX)"
lock=/tmp/podkopchik/config-apply.lock
changing=0; owns_lock=0; backup=""
guard="${PODKOPCHIK_STAGE4_GUARD:-}"
[ "$mode" != --install ] || [ -n "$guard" ] || fail 'arm an independent procd watchdog before installation'
if [ -n "$guard" ]; then
	case "$guard" in /root/podkopchik-stage4-*) ;; *) fail 'invalid independent guard' ;; esac
	[ -f "$guard/deadline" ] && [ ! -e "$guard/committed" ] || fail 'independent guard is not armed'
	[ ! -e "$guard/restored" ] && [ ! -e "$guard/restore-failed" ] && [ ! -e "$guard/recover-now" ] || fail 'independent recovery already requested'
	pid="$(ubus call service list '{"name":"podkopchik-stage4-watchdog"}' | jsonfilter -q -e '@.*.instances.guard.pid')"
	case "$pid" in ''|*[!0-9]*) fail 'independent guard service is not running' ;; esac
	case "$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" in
		*"$guard/watchdog.sh run $guard"*) ;;
		*) fail 'independent guard process does not match this deployment' ;;
	esac
	[ "$(cat "$guard/deadline")" -gt "$(($(cut -d. -f1 /proc/uptime) + 30))" ] || fail 'independent recovery deadline is too close'
fi
activate() {
	# Replace only the health worker, so it loads the new script; keep the
	# transparent rules and AWG interfaces live throughout the code update.
	ubus call service delete '{"name":"podkopchik","instance":"health"}' >/dev/null 2>&1 || true
	i=0
	while [ "$(ubus call service list '{"name":"podkopchik"}' | jsonfilter -q -e '@.podkopchik.instances.health.running' 2>/dev/null)" = true ]; do
		[ "$i" -lt 12 ] || return 1
		sleep 1; i=$((i + 1))
	done
	podkopchikctl apply
}
restart_ui() {
	/etc/init.d/rpcd restart
	/etc/init.d/uhttpd restart
}
finish() {
	rc="$?"
	trap - EXIT HUP INT TERM
	if [ "$changing" = 1 ]; then
		echo 'AWG stage4: deployment failed; restoring protected snapshot' >&2
		if [ -n "$guard" ]; then
			: > "$guard/recover-now"
			echo 'AWG stage4: delegated restoration to independent watchdog' >&2
		elif tar -xzf "$backup" -C / && activate; then
			restart_ui || true
			echo 'AWG stage4: previous code/config reapplied' >&2
		else
			echo "AWG stage4: AUTOMATIC RESTORE FAILED. Keep SSH open. Snapshot: $backup" >&2
		fi
	fi
	if [ "$owns_lock" = 1 ]; then rm -f "$lock/connection-token" "$lock/stage4-owner"; rmdir "$lock" 2>/dev/null || true; fi
	rm -rf "$work"
	exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
# Refuse archive links, path traversal and unknown regular-file destinations.
tar -tzf "$archive" > "$work/paths"
if grep -Eq '(^/|(^|/)\.\.(/|$)|[^A-Za-z0-9_./-])' "$work/paths"; then fail 'unsafe archive path'; fi
validate_restore_paths() {
	while IFS= read -r path; do
		case "$path" in .|./|./*|/*) return 1 ;; esac
		case "$path" in
		 */)
			case "$path" in
			 etc/podkopchik/|etc/podkopchik/*|usr/libexec/podkopchik/|usr/libexec/podkopchik/*|www/luci-static/resources/view/podkopchik/|www/luci-static/resources/view/podkopchik/*|usr/share/podkopchik/tools/|usr/share/podkopchik/tools/*) ;;
			 *) return 1 ;;
			esac ;;
		esac
	done
}
if [ "$mode" = --rollback ]; then
	validate_restore_paths < "$work/paths" || fail 'rollback archive contains root/system parent metadata'
fi
tar -tvzf "$archive" > "$work/types"
if grep -Ev '^[-d]' "$work/types" | grep -q .; then fail 'archive links/special files are forbidden'; fi
mkdir "$work/payload"
tar -xzf "$archive" -C "$work/payload"
find "$work/payload" -type f > "$work/files"
while IFS= read -r file; do
	path="${file#"$work/payload/"}"
	case "$path" in
	 etc/init.d/podkopchik|usr/bin/podkopchikctl|usr/libexec/podkopchik/*|usr/libexec/rpcd/podkopchik.awg|usr/share/podkopchik/tools/*|usr/share/luci/menu.d/luci-app-podkopchik.json|usr/share/rpcd/acl.d/luci-app-podkopchik.json|www/luci-static/resources/view/podkopchik/*|lib/upgrade/keep.d/podkopchik-awg|usr/share/ucode/luci/i18n/podkopchik.ru.lmo|usr/lib/lua/luci/i18n/podkopchik.ru.lmo) ;;
	 etc/config/podkopchik|etc/podkopchik/*|tmp/podkopchik/state.json) [ "$mode" = --rollback ] || fail 'public overlay contains private configuration' ;;
	 *) fail 'unknown archive destination' ;;
	esac
done < "$work/files"
test -f "$work/payload/usr/libexec/podkopchik/awg_manage.uc" || fail 'not a mixed AWG release'
if [ "$mode" != --rollback ]; then
	test -f "$work/payload/usr/libexec/podkopchik/interception.uc" || fail 'not a Stage4 overlay'
fi
for file in "$work/payload"/usr/libexec/podkopchik/*.sh; do sh -n "$file"; done
sh -n "$work/payload/usr/bin/podkopchikctl"
if [ "$mode" = --check ]; then
	echo 'AWG stage4: archive/preflight OK; no runtime or persistent settings changed'
	exit 0
fi
# Shared lock preserves live interception and prevents health selection races.
# Do not stop the service: that would remove TPROXY before a replacement exists.
mkdir "$lock" 2>/dev/null || fail 'config apply is busy'
owns_lock=1
[ -z "$guard" ] || printf '%s\n' "$guard" > "$lock/stage4-owner"
[ ! -e /tmp/podkopchik/health-check.lock ] || fail 'health check is busy; retry later'
PODKOPCHIK_CONNECTION_APPLY="$(ucode -L /usr/libexec/podkopchik -e 'printf("%s",require("awg").nonce());')"
export PODKOPCHIK_CONNECTION_APPLY
printf '%s\n' "$PODKOPCHIK_CONNECTION_APPLY" > "$lock/connection-token"
stamp="$(date +%s)-$$"
backup="/root/podkopchik-before-stage4-$stamp.tar.gz"
sh "$base/awg-preflight.sh" --backup "$backup"
diag="/root/podkopchik-before-stage4-$stamp"
mkdir -m 700 "$diag"
nft -s list table inet podkopchik > "$diag/nft.txt"
ip -N -4 rule show > "$diag/rules4.txt"
ip -N -6 rule show > "$diag/rules6.txt"
ip -N -4 route show table all > "$diag/routes4.txt"
ip -N -6 route show table all > "$diag/routes6.txt"
changing=1
tar -xzf "$archive" -C /
podkopchikctl validate
activate
sleep 2
podkopchikctl status > "$work/status.txt"
grep -qx 'Xray: running' "$work/status.txt" || fail 'main Xray is not running after apply'
podkopchikctl validate-active >/dev/null || fail 'active Xray config is invalid'
# Forwarding and DNS remain owned by Podkopchik; no network service restart.
restart_ui
changing=0
echo "AWG stage4: completed. Protected rollback snapshot: $backup"
sha256sum "$backup"
