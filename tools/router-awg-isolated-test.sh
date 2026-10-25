#!/bin/sh
# Explicit, temporary AX6000 IPv4 proof. Not a Podkopchik deployment.
set -eu
umask 077
[ "${1:-}" = --run ] && [ "$#" = 2 ] || { echo 'Usage: sh router-awg-isolated-test.sh --run PROFILE_ID' >&2; exit 2; }
id="$2"
case "$id" in ''|*[!a-f0-9]*) exit 2 ;; esac
[ "${#id}" = 32 ]
[ "$(cat /tmp/sysinfo/board_name)" = xiaomi,redmi-router-ax6000-stock ]
[ "$(uname -r)" = 6.12.112 ]
[ "$(cat /proc/sys/net/ipv4/conf/all/rp_filter)" = 0 ]
[ -s /root/podkopchik-before-awg23.tar.gz ]
dev=pawkztest0
table=47621
priority=25621
mark=536918533
port=20998
ip link show "$dev" >/dev/null 2>&1 && exit 1
[ -z "$(ip -4 route show table "$table" 2>/dev/null || true)" ]
[ -z "$(ip -4 rule show | awk '$1 == "25621:" || /0x2000ba05/')" ]
if netstat -lnt 2>/dev/null | grep -q ":$port "; then echo 'Probe port occupied' >&2; exit 1; fi
mkdir /tmp/podkopchik-awg23-probe.lock
work="$(mktemp -d /tmp/podkopchik-awg23-test.XXXXXX)" || { rmdir /tmp/podkopchik-awg23-probe.lock; exit 1; }
pid=''
made_dev=0
created_index=''
made_mark=0
made_oif=0
made_guard=0
cleanup() {
	if [ -n "$pid" ]; then
		case "$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)" in
			*"$work/probe.json"*)
				kill "$pid" 2>/dev/null || true
				sleep 1
				kill -KILL "$pid" 2>/dev/null || true
				;;
		esac
		wait "$pid" 2>/dev/null || true
		pid=''
	fi
	if [ "$made_dev" = 1 ]; then
		alias="$(ip -d -j link show dev "$dev" 2>/dev/null | jsonfilter -e '@[0].ifalias' || true)"
		index="$(cat "/sys/class/net/$dev/ifindex" 2>/dev/null || true)"
		if [ "$alias" = podkopchik-awg23-test ] || { [ -n "$created_index" ] && [ "$index" = "$created_index" ] && [ -z "$alias" ]; }; then
			ip link del dev "$dev" || true
		fi
	fi
	[ "$made_mark" = 0 ] || ip -4 rule del priority "$priority" fwmark "$mark" table "$table" protocol 186 || true
	[ "$made_oif" = 0 ] || ip -4 rule del priority "$priority" oif "$dev" table "$table" protocol 186 || true
	[ "$made_guard" = 0 ] || ip -4 route del unreachable default metric 42760 proto 186 table "$table" || true
	rm -rf "$work"
	rmdir /tmp/podkopchik-awg23-probe.lock || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
