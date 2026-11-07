#!/bin/sh
# One-shot fault injection in the NIC-free guest, not on any router.
set -eu
. /mnt/lab/native-vm-only.sh
nft_path=$(command -v nft)
[ ! -e "$nft_path.pkc-real" ]
mv "$nft_path" "$nft_path.pkc-real"
restore_nft() {
	[ ! -f "$nft_path.pkc-real" ] || mv "$nft_path.pkc-real" "$nft_path"
	rm -f /tmp/pkc-native-nft-failure
}
trap 'restore_nft; permanent_cleanup' EXIT
cat > "$nft_path" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -f ] && [ -f /tmp/pkc-native-nft-failure ] &&
   grep -q '^add table inet podkopchik_native ' "${2:-/dev/null}"; then
	rm -f /tmp/pkc-native-nft-failure
	echo 'Injected native nft transaction failure' >&2
	exit 1
fi
exec "$0.pkc-real" "$@"
EOF
chmod 755 "$nft_path"
native_status
before=$(jsonfilter -q -i "$permanent/status.json" -e '@.confirmed')
touch /tmp/pkc-native-nft-failure
ctl apply > "$permanent/nft-failed-apply.json"
failed=$(jsonfilter -q -i "$permanent/nft-failed-apply.json" -e '@.pending')
for attempt in $(seq 1 40); do
	native_status
	phase=$(jsonfilter -q -i "$permanent/status.json" -e '@.phase')
	pending=$(jsonfilter -q -i "$permanent/status.json" -e '@.pending') || pending=''
	[ "$phase" != active ] || [ -n "$pending" ] || break
	sleep 1
done
[ "$phase" = active ] && [ -z "$pending" ]
[ "$(jsonfilter -q -i "$permanent/status.json" -e '@.confirmed')" = "$before" ]
[ ! -e /tmp/pkc-native-nft-failure ]
grep -q 'Injected native nft transaction failure' "$permanent/tmp/native-error"
v4=$(query_native udp probe.protected.example. A NOERROR 1 | sed -n 's/^address=//p')
[ "$(ln wget -q -T 3 -O - "http://$v4:18081/")" = isolated-http-ok ]
if ctl native-confirm "$failed" >/dev/null 2>&1; then fail 'failed nft Apply was confirmed'; fi
restore_nft
trap permanent_cleanup EXIT
echo 'PASS: actual nft cutover failure autonomously restores the last confirmed generation without changing routing intent'
