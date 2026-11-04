#!/bin/sh
set -eu
base=$(mktemp -d)
trap 'rm -rf "$base"' EXIT HUP INT TERM
export PODKOPCHIK_LIB="$base/lib" PODKOPCHIK_TMP_DIR="$base/run" PODKOPCHIK_CONFIG_DIR="$base/config"
export PODKOPCHIK_PROC_DIR="$base/proc" PODKOPCHIK_INIT="$base/bin/init" TEST_ROOT="$base"
mkdir -p "$base/bin" "$base/lib" "$base/config" "$base/run" "$base/proc"
export PATH="$base/bin:$PATH"
cp root/usr/libexec/podkopchik/routing_safety.sh root/usr/libexec/podkopchik/xray.sh "$base/lib/"
touch "$base/lib/awg_cli.uc"
cat > "$base/bin/uci" <<'EOF'
#!/bin/sh
[ "$1" != -q ] || shift
case "$1" in
 get)
 case "$2" in
  podkopchik.main.routing_enabled) cat "$TEST_ROOT/requested" ;;
  podkopchik.main.enabled) echo 1 ;;
  podkopchik.main.lan_ifname) echo br-lan ;;
  'podkopchik.@proxy[0]') echo proxy ;;
  'podkopchik.@proxy[0].enabled') cat "$TEST_ROOT/proxy-enabled" ;;
  'podkopchik.@proxy[0].tag') echo fixture ;;
  'podkopchik.@proxy[0].uri') echo 'vless://TEST_ONLY' ;;
  'podkopchik.@domain_rule[0]') echo domain_rule ;;
  'podkopchik.@domain_rule[0].enabled') echo 1 ;;
  'podkopchik.@domain_rule[0].domain') [ "$(cat "$TEST_ROOT/has-route")" = 1 ] && echo example.invalid ;;
  'podkopchik.@domain_rule[0].target') echo direct ;;
  *) exit 1 ;;
 esac ;;
 set)
 echo "$2" >> "$TEST_ROOT/uci-writes"
 case "$2" in podkopchik.main.routing_enabled=*) echo "${2#*=}" > "$TEST_ROOT/requested" ;; esac ;;
 commit) : ;;
 *) exit 1 ;;
esac
EOF
cat > "$base/bin/ucode" <<'EOF'
#!/bin/sh
case "$*" in
 *awg_cli.uc*)
  echo "$*" >> "$TEST_ROOT/awg-actions"
  case "$*" in *' sync') [ ! -f "$TEST_ROOT/fail-awg-sync" ] ;; esac ;;
 *parse_vless.uc*) echo '{"network":"tcp","security":"reality"}' ;;
 *) cat "$TEST_ROOT/candidate.json" ;;
esac
EOF
cat > "$base/bin/jsonfilter" <<'EOF'
#!/bin/sh
case "$*" in *'.network'*) echo tcp ;; *'.security'*) echo reality ;; *) echo 12345 ;; esac
EOF
cat > "$base/bin/xray" <<'EOF'
#!/bin/sh
case "$*" in *'-test'*) ! grep -q '"bad":true' "$4" ;; *) exit 1 ;; esac
EOF
cat > "$base/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in
 -V) echo 'ip utility, iproute2-test' ;;
 *'rule show'*) [ ! -f "$PODKOPCHIK_TMP_DIR/routing.env" ] || echo '10991: from all fwmark 0x100000 lookup 10991' ;;
 *'route show table 10991'*) [ ! -f "$PODKOPCHIK_TMP_DIR/routing.env" ] || echo 'local default dev lo scope host' ;;
 *) echo "$*" >> "$TEST_ROOT/ip-writes" ;;
