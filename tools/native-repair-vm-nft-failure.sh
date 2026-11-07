#!/bin/sh
# Inject only one transaction failure in the disposable, NIC-free VM.
set -eu
real=$(command -v nft)
[ ! -e "$real.pkc-real" ]
mv "$real" "$real.pkc-real"
restore_repair_nft() { [ ! -e "$real.pkc-real" ] || mv "$real.pkc-real" "$real"; rm -f /tmp/pkc-repair-nft-failure; }
trap 'restore_repair_nft; emergency_clean' EXIT
cat > "$real" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -f ] && [ -f /tmp/pkc-repair-nft-failure ] && grep -q '^add table inet podkopchik_native ' "${2:-/dev/null}"; then
 rm /tmp/pkc-repair-nft-failure
 echo 'Injected repair nft failure' >&2
 exit 1
fi
exec "$0.pkc-real" "$@"
EOF
chmod 755 "$real"
touch /tmp/pkc-repair-nft-failure
ctl apply > "$permanent/repair-failed-apply.json"
for i in $(seq 1 45); do
	native_status
	[ "$(jsonfilter -i "$permanent/status.json" -e '@.phase')" != repair ] || break
	sleep 1
done
[ "$(jsonfilter -i "$permanent/status.json" -e '@.phase')" = repair ] || fail 'repair nft failure changed architecture'
[ -z "$(service_pid podkopchik-native-emergency-xray || true)" ]
if ln wget -q -T 1 -O - http://203.0.113.80:18081/ >/dev/null 2>&1; then fail 'failed cutover released protected traffic'; fi
restore_repair_nft
mv "$permanent/config/native-state/runtime.json" "$permanent/missing-state.saved"
native_env sh /etc/rc.common /mnt/lab/permanent/etc/init.d/podkopchik start > "$permanent/missing-start.log" 2>&1 || true
# rc.common may return success for an empty procd service even when
# start_service refused startup; verify the kernel and processes themselves.
[ -z "$(baseline_pid || true)" ] || fail 'missing Native state started legacy Xray'
rn nft list table inet podkopchik_native_uninitialized > "$permanent/missing-guard.nft"
grep -q 'dport 53.*drop' "$permanent/missing-guard.nft"
[ -z "$(service_pid podkopchik-native-emergency-xray || true)" ]
mv "$permanent/missing-state.saved" "$permanent/config/native-state/runtime.json"
cp "$permanent/uci/podkopchik" "$permanent/repair-valid-uci"
uci -c "$permanent/uci" set podkopchik.@ip_rule[0].cidr=invalid
uci -c "$permanent/uci" commit podkopchik
if ctl apply > "$permanent/repair-invalid.log" 2>&1; then fail 'invalid repair apply succeeded'; fi
cp "$permanent/repair-valid-uci" "$permanent/uci/podkopchik"
ctl apply > "$permanent/repair-corrected-apply.json"
wait_ready_native
token=$(jsonfilter -i "$permanent/status.json" -e '@.pending')
ctl native-confirm "$token"
if rn nft list table inet podkopchik_native_uninitialized >/dev/null 2>&1; then fail 'successful repair retained missing-state guard'; fi
[ "$(ln wget -q -T 5 -O - http://203.0.113.80:18081/)" = isolated-http-ok ]
trap emergency_clean EXIT
echo 'PASS: nft failure retains guarded Native repair; invalid correction preserves journal; corrected full Apply recovers in place without legacy rollback'
