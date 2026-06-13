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
	option fakedns_enabled '0'
	option fakedns_port '1053'
	option fakedns_listen ''
	option fakedns_pool_v4 '198.18.0.0/15'
	option fakedns_pool_size '65535'
	option fakedns_hijack_dns '0'
EOF

disabled="$tmp/disabled.json"
UCI_CONFIG_DIR="$tmp" ucode -L root/usr/libexec/podkopchik root/usr/libexec/podkopchik/generate.uc > "$disabled"
jsonfilter -q -i "$disabled" -e '@.routing.domainStrategy' >/dev/null

! grep -q '"dns-in"' "$disabled"
! grep -q '"dns-out"' "$disabled"
! grep -q '"fakedns"' "$disabled"
! grep -q '"dns"' "$disabled"

cat > "$tmp/podkopchik" <<'EOF'
config settings 'main'
	option transparent_port '12345'
	option loglevel 'warning'
	option fakedns_enabled '1'
	option fakedns_port '1053'
	option fakedns_listen ''
	option fakedns_pool_v4 '198.18.0.0/15'
	option fakedns_pool_size '65535'
	option fakedns_hijack_dns '0'
EOF

enabled="$tmp/enabled.json"
UCI_CONFIG_DIR="$tmp" ucode -L root/usr/libexec/podkopchik root/usr/libexec/podkopchik/generate.uc > "$enabled"
jsonfilter -q -i "$enabled" -e '@.dns.servers[0]' | grep -qx 'fakedns'
jsonfilter -q -i "$enabled" -e '@.fakedns.ipPool' | grep -qx '198.18.0.0/15'
jsonfilter -q -i "$enabled" -e '@.fakedns.poolSize' | grep -qx '65535'
jsonfilter -q -i "$enabled" -e '@.inbounds[1].tag' | grep -qx 'dns-in'
jsonfilter -q -i "$enabled" -e '@.inbounds[1].listen' | grep -qx '127.0.0.1'
jsonfilter -q -i "$enabled" -e '@.inbounds[1].port' | grep -qx '1053'
jsonfilter -q -i "$enabled" -e '@.outbounds[2].tag' | grep -qx 'dns-out'
jsonfilter -q -i "$enabled" -e '@.routing.rules[0].inboundTag[0]' | grep -qx 'dns-in'
jsonfilter -q -i "$enabled" -e '@.routing.rules[0].outboundTag' | grep -qx 'dns-out'
jsonfilter -q -i "$enabled" -e '@.inbounds[0].sniffing.destOverride[*]' | grep -qx 'fakedns'

cat > "$tmp/podkopchik" <<'EOF'
config settings 'main'
	option transparent_port '12345'
	option loglevel 'warning'
	option fakedns_enabled '1'
	option fakedns_port '1053'
	option fakedns_listen ''
	option fakedns_pool_v4 '198.18.0.0/15'
	option fakedns_pool_size '65535'
	option fakedns_hijack_dns '1'
EOF

hijack="$tmp/hijack.json"
UCI_CONFIG_DIR="$tmp" ucode -L root/usr/libexec/podkopchik root/usr/libexec/podkopchik/generate.uc > "$hijack"
jsonfilter -q -i "$hijack" -e '@.inbounds[1].tag' | grep -qx 'dns-in'
jsonfilter -q -i "$hijack" -e '@.inbounds[1].listen' | grep -qx '0.0.0.0'

cat > "$tmp/podkopchik" <<'EOF'
config settings 'main'
	option transparent_port '12345'
	option loglevel 'warning'
	option fakedns_enabled '1'
	option fakedns_port '1053'
	option fakedns_listen '192.168.8.1'
	option fakedns_pool_v4 '198.18.0.0/15'
	option fakedns_pool_size '65535'
	option fakedns_hijack_dns '1'
EOF

override="$tmp/override.json"
UCI_CONFIG_DIR="$tmp" ucode -L root/usr/libexec/podkopchik root/usr/libexec/podkopchik/generate.uc > "$override"
jsonfilter -q -i "$override" -e '@.inbounds[1].listen' | grep -qx '192.168.8.1'

echo "generate FakeDNS smoke OK"
