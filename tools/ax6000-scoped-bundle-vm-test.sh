#!/bin/sh
# Prove the transferred package can start DNS, not just initialize its ledger.
set -eu
umask 077
. /mnt/lab/native-vm-only.sh
d=$(mktemp -d /tmp/pkc-bundle-test.XXXXXX)
r=pkc-bundle-router-$$; l=pkc-bundle-client-$$
up=; dp=
cleanup() {
	for p in $dp $up; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done
	for n in "$l" "$r"; do ip netns del "$n" 2>/dev/null || true; done
}
trap cleanup EXIT
cd "$d"
tar -xf /mnt/lab/scoped-retry.tar
sha256sum -c SHA256SUMS
ucode -e 'import { lstat, lsdir } from "fs";
	const dir=lstat("."); if(dir.uid!=0||dir.gid!=0||dir.mode!=0o700) die("unsafe bundle directory");
	for(let f in lsdir(".")){let s=lstat(f); if(s?.type!="file"||s.uid!=0||s.gid!=0||s.nlink!=1||s.mode!=(f=="podkopchik-native-dns"?0o700:0o600)) die("unsafe file: "+f);}
	print("PASS: every extracted archive member is regular, singly linked, root:root and private\n");'
get() { jsonfilter -i run.json -e "@.$1"; }
port=$(get port); epoch=$(get epoch); https=$(get https); ntp=$(get ntp); direct=$(get direct)
./podkopchik-native-dns -config "$d/pilot.dns" -ledger "$d/ledger" -init-ledger
for n in "$r" "$l"; do ip netns add "$n"; ip -n "$n" link set lo up; done
rn() { ip netns exec "$r" "$@"; }
ln() { ip netns exec "$l" "$@"; }
rn ip link add "$port" type veth peer name client0 netns "$l"
rn ip -4 addr add 172.31.252.1/30 dev "$port"
ln ip -4 addr add 172.31.252.2/30 dev client0
rn ip link set dev "$port" up
ln ip link set dev client0 up
ln ip -4 route add default via 172.31.252.1
rn nft -f - <<'NFT'
add table inet fw4
add chain inet fw4 input { type filter hook input priority filter; policy drop; }
add rule inet fw4 input iifname "lo" accept
add chain inet fw4 forward { type filter hook forward priority filter; policy drop; }
NFT
rn nft -c -f pilot.nft
rn nft -f pilot.nft
ip netns exec "$r" /usr/sbin/dnsmasq --conf-file=/dev/null --keep-in-foreground --no-hosts --no-resolv --bind-interfaces \
	--listen-address=127.0.0.1 --port=24156 --local-ttl=60 --pid-file="$d/upstream.pid" \
	--host-record="www.cloudflare.com,$https" --host-record="time.cloudflare.com,$ntp" > "$d/upstream.log" 2>&1 & up=$!
ip netns exec "$r" "$d/podkopchik-native-dns" -config "$d/pilot.dns" -ledger "$d/ledger" > "$d/classifier.log" 2>&1 & dp=$!
live="s_${epoch}_live4"
for i in 1 2 3 4 5 6; do rn nft get element inet pkc_virtual_guard "$live" '{ 172.31.252.2 }' >/dev/null 2>&1 && break; sleep 1; done
if ! rn nft get element inet pkc_virtual_guard "$live" '{ 172.31.252.2 }' >/dev/null; then cat "$d/upstream.log" "$d/classifier.log"; exit 1; fi
fake=$(ln /mnt/lab/retry-pilot-probe lookup 172.31.252.1:53 udp www.cloudflare.com)
case "$fake" in 172.31.253.*) ;; *) exit 1 ;; esac
[ "$(ln /mnt/lab/retry-pilot-probe lookup "$direct:53" tcp www.cloudflare.com)" = "$fake" ]
rn nft get element inet pkc_virtual_guard "s_${epoch}_m4" "{ $fake }" | grep -Fq ": $https"
kill -0 "$up" && kill -0 "$dp"
echo 'PASS: archive classifier served UDP and redirected TCP DNS, published the same synthetic A and DNAT mapping'