esac
EOF
cat > "$base/bin/nft" <<'EOF'
#!/bin/sh
case "$*" in
 'list tables')
  [ ! -e "$TEST_ROOT/nft-app" ] || echo 'table inet podkopchik'
  [ ! -e "$TEST_ROOT/nft-guard" ] || echo 'table inet podkopchik_guard'
  exit 0 ;;
 'list table inet podkopchik') [ -f "$TEST_ROOT/nft-app" ] && cat "$TEST_ROOT/nft-app" ;;
 'delete table inet podkopchik_guard') rm -f "$TEST_ROOT/nft-guard" ;;
 -c*) exit 0 ;;
 -f*)
  if grep -q 'add table inet podkopchik_guard' "$2"; then cp "$2" "$TEST_ROOT/nft-guard"
  elif grep -q 'table inet podkopchik' "$2"; then
   sed '/^delete table /d' "$2" > "$TEST_ROOT/nft-app"
  else exit 1; fi ;;
 *) exit 1 ;;
esac
EOF
cat > "$base/bin/netstat" <<'EOF'
#!/bin/sh
[ ! -f "$PODKOPCHIK_PROC_DIR/200/cmdline" ] || echo 'tcp 0 0 127.0.0.1:12345 0.0.0.0:* LISTEN 200/xray'
EOF
cat > "$base/bin/init" <<'EOF'
#!/bin/sh
echo "$*" >> "$TEST_ROOT/init-actions"
if [ -e "$TEST_ROOT/fail-start-once" ]; then rm "$TEST_ROOT/fail-start-once"; exit 1; fi
if [ "$(cat "$TEST_ROOT/requested")" = 1 ]; then
 mkdir -p "$PODKOPCHIK_PROC_DIR/200"
 printf 'xray\000run\000-config\000%s\000' "$PODKOPCHIK_CONFIG_DIR/config.json" > "$PODKOPCHIK_PROC_DIR/200/cmdline"
else rm -rf "$PODKOPCHIK_PROC_DIR/200"; fi
EOF
cat > "$base/lib/apply_rules.sh" <<'EOF'
#!/bin/sh
echo apply >> "$TEST_ROOT/rule-actions"
[ ! -f "$TEST_ROOT/fail-nft" ] || { echo 'nft commit failed (fixture)' >&2; exit 1; }
echo 'table inet podkopchik { # NEW }' > "$TEST_ROOT/nft-app"
echo podkopchik-routing-v1 > "$PODKOPCHIK_TMP_DIR/routing.env"
EOF
cat > "$base/lib/cleanup_rules.sh" <<'EOF'
#!/bin/sh
echo cleanup >> "$TEST_ROOT/rule-actions"
rm -f "$TEST_ROOT/nft-app" "$PODKOPCHIK_TMP_DIR/routing.env"
EOF
cat > "$base/bin/logger" <<'EOF'
#!/bin/sh
echo "$*" >> "$TEST_ROOT/events"
EOF
chmod +x "$base/bin/"* "$base/lib/"*.sh

reset_case() {
	rm -rf "$base/config" "$base/run" "$base/proc"
	mkdir -p "$base/config" "$base/run" "$base/proc/200"
	printf 'xray\000run\000-config\000%s\000' "$base/config/config.json" > "$base/proc/200/cmdline"
	echo '{"inbounds":[{"tag":"transparent","port":12345}],"old":true}' > "$base/config/config.json"
	cp "$base/config/config.json" "$base/old.json"
	echo '{"inbounds":[{"tag":"transparent","port":12345}],"new":true}' > "$base/candidate.json"
	echo 'table inet podkopchik { # OLD }' > "$base/nft-app"
	cp "$base/nft-app" "$base/old.nft"
	echo podkopchik-routing-v1 > "$base/run/routing.env"
	echo 1 > "$base/requested"; echo 1 > "$base/proxy-enabled"; echo 1 > "$base/has-route"
	rm -f "$base/fail-nft" "$base/fail-start-once" "$base/fail-awg-sync" "$base/nft-guard"
	: > "$base/uci-writes"; : > "$base/init-actions"; : > "$base/rule-actions"; : > "$base/awg-actions"
}
apply() { sh root/usr/bin/podkopchikctl apply > "$base/output" 2>&1; }
unchanged() {
	cmp "$base/old.json" "$base/config/config.json"
	cmp "$base/old.nft" "$base/nft-app"
	[ "$(cat "$base/requested")" = 1 ]
	! grep -q 'routing_enabled=0' "$base/uci-writes"
}
for reason in missing_proxy missing_rule invalid_config; do
	reset_case
	case "$reason" in
	 missing_proxy) echo 0 > "$base/proxy-enabled" ;;
	 missing_rule) echo 0 > "$base/has-route" ;;
	 invalid_config) echo '{"bad":true}' > "$base/candidate.json" ;;
	esac
	if apply; then echo "Expected validation failure: $reason"; exit 1; fi
	unchanged
	[ ! -s "$base/init-actions" ] && [ ! -s "$base/rule-actions" ] && [ ! -s "$base/awg-actions" ]
