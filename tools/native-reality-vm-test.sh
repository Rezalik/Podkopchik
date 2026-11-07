#!/bin/sh
# Independent validation of the public laboratory Reality endpoint.
set -eu
umask 077
. /mnt/lab/native-vm-only.sh
. /mnt/lab/native-vm-binaries.sh
out=$(mktemp -d /tmp/pkc-reality.XXXXXX)
r=pkc-reality-r-$$; w=pkc-reality-w-$$; pids=''
cleanup() { for p in $pids; do kill "$p" 2>/dev/null || true; done; for p in $pids; do wait "$p" 2>/dev/null || true; done; ip netns del "$r"; ip netns del "$w"; }
trap cleanup EXIT
ip netns add "$r"; ip netns add "$w"
ip -n "$r" link set lo up; ip -n "$w" link set lo up
ip -n "$r" link add wan type veth peer name peer
ip -n "$r" link set peer netns "$w"
ip -n "$r" link set wan up; ip -n "$w" link set peer up
ip -n "$r" addr add 192.0.2.1/24 dev wan
ip -n "$w" addr add 192.0.2.2/24 dev peer
ip -n "$w" addr add 203.0.113.80/32 dev lo
bin="$PKC_VM_BIN/native-dns.test"; xray="$PKC_VM_BIN/xray"
PKC_NATIVE_LAB=https-serve ip netns exec "$w" "$bin" -test.run='^TestGuestFixture$' -- 203.0.113.80:18084 "$out/tls.der" > "$out/tls.log" 2>&1 & pids="$pids $!"
PKC_NATIVE_LAB=serve ip netns exec "$w" "$bin" -test.run='^TestGuestFixture$' -- 203.0.113.80:18081 > "$out/http.log" 2>&1 & pids="$pids $!"
ucode -e 'import {readfile} from "fs"; let c=json(readfile(ARGV[0]));c.log.loglevel="debug";printf("%J",c);' "$1" > "$out/server.json"
ucode -e 'import {readfile} from "fs";let c=json(readfile(ARGV[0]));c.log.loglevel="debug";
	c.inbounds=[{tag:"socks",listen:"127.0.0.1",port:19080,protocol:"socks",settings:{auth:"noauth"}}];
	c.routing.rules=[{type:"field",inboundTag:["socks"],outboundTag:"vless_vm"}];printf("%J",c);' "$2" > "$out/client.json"
ip netns exec "$w" "$xray" run -config "$out/server.json" > "$out/server.log" 2>&1 & pids="$pids $!"
ip netns exec "$r" "$xray" run -config "$out/client.json" > "$out/client.log" 2>&1 & pids="$pids $!"
sleep 2
if ! PKC_NATIVE_LAB=socks ip netns exec "$r" "$bin" -test.run='^TestGuestFixture$' -- 127.0.0.1:19080 203.0.113.80:18081; then
	cat "$out/server.log" "$out/client.log" "$out/http.log" "$out/tls.log"
	exit 1
fi
echo 'PASS: isolated Reality endpoint independently returned HTTP without Native routing'
