#!/bin/sh

set -eu

tmp="tests/.tmp.fakedns-hijack.$$"
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
	podkopchik.main.fakedns_enabled) echo "${FAKEDNS_ENABLED:-0}" ;;
	podkopchik.main.fakedns_hijack_dns) echo "${FAKEDNS_HIJACK:-0}" ;;
	podkopchik.main.fakedns_port) echo "${FAKEDNS_PORT:-1053}" ;;
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

chmod +x "$tmp/uci" "$tmp/cleanup" "$tmp/ip" "$tmp/nft"

run_apply() {
	label="$1"
	enabled="$2"
	hijack="$3"
	log="$tmp/$label.log"
	err="$tmp/$label.err"

	FAKEDNS_ENABLED="$enabled" \
		FAKEDNS_HIJACK="$hijack" \
		FAKEDNS_PORT="1053" \
		PODKOPCHIK_TEST_LOG="$log" \
		PODKOPCHIK_TMP_DIR="$tmp/runtime-$label" \
		PODKOPCHIK_CLEANUP="$tmp/cleanup" \
		PODKOPCHIK_IP="$tmp/ip" \
		PODKOPCHIK_NFT="$tmp/nft" \
		PATH="$tmp:$PATH" \
		sh root/usr/libexec/podkopchik/apply_rules.sh apply 2>"$err"

	echo "$log"
}

disabled_log="$(run_apply disabled 0 0)"
! grep -q "dns_prerouting" "$disabled_log"

no_hijack_log="$(run_apply no-hijack 1 0)"
! grep -q "dns_prerouting" "$no_hijack_log"

hijack_log="$(run_apply hijack 1 1)"
grep -q "nft add chain inet podkopchik dns_prerouting { type nat hook prerouting priority dstnat; policy accept; }" "$hijack_log"
grep -q "nft add rule inet podkopchik dns_prerouting iifname br-lan udp dport 53 redirect to :1053" "$hijack_log"
grep -q "nft add rule inet podkopchik dns_prerouting iifname br-lan tcp dport 53 redirect to :1053" "$hijack_log"
grep -q "nft add chain inet podkopchik prerouting { type filter hook prerouting priority mangle; policy accept; }" "$hijack_log"
grep -q "nft add rule inet podkopchik prerouting iifname br-lan meta l4proto tcp meta mark set 0x100000 tproxy to :12345 accept" "$hijack_log"

grep -q "nft delete table inet podkopchik" root/usr/libexec/podkopchik/cleanup_rules.sh

echo "FakeDNS hijack smoke OK"