done

for reason in nft_failure xray_start_failure awg_sync_failure; do
	reset_case
	case "$reason" in
	 nft_failure) touch "$base/fail-nft" ;;
	 awg_sync_failure) touch "$base/fail-awg-sync" ;;
	 *) touch "$base/fail-start-once" ;;
	esac
	if apply; then echo "Expected runtime failure: $reason"; exit 1; fi
	unchanged
	[ ! -f "$base/nft-guard" ]
	grep -q restore-active "$base/awg-actions"
done

# No existing namespace may be taken over under the guard's name.
reset_case
echo foreign > "$base/nft-guard"
if apply; then echo 'Expected foreign-guard rejection'; exit 1; fi
unchanged
[ "$(cat "$base/nft-guard")" = foreign ]

# Failed first activation does not flip OFF to ON or expose LAN forwarding.
reset_case
echo 0 > "$base/requested"
rm -rf "$base/proc/200"; rm "$base/nft-app"
touch "$base/fail-nft"
if apply; then echo 'Expected first activation failure'; exit 1; fi
[ "$(cat "$base/requested")" = 0 ]
cmp "$base/old.json" "$base/config/config.json"
[ -f "$base/nft-guard" ]
[ ! -s "$base/init-actions" ]
sh root/usr/bin/podkopchikctl status > "$base/output"
grep -qx 'Routing applied: 0' "$base/output"
grep -qx 'Routing safety guard: active' "$base/output"

reset_case
sh "$base/lib/routing_safety.sh" ready
if sh "$base/lib/routing_safety.sh" ready '200'; then echo 'Old listener falsely acknowledged as restarted'; exit 1; fi
apply
grep -q '"new":true' "$base/config/config.json"
[ -f "$base/config/working-state.name" ] && [ ! -f "$base/nft-guard" ]
# Emulate a later recovery after /tmp was lost, not a physical reboot.
cp "$base/config/config.json" "$base/last.json"
rm -rf "$base/run" "$base/proc/200"; mkdir "$base/run"
rm -f "$base/nft-app"
sh "$base/lib/routing_safety.sh" restore
cmp "$base/last.json" "$base/config/config.json"
[ -f "$base/nft-guard" ]
grep -q 'hook forward priority -10' "$base/nft-guard"
grep -q 'iifname "br-lan" counter drop' "$base/nft-guard"
! grep -q 'hook input\|hook output' "$base/nft-guard"

# Explicit Cleanup alone persists OFF and removes the owned guard/table.
sh root/usr/bin/podkopchikctl cleanup > "$base/output" 2>&1
[ "$(cat "$base/requested")" = 0 ]
[ ! -f "$base/nft-guard" ] && [ ! -f "$base/nft-app" ]
[ ! -d "$base/proc/200" ]
echo 'Safe Apply/rollback/explicit-disable smoke OK (mocked kernel; no live WAN leak claim)'