main_before="$(ip -4 route show table main)"
rules_before="$(ip -4 rule show)"
nft_before="$(nft -s list table inet podkopchik | sha256sum)"
AWG_TEST_ID="$id" AWG_TEST_DIR="$work" ucode -L /usr/libexec/podkopchik -e '
import * as fs from "fs";
const awg = require("awg"), id = getenv("AWG_TEST_ID"), work = getenv("AWG_TEST_DIR");
try {
	let lock = fs.open("/etc/podkopchik/awg/.lock", "a+", 0o600);
	if (!lock || !lock.lock("xn")) die("busy");
	let meta = json(fs.readfile("/etc/podkopchik/awg/" + id + ".json"));
	if (meta.id != id || !match(meta.revision, /^[a-f0-9]{32}$/)) die("metadata");
	let parsed = awg.parse(fs.readfile("/etc/podkopchik/awg/" + id + "." + meta.revision + ".conf"));
	let lines = [], pub = {};
	for (let line in split(parsed.config, "\n")) {
		let field = trim(split(line, "=", 2)[0]), pos = index(line, "=");
		if (field == "Address" || field == "MTU") pub[field] = trim(substr(line, pos + 1));
		if (index([ "Address", "DNS", "MTU", "FwMark" ], field) < 0) push(lines, line);
	}
	if (!match(pub.Address || "", /^[0-9.]+\/32$/)) die("prototype requires one IPv4 /32");
	function put(path, value) {
		let f = fs.open(work + path, "wx", 0o600);
		if (!f) die("storage");
		f.write(value); f.close();
	}
	put("/kernel.conf", join("\n", lines));
	put("/public.json", sprintf("%J", pub));
	put("/probe.json", sprintf("%J", {
		log: {loglevel:"warning"}, dns: {tag:"probe-in",queryStrategy:"UseIPv4",servers:["tcp://1.1.1.1"]},
		inbounds:[{tag:"probe-in",listen:"127.0.0.1",port:20998,protocol:"socks",settings:{auth:"noauth",udp:false}}],
		outbounds:[{tag:"awg-test",protocol:"freedom",streamSettings:{sockopt:{interface:"pawkztest0",mark:536918533,domainStrategy:"ForceIPv4"}}}],
		routing:{rules:[{type:"field",inboundTag:["probe-in"],outboundTag:"awg-test"}]}
	}));
	lock.close();
} catch (e) { warn("Private profile preparation failed; values omitted\n"); exit(1); }
'
address="$(jsonfilter -i "$work/public.json" -e @.Address)"
mtu="$(jsonfilter -i "$work/public.json" -e @.MTU)"
[ -n "$mtu" ] || mtu=1280
ip -4 route get "${address%/*}" | grep -q ' via '
ip -4 route add unreachable default metric 42760 proto 186 table "$table"
made_guard=1
ip -4 rule add priority "$priority" fwmark "$mark" table "$table" protocol 186
made_mark=1
ip -4 rule add priority "$priority" oif "$dev" table "$table" protocol 186
made_oif=1
ip link add dev "$dev" type amneziawg
made_dev=1
created_index="$(cat "/sys/class/net/$dev/ifindex")"
ip link set dev "$dev" alias podkopchik-awg23-test
[ "$(cat "/sys/class/net/$dev/ifalias")" = podkopchik-awg23-test ]
if ! awg setconf "$dev" "$work/kernel.conf" >"$work/setconf.log" 2>&1; then
	echo 'AWG setconf failed; secret-bearing error output omitted' >&2
	exit 1
fi
rm -f "$work/kernel.conf"
awg set "$dev" fwmark 0
ip link set dev "$dev" mtu "$mtu" addrgenmode none
ip -4 address add "$address" dev "$dev" noprefixroute
ip link set dev "$dev" up
ip -4 route add default dev "$dev" metric 100 proto 186 table "$table"
curl --noproxy '*' --proto '=https' -fsS --max-time 15 --max-filesize 4096 \
	--interface "if!$dev" --resolve one.one.one.one:443:1.1.1.1 \
	https://one.one.one.one/cdn-cgi/trace -o "$work/direct.trace" -w 'AWG_DIRECT_HTTPS=%{http_code} TLS=%{ssl_verify_result} SECONDS=%{time_total}\n'
. /usr/libexec/podkopchik/xray.sh
bin="$(xray_bin)"
"$bin" run -test -config "$work/probe.json"
"$bin" run -config "$work/probe.json" >"$work/xray.log" 2>&1 &
pid="$!"
sleep 1
kill -0 "$pid"
netstat -lntp 2>/dev/null | awk -v p="$pid/" '$4 ~ /:20998$/ && index($NF,p)==1 { ok=1 } END { exit !ok }'
curl --noproxy '' --proto '=https' -fsS --max-time 15 --max-filesize 4096 \
	--socks5-hostname "127.0.0.1:$port" https://one.one.one.one/cdn-cgi/trace \
	-o "$work/xray.trace" -w 'XRAY_AWG_HTTPS=%{http_code} TLS=%{ssl_verify_result} SECONDS=%{time_total}\n'
handshake="$(awg show "$dev" latest-handshakes | awk '$2 > t {t=$2} END {printf "%.0f",t}')"
now="$(date +%s)"
[ "$handshake" -gt 0 ] && [ "$((now - handshake))" -ge 0 ] && [ "$((now - handshake))" -le 180 ]
printf 'HANDSHAKE_AGE_SECONDS=%s\n' "$((now - handshake))"
awg show "$dev" transfer | awk '{rx+=$2;tx+=$3}END{printf "RX_BYTES=%.0f TX_BYTES=%.0f\n",rx,tx}'
sed -n 's/^ip=/EXTERNAL_IP=/p' "$work/xray.trace"
cleanup
trap - EXIT HUP INT TERM
if ip link show "$dev" >/dev/null 2>&1; then echo 'FAIL: temporary interface remains' >&2; exit 1; fi
[ -z "$(ip -4 route show table "$table" 2>/dev/null || true)" ]
[ "$(ip -4 route show table main)" = "$main_before" ]
[ "$(ip -4 rule show)" = "$rules_before" ]
[ "$(nft -s list table inet podkopchik | sha256sum)" = "$nft_before" ]
echo 'ISOLATED_PROTOTYPE_PASS; MAIN_ROUTES_POLICY_NFT_UNCHANGED; TEMP_RESOURCES_REMOVED'
