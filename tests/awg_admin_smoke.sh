#!/bin/sh
set -eu
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT HUP INT TERM
awk '/^cmd_rollback\(\)/ {p=1} p {print} p && /^}/ {exit}' root/usr/bin/podkopchikctl > "$root/rollback-function"
(
	. "$root/rollback-function"
	ROLLBACK="$root/archive"
	touch "$ROLLBACK"
	printf x > "$ROLLBACK"
	has_awg_binding() { return 0; }
	die() { echo "$*" >&2; exit 1; }
	tar() {
		if [ "$1" = -tzf ]; then echo usr/libexec/podkopchik/awg.uc; return; fi
		echo 'UNSAFE RESTORE' >> "$root/mutations"
		return 1
	}
	cmd_rollback
) >"$root/out" 2>"$root/error" && { echo 'FAIL: old rollback accepted AWG bindings'; exit 1; }
grep -q 'old rollback cannot handle AWG bindings' "$root/error"
test ! -e "$root/mutations"
grep -q 'No package installation' tools/awg-preflight.sh
grep -q 'validate-active' tools/awg-preflight.sh
grep -q 'checksum mismatch' tools/awg-rollback.sh
grep -q 'dispose-all' tools/awg-rollback.sh
grep -q 'before_start\|prepare-connections' root/etc/init.d/podkopchik
if grep -Eq -- '--allow-untrusted|--force|awg-quick up|ip route.*table main' tools/awg-preflight.sh tools/awg-rollback.sh; then
	echo 'FAIL: unsafe admin command'; exit 1
fi
echo 'AWG admin static/rollback-guard smoke OK; no live code restoration claimed'
