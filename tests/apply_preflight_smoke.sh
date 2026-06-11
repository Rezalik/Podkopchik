#!/bin/sh

set -eu

tmp="tests/.tmp.apply-preflight.$$"
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
	*) exit 1 ;;
esac
EOF

cat > "$tmp/cleanup" <<'EOF'
#!/bin/sh

echo cleanup >> "$PODKOPCHIK_TEST_LOG"
EOF

cat > "$tmp/ip-busybox" <<'EOF'
#!/bin/sh

if [ "${1:-}" = "-V" ]; then
	echo "BusyBox v1.36.1 (OpenWrt) multi-call binary."
	exit 0
fi

echo "busybox ip does not support this command" >&2
exit 1
EOF

cat > "$tmp/ip-iproute2" <<'EOF'
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

chmod +x "$tmp/uci" "$tmp/cleanup" "$tmp/ip-busybox" "$tmp/ip-iproute2" "$tmp/nft"

log="$tmp/busybox.log"
err="$tmp/busybox.err"
if PODKOPCHIK_TEST_LOG="$log" \
	PODKOPCHIK_TMP_DIR="$tmp/runtime-busybox" \
	PODKOPCHIK_CLEANUP="$tmp/cleanup" \
	PODKOPCHIK_IP="$tmp/ip-busybox" \
	PODKOPCHIK_NFT="$tmp/nft" \
	PATH="$tmp:$PATH" \
	sh root/usr/libexec/podkopchik/apply_rules.sh apply 2>"$err"; then
	echo "FAIL: BusyBox ip unexpectedly passed apply preflight"
	exit 1
fi

grep -q "Missing required dependency: ip-full" "$err"
grep -q "BusyBox ip is not sufficient for fwmark policy routing" "$err"
grep -q "cleanup" "$log"
! grep -q "fwmark" "$log"

log="$tmp/iproute2.log"
err="$tmp/iproute2.err"
PODKOPCHIK_TEST_LOG="$log" \
	PODKOPCHIK_TMP_DIR="$tmp/runtime-iproute2" \
	PODKOPCHIK_CLEANUP="$tmp/cleanup" \
	PODKOPCHIK_IP="$tmp/ip-iproute2" \
	PODKOPCHIK_NFT="$tmp/nft" \
	PATH="$tmp:$PATH" \
	sh root/usr/libexec/podkopchik/apply_rules.sh apply 2>"$err"

grep -q "ip rule add fwmark 0x100000 table 10991 priority 10991" "$log"
grep -q "ip route add local default dev lo table 10991" "$log"
grep -q "nft add rule inet podkopchik prerouting iifname br-lan meta l4proto tcp meta mark set 0x100000 tproxy to :12345 accept" "$log"

echo "apply preflight smoke OK"
