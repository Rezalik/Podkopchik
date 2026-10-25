#!/bin/sh
set -eu

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export TEST_ROOT="$tmp"
export PODKOPCHIK_LIB="$tmp/lib"
export PODKOPCHIK_TMP_DIR="$tmp/runtime"
export PODKOPCHIK_CONFIG_DIR="$tmp/config"
export PODKOPCHIK_CORE_DIR="$tmp/core"
export PODKOPCHIK_PROC_DIR="$tmp/proc"
export PODKOPCHIK_INIT="$tmp/init"
export PODKOPCHIK_OPKG_CONF="$tmp/opkg.conf"
mkdir -p "$tmp/bin" "$tmp/lib" "$tmp/runtime" "$tmp/config" "$tmp/core" "$tmp/proc/42" "$tmp/asset"
echo 'option check_signature' > "$tmp/opkg.conf"
cp root/usr/libexec/podkopchik/xray.sh "$tmp/lib/"
export PATH="$tmp/bin:$PATH"

cat > "$tmp/old" <<'EOF'
#!/bin/sh
if [ "$1" = version ]; then echo 'Xray 25.1.30'; else exit 0; fi
EOF
cat > "$tmp/new" <<'EOF'
#!/bin/sh
if [ "$1" = version ]; then echo 'Xray 26.10.21'; exit 0; fi
[ "${FAIL_CONFIG:-0}" != 1 ]
EOF
chmod +x "$tmp/old" "$tmp/new"
cp "$tmp/old" "$tmp/bin/xray"
cp "$tmp/new" "$tmp/asset/xray"
(cd "$tmp/asset" && zip -q "$tmp/release.zip" xray)
digest="$(sha256sum "$tmp/release.zip" | awk '{print $1}')"
size="$(wc -c < "$tmp/release.zip" | tr -d ' ')"
printf '{"tag_name":"v26.10.21","assets":[{"name":"Xray-linux-arm64-v8a.zip","size":%s,"digest":"sha256:%s"}]}' "$size" "$digest" > "$tmp/metadata"
echo '{"routing":{},"fakedns":{"ipPool":"198.18.0.0/15"}}' > "$tmp/config/config.json"
cp "$tmp/config/config.json" "$tmp/original-config"
printf '%s\000run\000-config\000%s\000' "$tmp/bin/xray" "$tmp/config/config.json" > "$tmp/proc/42/cmdline"

cat > "$tmp/bin/uname" <<'EOF'
#!/bin/sh
echo "${TEST_ARCH:-aarch64}"
EOF
cat > "$tmp/bin/od" <<'EOF'
#!/bin/sh
cat >/dev/null
echo '7f 45 4c 46 02 01 01 00 00 00 00 00 00 00 00 00 02 00 b7 00'
EOF
cat > "$tmp/bin/df" <<'EOF'
#!/bin/sh
echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
echo "test 999999 0 ${TEST_FREE:-999999} 0% /"
EOF
cat > "$tmp/bin/curl" <<'EOF'
#!/bin/sh
out=''; previous=''
for arg in "$@"; do
 [ "$previous" != '-o' ] || out="$arg"
 case "$arg" in https://*) url="$arg" ;; esac
 previous="$arg"
done
case "$url" in
 *api.github.com*) cp "$TEST_ROOT/metadata" "$out" ;;
 *.zip) cp "$TEST_ROOT/release.zip" "$out" ;;
 *.dgst) echo "SHA256= ${BAD_DIGEST:-0000000000000000000000000000000000000000000000000000000000000000}" > "$out" ;;
 *) exit 1 ;;
esac
EOF
cat > "$tmp/bin/jsonfilter" <<'EOF'
#!/usr/bin/env node
const fs = require('fs');
const args = process.argv.slice(2);
const file = args[args.indexOf('-i') + 1];
const expr = args[args.indexOf('-e') + 1];
let data = JSON.parse(fs.readFileSync(file));
const fields = expr.replace(/^@\./, '').replace(/\[(\d+)\]/g, '.$1').split('.');
for (const field of fields) data = data && data[field];
if (data == null) process.exit(1);
console.log(data);
EOF
cat > "$tmp/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
 *routing_enabled*|*fakedns_enabled*) echo 1 ;;
 *transparent_port*) echo 12345 ;;
 *fakedns_port*) echo 1053 ;;
 *) exit 1 ;;
esac
EOF
cat > "$tmp/bin/readlink" <<'EOF'
#!/bin/sh
case "$(cat "$PODKOPCHIK_CORE_DIR/selected" 2>/dev/null || echo package)" in
 package) echo "$TEST_ROOT/bin/xray" ;;
 *) echo "$PODKOPCHIK_CORE_DIR/xray" ;;
