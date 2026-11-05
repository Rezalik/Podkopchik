#!/bin/sh
set -eu
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

extra_command() { :; }
. root/etc/init.d/podkopchik
xray_bin() { echo /usr/bin/xray; }
procd_open_instance() { instance="$1"; }
procd_set_param() { printf '%s %s\n' "$instance" "$*" >> "$tmp/params"; }
procd_close_instance() { :; }

# Full-cone behavior must not be disabled as a workaround for reply retention.
export XRAY_CONE_DISABLED=false
CONFIG=/etc/podkopchik/config.json
xray_instance
health_instance
[ "$XRAY_CONE_DISABLED" = false ]
! grep -q 'cone.disabled=true\|XRAY_CONE_DISABLED=true' "$tmp/params"
! grep -q '^health env ' "$tmp/params"
grep -qx 'xray command /usr/bin/xray run -config /etc/podkopchik/config.json' "$tmp/params"
grep -qx 'xray limits nofile=16384 16384' "$tmp/params"
! grep -q '^health limits ' "$tmp/params"

# Optional real-core syntax check. It binds no listener and uses no real keys.
if [ -n "${XRAY_TEST_BIN:-}" ]; then
	cat > "$tmp/config.json" <<'EOF'
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "transparent", "port": 12345, "protocol": "dokodemo-door",
      "settings": { "network": "tcp,udp", "followRedirect": true },
      "streamSettings": { "sockopt": { "tproxy": "tproxy" } },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic", "fakedns"] } },
    { "tag": "dns-in", "listen": "0.0.0.0", "port": 1053,
      "protocol": "dokodemo-door",
      "settings": { "network": "tcp,udp", "address": "8.8.8.8", "port": 53 } }
  ],
  "outbounds": [ { "tag": "direct", "protocol": "freedom" },
    { "tag": "dns-out", "protocol": "dns" } ],
  "dns": { "servers": ["fakedns"] },
  "fakedns": { "ipPool": "198.18.0.0/15", "poolSize": 65535 },
  "routing": { "rules": [
    { "type": "field", "inboundTag": ["dns-in"], "outboundTag": "dns-out" }
  ] }
}
EOF
	"$XRAY_TEST_BIN" run -test -config "$tmp/config.json" > "$tmp/test.log" 2>&1 || {
		cat "$tmp/test.log" >&2
		exit 1
	}
	grep -q 'Configuration OK' "$tmp/test.log"
	echo 'Xray real-core config syntax OK (no listeners or traffic started)'
else
	echo 'SKIP: real-core syntax check needs XRAY_TEST_BIN'
fi
echo 'Full-cone-preserving main startup smoke OK (mocked procd; not live TPROXY acceptance)'
