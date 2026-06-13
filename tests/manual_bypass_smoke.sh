#!/bin/sh

set -eu

tmp="tests/.tmp.manual-bypass.$$"
rm -rf "$tmp"
mkdir -p "$tmp"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/uci" <<'EOF'
#!/bin/sh

[ "$1" = "-q" ] && shift
[ "${1:-}" = "get" ] || exit 1

case "${2:-}" in
	podkopchik.main.routing_enabled) echo "0" ;;
	podkopchik.main.transparent_port) echo "12345" ;;
	podkopchik.main.lan_ifname) echo "br-lan" ;;
	podkopchik.main.dns_redirect) echo "0" ;;
	podkopchik.main.fakedns_enabled) echo "1" ;;
	podkopchik.main.fakedns_hijack_dns) echo "1" ;;
	podkopchik.main.fakedns_port) echo "1053" ;;
	podkopchik.main.fakedns_pool_v4) echo "198.18.0.0/15" ;;
	podkopchik.@proxy\[0\]|podkopchik.@proxy\[1\]) echo "proxy" ;;
	podkopchik.@proxy\[0\].uri) echo "vless://11111111-2222-3333-4444-555555555555@203.0.113.10:443?type=tcp&security=reality&sni=example.invalid&pbk=FAKE&sid=abcd" ;;
	podkopchik.@proxy\[1\].uri) echo "vless://11111111-2222-3333-4444-555555555555@proxy.example.com:443?type=tcp&security=reality&sni=proxy.example.com&pbk=FAKE&sid=abcd" ;;
	podkopchik.@bypass_rule\[0\]|podkopchik.@bypass_rule\[1\]|podkopchik.@bypass_rule\[2\]|podkopchik.@bypass_rule\[3\]|podkopchik.@bypass_rule\[4\]) echo "bypass_rule" ;;
	podkopchik.@bypass_rule\[0\].enabled) echo "1" ;;
	podkopchik.@bypass_rule\[0\].host) echo "5.42.117.16" ;;
	podkopchik.@bypass_rule\[1\].enabled) echo "1" ;;
	podkopchik.@bypass_rule\[1\].host) echo "192.0.2.0/24" ;;
	podkopchik.@bypass_rule\[2\].enabled) echo "1" ;;
	podkopchik.@bypass_rule\[2\].host) echo "panel.example.com" ;;
	podkopchik.@bypass_rule\[3\].enabled) echo "1" ;;
	podkopchik.@bypass_rule\[3\].host) echo "2001:db8:abcd::/48" ;;
	podkopchik.@bypass_rule\[4\].enabled) echo "0" ;;
	podkopchik.@bypass_rule\[4\].host) echo "198.51.100.200" ;;
	*) exit 1 ;;
esac
EOF

cat > "$tmp/cleanup" <<'EOF'
#!/bin/sh

echo cleanup >> "$PODKOPCHIK_TEST_LOG"
EOF

cat > "$tmp/ip" <<'EOF'
#!/bin/sh

if [ "${1:-}" = "-V" ]; then
	echo "ip utility, iproute2-6.11.0"
	exit 0
fi

echo "ip $*" >> "$PODKOPCHIK_TEST_LOG"
exit 0
EOF

cat > "$tmp/nft" <<'EOF'
#!/bin/sh

echo "nft $*" >> "$PODKOPCHIK_TEST_LOG"
exit 0
EOF

cat > "$tmp/ucode" <<'EOF'
#!/bin/sh

uri="${4:-}"

case "$uri" in
	*@203.0.113.10:443*) echo '{"host":"203.0.113.10"}' ;;
	*@proxy.example.com:443*) echo '{"host":"proxy.example.com"}' ;;
	*) exit 1 ;;
esac
EOF

cat > "$tmp/jsonfilter" <<'EOF'
#!/bin/sh

json="$(cat)"

case "$json" in
	*'"host":"203.0.113.10"'*) echo "203.0.113.10" ;;
	*'"host":"proxy.example.com"'*) echo "proxy.example.com" ;;
	*) exit 1 ;;
esac
EOF

cat > "$tmp/resolve" <<'EOF'
#!/bin/sh

case "${1:-}" in
	proxy.example.com)
		echo "198.51.100.22"
		echo "2001:db8::22"
		;;
	panel.example.com)
		echo "198.51.100.77"
		;;
	*)
		exit 1
		;;
esac
EOF

chmod +x "$tmp/uci" "$tmp/cleanup" "$tmp/ip" "$tmp/nft" "$tmp/ucode" "$tmp/jsonfilter" "$tmp/resolve"

log="$tmp/apply.log"
err="$tmp/apply.err"

PODKOPCHIK_TEST_LOG="$log" \
	PODKOPCHIK_TMP_DIR="$tmp/runtime" \
	PODKOPCHIK_CLEANUP="$tmp/cleanup" \
	PODKOPCHIK_IP="$tmp/ip" \
	PODKOPCHIK_NFT="$tmp/nft" \
	PODKOPCHIK_UCODE="$tmp/ucode" \
	PODKOPCHIK_JSONFILTER="$tmp/jsonfilter" \
	PODKOPCHIK_RESOLVER="$tmp/resolve" \
	PATH="$tmp:$PATH" \
	sh root/usr/libexec/podkopchik/apply_rules.sh apply 2>"$err"

grep -q "nft add element inet podkopchik proxy_bypass4 { .*203.0.113.10" "$log"
grep -q "nft add element inet podkopchik proxy_bypass4 { .*198.51.100.22" "$log"
grep -q "nft add element inet podkopchik proxy_bypass4 { .*5.42.117.16" "$log"
grep -q "nft add element inet podkopchik proxy_bypass4 { .*192.0.2.0/24" "$log"
grep -q "nft add element inet podkopchik proxy_bypass4 { .*198.51.100.77" "$log"
grep -q "nft add element inet podkopchik proxy_bypass6 { .*2001:db8::22" "$log"
grep -q "nft add element inet podkopchik proxy_bypass6 { .*2001:db8:abcd::/48" "$log"
! grep -q "198.51.100.200" "$log"
! grep -q "nft add element inet podkopchik reserved4 .*198.18.0.0/15" "$log"
grep -q "nft add rule inet podkopchik prerouting iifname br-lan ip daddr @proxy_bypass4 return" "$log"
grep -q "nft add rule inet podkopchik prerouting iifname br-lan ip6 daddr @proxy_bypass6 return" "$log"
grep -q "nft add rule inet podkopchik prerouting iifname br-lan meta l4proto tcp meta mark set 0x100000 tproxy to :12345 accept" "$log"

bypass_line="$(grep -n "ip daddr @proxy_bypass4 return" "$log" | head -n 1 | cut -d: -f1)"
tproxy_line="$(grep -n "meta l4proto tcp meta mark set 0x100000 tproxy to :12345 accept" "$log" | head -n 1 | cut -d: -f1)"

[ -n "$bypass_line" ] && [ -n "$tproxy_line" ] && [ "$bypass_line" -lt "$tproxy_line" ]

grep -q '^proxy_bypass4=.*203.0.113.10.*198.51.100.22.*5.42.117.16.*192.0.2.0/24.*198.51.100.77' "$tmp/runtime/proxy_bypass.env"
grep -q '^proxy_bypass6=.*2001:db8::22.*2001:db8:abcd::/48' "$tmp/runtime/proxy_bypass.env"

echo "manual bypass smoke OK"
