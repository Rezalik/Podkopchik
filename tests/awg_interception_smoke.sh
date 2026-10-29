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
 *main.udp_interception) [ -z "${UDP+x}" ] && exit 1; echo "$UDP" ;;
 *main.ipv6_interception) [ -z "${IPV6+x}" ] && exit 1; echo "$IPV6" ;;
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
 'rule show') [ ! -f "$rule" ] || printf '10991:\tfrom all fwmark 0x100000 lookup 10991 \t\n' ;;
 'route show table 10991')
  if [ -f "$route" ]; then
   if [ "${FOREIGN_ROUTE:-0}" = 1 ]; then
    echo 'local default dev other0 scope host '
   elif [ "$family" = 6 ]; then
    printf 'local default dev lo metric 1024 pref medium \t\n'
   else
    printf 'local default dev lo scope host \t\n'
   fi
  fi
  ;;
 'rule add '* ) touch "$rule" ;;
 'route add '* ) touch "$route" ;;
 'rule del '* ) rm -f "$rule" ;;
 'route del '* ) rm -f "$route" ;;
 *) exit 1 ;;
esac
EOF
cat > "$root/bin/ucode" <<'EOF'
#!/bin/sh
case "$*" in *interception-preflight*) [ "${NO_IPV6:-0}" = 0 ] ;; *) exit 1 ;; esac
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
grep -q 'meta l4proto tcp.*tproxy ip to :12345 accept' "$root/committed"
grep -q 'dns_prerouting.*udp dport 53 redirect to :1053' "$root/committed"
apply
test "$(grep -c 'tproxy ip to :12345 accept' "$root/committed")" = 1
cp "$root/committed" "$root/previous"
if env FOREIGN_ROUTE=1 sh root/usr/libexec/podkopchik/apply_rules.sh apply 2>"$root/foreign-error"; then
 echo 'FAIL: whitespace normalization accepted a foreign route'; exit 1
fi
grep -q 'owned policy route changed' "$root/foreign-error"
cmp "$root/previous" "$root/committed"
test -f "$root/rule4"
test -f "$root/route4"
if env FAIL_NFT=1 sh root/usr/libexec/podkopchik/apply_rules.sh apply 2>"$root/error"; then echo 'FAIL: nft error ignored'; exit 1; fi
cmp "$root/previous" "$root/committed"
test -f "$root/rule4"
test -f "$root/route4"
grep -q 'nft validation failed' "$root/error"
env EXTENDED=1 sh root/usr/libexec/podkopchik/apply_rules.sh apply
if [ -n "${PODKOPCHIK_TEST_NFT_BATCH:-}" ]; then cp "$root/committed" "$PODKOPCHIK_TEST_NFT_BATCH"; fi
grep -q 'meta l4proto udp.*tproxy to :12345 accept' "$root/committed"
test -f "$root/rule6"
test -f "$root/route6"
if grep -q 'dport 443.*drop' "$root/committed"; then echo 'FAIL: UDP443 blocking'; exit 1; fi
for udp in 0 1; do
 for ipv6 in 0 1; do
  env UDP="$udp" IPV6="$ipv6" sh root/usr/libexec/podkopchik/apply_rules.sh apply
  if [ -n "${PODKOPCHIK_TEST_NFT_DIR:-}" ]; then cp "$root/committed" "$PODKOPCHIK_TEST_NFT_DIR/udp$udp-ipv6$ipv6.nft"; fi
  test "$(grep -c 'l4proto udp.*tproxy' "$root/committed" || true)" = "$udp"
  if [ "$ipv6" = 1 ]; then
   test -f "$root/rule6"
   ! grep -q 'nfproto ipv4.*tproxy' "$root/committed"
  else
   test ! -f "$root/rule6"
   grep -q 'nfproto ipv4.*l4proto tcp.*tproxy ip to' "$root/committed"
  fi
  grep -q 'ff00::/8' "$root/committed"
  dns_line="$(grep -n 'th dport 53 return' "$root/committed" | cut -d: -f1)"
  tcp_line="$(grep -n 'l4proto tcp.*tproxy' "$root/committed" | cut -d: -f1)"
  bypass_line="$(grep -n 'ip daddr @proxy_bypass4 return' "$root/committed" | cut -d: -f1)"
  test "$dns_line" -lt "$tcp_line"
  test "$bypass_line" -lt "$tcp_line"
 done
done
cp "$root/committed" "$root/previous"
if env UDP=0 IPV6=1 NO_IPV6=1 sh root/usr/libexec/podkopchik/apply_rules.sh apply 2>"$root/error"; then
 echo 'FAIL: unsupported IPv6 accepted'; exit 1
fi
grep -q 'IPv6 interception requires' "$root/error"
cmp "$root/previous" "$root/committed"
apply
test ! -f "$root/rule6"
test ! -f "$root/route6"
sh root/usr/libexec/podkopchik/cleanup_rules.sh
test ! -f "$root/committed"
test ! -f "$root/rule4"
test ! -f "$root/route4"
echo 'AWG interception MOCK smoke OK: atomic replacement, failure retention, idempotency, opt-in UDP/IPv6, scoped cleanup'
