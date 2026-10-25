#!/bin/sh
# Short LuCI requests start a worker; all actual update locking stays in the manager.
set -eu
umask 077
LIB="${PODKOPCHIK_LIB:-/usr/libexec/podkopchik}"
TMP_DIR="${PODKOPCHIK_TMP_DIR:-/tmp/podkopchik}"
mkdir -p "$TMP_DIR"
lock="$TMP_DIR/xray-job.lock"
state="$TMP_DIR/xray-job.state"
op="${2:-}"
source="${3:-package}"
case "$op:$source" in xray-check:package|xray-check:official|xray-install:package|xray-install:official|xray-rollback:package) ;;
	*) echo 'invalid Xray job action' >&2; exit 1 ;;
esac

if [ "${1:-}" = start ]; then
	if ! mkdir "$lock" 2>/dev/null; then
		owner="$(cat "$lock/pid" 2>/dev/null || true)"
		case "$owner" in ''|*[!0-9]*) echo 'another Xray job is starting' >&2; exit 1 ;; esac
		if kill -0 "$owner" 2>/dev/null; then echo 'another Xray job is running' >&2; exit 1; fi
		rm -f "$lock/pid"
		rmdir "$lock" && mkdir "$lock" || exit 1
	fi
	id="$(date +%s)-$$"
	printf '%s\n' "$$" > "$lock/pid"
	printf 'job_id=%s\njob_status=running\njob_started=%s\n' "$id" "$(date +%s)" > "$state.new"
	mv "$state.new" "$state"
	( trap '' HUP; exec sh "$LIB/xray_jobs.sh" run "$op" "$source" "$id" ) </dev/null > "$TMP_DIR/xray-job.log" 2>&1 &
	cat "$state"
	exit 0
fi

id="${4:-}"
printf '%s\n' "$$" > "$lock/pid"
complete() {
	rc=$?
	trap - EXIT
	if [ "$rc" = 0 ]; then result=done; else result=failed; fi
	printf 'job_id=%s\njob_status=%s\n' "$id" "$result" > "$state.new"
	if [ "$rc" != 0 ]; then
		message="$(grep -m 1 -E 'podkopchik Xray:|invalid Xray' "$TMP_DIR/xray-job.log" | tr '\n\r' '  ' || true)"
		printf 'job_message=%s\n' "${message:-Xray operation failed}" >> "$state.new"
	fi
	mv "$state.new" "$state"
	rm -f "$lock/pid"
	rmdir "$lock" 2>/dev/null || true
	exit "$rc"
}
trap complete EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
sh "$LIB/xray_update.sh" "$op" "$source"
