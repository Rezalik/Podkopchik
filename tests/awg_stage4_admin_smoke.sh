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
# Exercise the real activation function in isolation, including downgrade guard
# release. All absolute paths below are redirected to this private test root.
awk '/^activate\(\)/ {p=1} p {print} p && /^}/ {exit}' tools/awg-stage4-install.sh |
 sed "s@/usr/libexec/podkopchik/routing_safety.sh@$root/safety@g; s@/etc/init.d/podkopchik@$root/init@g" > "$root/activate"
export STAGE4_TEST_ROOT="$root"
cat > "$root/safety" <<'EOF'
#!/bin/sh
echo "safety $*" >> "$STAGE4_TEST_ROOT/activation-actions"
case "$1" in pids) echo 100 ;; ready) [ "${2:-}" = 100 ] ;; esac
EOF
cat > "$root/init" <<'EOF'
#!/bin/sh
echo "init $*" >> "$STAGE4_TEST_ROOT/activation-actions"
EOF
chmod +x "$root/init" "$root/safety"
. "$root/activate"
uci() { echo "$requested"; }
ubus() { echo '{}'; }
jsonfilter() { :; }
podkopchikctl() { echo "ctl $*" >> "$root/activation-actions"; [ "${fail_apply:-0}" = 0 ]; }
requested=0
activate
grep -qx 'init restart' "$root/activation-actions"
! grep -q 'ctl apply' "$root/activation-actions"
: > "$root/activation-actions"
requested=1
activate
grep -qx 'ctl apply' "$root/activation-actions"
grep -qx 'safety ready 100' "$root/activation-actions"
grep -qx 'safety unguard' "$root/activation-actions"
: > "$root/activation-actions"
fail_apply=1
if activate; then echo 'FAIL: activation swallowed failed Apply'; exit 1; fi
! grep -q 'safety unguard' "$root/activation-actions"
if grep -Eq 'reboot|sysupgrade|flush ruleset|init.d/network|init.d/firewall|init.d/podkopchik stop' tools/awg-stage4-install.sh; then
 echo 'FAIL: disruptive deployment operation'; exit 1
fi
echo 'Stage4 admin MOCK smoke OK: protected restore, persisted OFF, fresh core readiness; no deployment claimed'