esac
EOF
cat > "$tmp/bin/nft" <<'EOF'
#!/bin/sh
[ "$*" = '-s list table inet podkopchik' ] || exit 1
echo 'table inet podkopchik { FakeDNS unchanged; TCP TPROXY unchanged; }'
EOF
cat > "$tmp/bin/ip" <<'EOF'
#!/bin/sh
echo "unchanged $*"
EOF
cat > "$tmp/bin/netstat" <<'EOF'
#!/bin/sh
echo 'tcp 0 0 :::12345 :::* LISTEN 42/xray'
echo 'udp 0 0 :::1053 :::* 42/xray'
EOF
cat > "$tmp/bin/nslookup" <<'EOF'
#!/bin/sh
echo "Address 1: ${FAKE_ANSWER:-198.19.1.2}"
EOF
cat > "$tmp/bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$tmp/bin/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$tmp/init" <<'EOF'
#!/bin/sh
[ "$1" = core_restart ] || exit 1
echo "$*" >> "$TEST_ROOT/restarts"
if [ "${FAIL_START:-0}" = 1 ] && [ "$(cat "$PODKOPCHIK_CORE_DIR/selected")" != rollback ]; then exit 1; fi
EOF
cat > "$tmp/lib/connection_check.sh" <<'EOF'
#!/bin/sh
if [ "${FAIL_PROBE:-0}" = 1 ]; then echo '{"status":"down"}'; exit 0; fi
echo '{"status":"up","external_ip":"192.0.2.1","latency_ms":84}'
EOF
cat > "$tmp/bin/opkg" <<'EOF'
#!/bin/sh
echo "$*" >> "$TEST_ROOT/opkg-commands"
case "$*" in
 update) exit 0 ;;
 'list xray-core') echo 'xray-core - 26.10.21-1 - Xray' ;;
 'upgrade xray-core') cp "$TEST_ROOT/new" "$TEST_ROOT/bin/xray" ;;
 *) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/"* "$tmp/init" "$tmp/lib/connection_check.sh"
script=root/usr/libexec/podkopchik/xray_update.sh

sh "$script" xray-status | grep -q 'installed=25.1.30'
sh "$script" xray-check official | grep -q 'latest=v26.10.21'
if TEST_ARCH=mips sh "$script" xray-check official > "$tmp/out" 2>&1; then exit 1; fi
grep -q 'unsupported architecture' "$tmp/out"
if TEST_FREE=1 sh "$script" xray-install official > "$tmp/out" 2>&1; then exit 1; fi
grep -q 'insufficient free space' "$tmp/out"
[ ! -d "$tmp/runtime/config-apply.lock" ]
mkdir "$tmp/runtime/health-check.lock"
if sh "$script" xray-install official > "$tmp/out" 2>&1; then exit 1; fi
grep -q 'health check is running' "$tmp/out"
rmdir "$tmp/runtime/health-check.lock"
if FAIL_CONFIG=1 sh "$script" xray-install official > "$tmp/out" 2>&1; then exit 1; fi
grep -q 'candidate rejected' "$tmp/out"
[ ! -f "$tmp/core/selected" ]
[ ! -f "$tmp/restarts" ]
cp "$tmp/metadata" "$tmp/metadata.good"
node -e 'const fs=require("fs");const p=process.argv[1];const m=JSON.parse(fs.readFileSync(p));m.assets[0].digest="sha256:"+"0".repeat(64);fs.writeFileSync(p,JSON.stringify(m))' "$tmp/metadata"
if sh "$script" xray-install official > "$tmp/out" 2>&1; then exit 1; fi
grep -q 'SHA256 mismatch' "$tmp/out"
[ ! -f "$tmp/core/selected" ]
cp "$tmp/metadata.good" "$tmp/metadata"
sh "$script" xray-install official > "$tmp/out"
grep -q 'status=verified' "$tmp/out"
[ "$(cat "$tmp/core/selected")" = official ]
[ "$("$tmp/bin/xray" version)" = 'Xray 25.1.30' ]
[ "$("$tmp/core/xray" version)" = 'Xray 26.10.21' ]
cmp "$tmp/config/config.json" "$tmp/original-config"
sh "$script" xray-rollback > "$tmp/out"
grep -q 'installed=25.1.30' "$tmp/out"
if FAIL_START=1 sh "$script" xray-install official > "$tmp/out" 2>&1; then exit 1; fi
grep -q 'previous executable restored' "$tmp/out"
[ "$(cat "$tmp/core/selected")" = rollback ]
[ "$("$tmp/core/xray" version)" = 'Xray 25.1.30' ]
if FAIL_PROBE=1 sh "$script" xray-install official > "$tmp/out" 2>&1; then exit 1; fi
grep -q 'previous executable restored' "$tmp/out"
[ "$("$tmp/core/xray" version)" = 'Xray 25.1.30' ]
if FAKE_ANSWER=192.0.2.1 sh "$script" xray-install official > "$tmp/out" 2>&1; then exit 1; fi
grep -q 'previous executable restored' "$tmp/out"
[ "$("$tmp/core/xray" version)" = 'Xray 25.1.30' ]
echo 'option check_signature 0' > "$tmp/opkg.conf"
if sh "$script" xray-check package > "$tmp/out" 2>&1; then exit 1; fi
grep -q 'signature checking must be enabled' "$tmp/out"
echo 'option check_signature' > "$tmp/opkg.conf"
sh "$script" xray-install package > "$tmp/out"
grep -q 'status=verified' "$tmp/out"
[ "$(cat "$tmp/core/selected")" = package ]
grep -qx 'upgrade xray-core' "$tmp/opkg-commands"
! grep -qx 'upgrade' "$tmp/opkg-commands"
cmp "$tmp/config/config.json" "$tmp/original-config"
[ ! -d "$tmp/runtime/xray-update.lock" ]
echo 'Xray update/rollback smoke OK (mocked router, no live upgrade)'
