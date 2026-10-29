#!/bin/sh
set -eu
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT HUP INT TERM
# Run just the actual failure trap with fake restore/apply/UI commands. Never
# execute the installer entry point or a router service on the test host.
awk '/^finish\(\)/ {p=1} p {print} p && /^}/ {exit}' tools/awg-stage4-install.sh > "$root/finish"
if (
 . "$root/finish"
 changing=1; owns_lock=1; backup="$root/private.tar.gz"; work="$root/work"; lock="$root/lock"; guard=""
 mkdir "$work" "$lock"
 touch "$lock/connection-token"
 tar() { printf '%s\n' 'restored' >> "$root/actions"; }
 activate() { printf '%s\n' 'reapplied' >> "$root/actions"; }
 restart_ui() { printf '%s\n' 'ui' >> "$root/actions"; }
 trap finish EXIT
 exit 7
) >"$root/out" 2>"$root/error"; then
 echo 'FAIL: original install failure was hidden'; exit 1
fi
grep -q '^restored$' "$root/actions"
grep -q '^reapplied$' "$root/actions"
test ! -d "$root/lock"
test ! -d "$root/work"
grep -q 'previous code/config reapplied' "$root/error"
grep -q 'archive checksum mismatch' tools/awg-stage4-install.sh
grep -q 'archive links/special files are forbidden' tools/awg-stage4-install.sh
grep -q 'instance.*health' tools/awg-stage4-install.sh
if grep -Eq 'reboot|sysupgrade|flush ruleset|init.d/network|init.d/firewall|init.d/podkopchik stop' tools/awg-stage4-install.sh; then
 echo 'FAIL: disruptive deployment operation'; exit 1
fi
echo 'Stage4 admin trap MOCK smoke OK: protected restore, reapply, lock release; no deployment claimed'
