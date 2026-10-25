#!/bin/sh
set -eu
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT HUP INT TERM
export AWG_TEST_ROOT="$root"
mkdir "$root/bin"
cat > "$root/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
 *main.routing_enabled) echo 1 ;;
 *main.transparent_port) echo 12345 ;;
 *main.lan_ifname) echo br-lan ;;
 *main.fakedns_enabled|*main.fakedns_hijack_dns) echo 1 ;;
 *main.fakedns_port) echo 1053 ;;
 *main.extended_interception) echo "${EXTENDED:-0}" ;;
 *) exit 1 ;;
esac
EOF
cat > "$root/bin/ip" <<'EOF'
#!/bin/sh
set -eu
[ "$*" != -V ] || { echo iproute2; exit; }
family=4
if [ "${1:-}" = -6 ]; then family=6; shift; fi
rule="$AWG_TEST_ROOT/rule$family"
route="$AWG_TEST_ROOT/route$family"
case "$*" in
 'rule show') [ ! -f "$rule" ] || echo '10991: from all fwmark 0x100000 lookup 10991' ;;
 'route show table 10991') [ ! -f "$route" ] || echo 'local default dev lo scope host' ;;
 'rule add '* ) touch "$rule" ;;
 'route add '* ) touch "$route" ;;
 'rule del '* ) rm -f "$rule" ;;
 'route del '* ) rm -f "$route" ;;
 *) exit 1 ;;
esac
EOF
cat > "$root/bin/nft" <<'EOF'
#!/bin/sh
set -eu
case "$*" in
 'list table inet podkopchik') test -f "$AWG_TEST_ROOT/committed" ;;
 '-c -f '*) [ "${FAIL_NFT:-0}" = 0 ] ;;
 '-f '*) cp "$2" "$AWG_TEST_ROOT/committed" ;;
 'delete table inet podkopchik') rm -f "$AWG_TEST_ROOT/committed" ;;
 *) exit 1 ;;
esac
EOF
chmod +x "$root/bin/"*
export PATH="$root/bin:$PATH"
export PODKOPCHIK_TMP_DIR="$root/runtime"
export PODKOPCHIK_IP=ip PODKOPCHIK_NFT=nft
apply() { sh root/usr/libexec/podkopchik/apply_rules.sh apply; }
apply
if grep -q 'l4proto udp' "$root/committed"; then echo 'FAIL: default UDP interception'; exit 1; fi
grep -q 'meta l4proto tcp.*tproxy to :12345 accept' "$root/committed"
grep -q 'dns_prerouting.*udp dport 53 redirect to :1053' "$root/committed"
apply
test "$(grep -c 'tproxy to :12345 accept' "$root/committed")" = 1
cp "$root/committed" "$root/previous"
if env FAIL_NFT=1 sh root/usr/libexec/podkopchik/apply_rules.sh apply 2>"$root/error"; then echo 'FAIL: nft error ignored'; exit 1; fi
cmp "$root/previous" "$root/committed"
test -f "$root/rule4"
test -f "$root/route4"
grep -q 'nft validation failed' "$root/error"
env EXTENDED=1 sh root/usr/libexec/podkopchik/apply_rules.sh apply
if [ -n "${PODKOPCHIK_TEST_NFT_BATCH:-}" ]; then cp "$root/committed" "$PODKOPCHIK_TEST_NFT_BATCH"; fi
grep -q 'udp udp dport != 53.*tproxy to :12345 accept' "$root/committed"
test -f "$root/rule6"
test -f "$root/route6"
if grep -q 'dport 443.*drop' "$root/committed"; then echo 'FAIL: UDP443 blocking'; exit 1; fi
apply
test ! -f "$root/rule6"
test ! -f "$root/route6"
sh root/usr/libexec/podkopchik/cleanup_rules.sh
test ! -f "$root/committed"
test ! -f "$root/rule4"
test ! -f "$root/route4"
echo 'AWG interception MOCK smoke OK: atomic replacement, failure retention, idempotency, opt-in UDP/IPv6, scoped cleanup'
