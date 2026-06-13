#!/bin/sh

set -eu

if ! command -v ucode >/dev/null 2>&1; then
	echo "SKIP: ucode not available"
	exit 0
fi

if ! command -v jsonfilter >/dev/null 2>&1; then
	echo "SKIP: jsonfilter not available"
	exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/podkopchik" <<'EOF'
config settings 'main'
	option transparent_port '12345'
	option loglevel 'warning'

config proxy
	option enabled '1'
	option name 'gerWARP'
	option tag 'gerwarp'
	option uri 'vless://11111111-2222-3333-4444-555555555555@proxy.example.com:443?type=tcp&security=reality&sni=proxy.example.com&pbk=FAKE&sid=abcd'

config proxy_group
	option enabled '1'
	option name 'Automatic proxy group'
	option tag 'auto_proxy_group'
	option mode 'strict_primary'
	option primary 'gerwarp'

config bypass_rule
	option enabled '1'
	option host 'panel.example.com'
	option comment 'panel direct'

config bypass_rule
	option enabled '1'
	option host '5.42.117.16'
	option comment 'IP direct'

config domain_rule
	option enabled '1'
	list domain 'panel.example.com'
	list domain 'x.com'
	option target 'auto_proxy_group'
	option group_name 'X'
	option group_tag 'x'
EOF

out="$tmp/config.json"
UCI_CONFIG_DIR="$tmp" ucode -L root/usr/libexec/podkopchik root/usr/libexec/podkopchik/generate.uc > "$out"

jsonfilter -q -i "$out" -e '@.routing.rules[1].outboundTag' | grep -qx 'direct'
jsonfilter -q -i "$out" -e '@.routing.rules[1].domain[*]' | grep -qx 'domain:panel.example.com'
! jsonfilter -q -i "$out" -e '@.routing.rules[1].domain[*]' | grep -qx 'domain:5.42.117.16'
jsonfilter -q -i "$out" -e '@.routing.rules[2].domain[*]' | grep -qx 'domain:x.com'
jsonfilter -q -i "$out" -e '@.routing.rules[2].outboundTag' | grep -qx 'gerwarp'

echo "generate manual bypass smoke OK"
