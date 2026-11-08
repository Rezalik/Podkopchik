#!/bin/sh
# App updates use the same detached, polled job pattern as the Xray manager.
set -eu
umask 077
LIB="${PODKOPCHIK_LIB:-/usr/libexec/podkopchik}"
TMP_DIR="${PODKOPCHIK_TMP_DIR:-/tmp/podkopchik}"
mkdir -p "$TMP_DIR"
lock="$TMP_DIR/update-job.lock"
state="$TMP_DIR/update-job.state"
case "${1:-}" in
 status) [ ! -f "$state" ] || cat "$state"; exit 0 ;;
 start)
	mkdir "$lock" 2>/dev/null || { echo 'Another app update is active; inspect its status before retrying.' >&2; exit 1; }
	id="$(date +%s)-$$"
	printf 'job_id=%s\njob_status=running\n' "$id" > "$state"
	( trap '' HUP; exec sh "$LIB/update_jobs.sh" run "$id" ) </dev/null > "$TMP_DIR/update-job.log" 2>&1 &
	cat "$state"
	exit 0 ;;
 run) id="$2" ;;
 *) exit 2 ;;
esac
finish() {
	rc=$?
	trap - EXIT
	if [ "$rc" = 0 ]; then result=done; else result=failed; fi
	printf 'job_id=%s\njob_status=%s\n' "$id" "$result" > "$state.new"
	# Bounded installation output; it contains no UCI dumps or client queries.
	tail -c 4096 "$TMP_DIR/update-job.log" | sed 's/^/message=/' >> "$state.new"
	mv "$state.new" "$state"
	rmdir "$lock"
	exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
"${PODKOPCHIK_CTL:-/usr/bin/podkopchikctl}" update-install
