#!/bin/sh
set -eu
if ! command -v ucode >/dev/null 2>&1 || ! command -v jsonfilter >/dev/null 2>&1; then
	echo 'SKIP: connection config generation needs ucode + uci/fs modules + jsonfilter'
	exit 0
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/podkopchik" <<'EOF'
config settings 'main'
 option fakedns_enabled '1'
config proxy
 option enabled '1'
 option role 'main'
 option tag 'fixture'
 option uri 'vless://11111111-2222-3333-4444-555555555555@example.invalid:443?type=tcp&security=reality&sni=example.invalid&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=abcd#synthetic'
EOF
export UCI_CONFIG_DIR="$tmp"
export PODKOPCHIK_PROBE_URI='vless://11111111-2222-3333-4444-555555555555@example.invalid:443?type=tcp&security=reality&sni=example.invalid&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=abcd#synthetic'
gen=root/usr/libexec/podkopchik/generate.uc
ucode -L root/usr/libexec/podkopchik "$gen" probe-uri > "$tmp/config.json"
jsonfilter -q -i "$tmp/config.json" -e '@.inbounds[0].port' | grep -qx 20999
jsonfilter -q -i "$tmp/config.json" -e '@.outbounds[0].tag' | grep -qx probe
! grep -q fakedns "$tmp/config.json"
ucode -L root/usr/libexec/podkopchik "$gen" probe-primary > "$tmp/primary.json"
cmp "$tmp/config.json" "$tmp/primary.json"
ucode -L root/usr/libexec/podkopchik "$gen" health fixture 20800 > "$tmp/health.json"
jsonfilter -q -i "$tmp/health.json" -e '@.routing.rules[0].outboundTag' | grep -qx fixture
if command -v xray >/dev/null 2>&1; then
 xray run -test -config "$tmp/config.json" > "$tmp/validate.log" 2>&1
fi
echo 'Connection config generation smoke OK (synthetic fixture)'
