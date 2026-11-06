#!/bin/sh
# Independent control through an existing AWG. No routing or firewall changes.
set -eu
umask 077
[ "$#" = 3 ] && [ "$(id -u)" = 0 ] || exit 2
[ "$(cat /tmp/sysinfo/board_name)" = xiaomi,redmi-router-ax6000-stock ] || exit 2
case "$PWD" in /tmp/pkc-udp-control.*) ;; *) exit 2 ;; esac
dev="$1"; dst="$2"; port="$3"
printf '%s\n' "$dev" | grep -Eq '^paw[0-9a-f]{12}$'
printf '%s\n' "$dst" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
case "$port" in ''|*[!0-9]*) exit 2 ;; esac
[ "$port" -ge 1024 ] && [ "$port" -le 65535 ]
sha256sum -c SHA256SUMS
wan=$(ubus call network.interface.wan status | jsonfilter -e '@.l3_device')
ip -4 route get "$dst" oif "$dev" | grep -Fq "dev $dev"
ip -d -j link show dev "$dev" | jsonfilter -e '@[0].linkinfo.info_kind' | grep -qx amneziawg
peer=$(awg show "$dev" endpoints | awk 'NR==1 {print $2} END{if(NR!=1)exit 1}')
printf '%s\n' "$peer" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]{1,5}$'
nft0=$(nft -s list ruleset | sha256sum)
ip0=$(ip -N -4 -j rule show | sha256sum)
export LD_LIBRARY_PATH="$PWD"
pids=
stop() {
	for p in $pids; do kill -INT "$p" 2>/dev/null || :; done
	for p in $pids; do wait "$p" || :; done
	pids=
}
trap stop EXIT
trap 'exit 1' HUP INT TERM
./tcpdump --immediate-mode -p -nn -U -Q inout -i "$dev" -s 80 -c 4096 -w awg.pcap \
	"udp and host $dst and port $port" >awg.log 2>&1 & pids="$!"
./tcpdump --immediate-mode -p -nn -U -Q out -i "$wan" -s 80 -c 4096 -w wan.pcap \
	"udp and ((dst host $dst and dst port $port) or (dst host ${peer%:*} and dst port ${peer##*:}))" >wan.log 2>&1 & pids="$pids $!"
for i in 1 2 3 4; do
	if grep -q 'listening on' awg.log && grep -q 'listening on' wan.log; then break; fi
	sleep 1
done
grep -q 'listening on' awg.log && grep -q 'listening on' wan.log
rc=0
./pilot-probe udp-echo "$dst:$port" "$dev" || rc=$?
for p in $pids; do kill -0 "$p" || exit 1; done
awk -v h="$dst" -v p="$port" '$3=="udp" && index($0,"dst=" h " ") && index($0,"dport=" p " ") {
	n++; for(i=1;i<=NF;i++) if($i ~ /^packets=/) printf "%s ",$i; print ""
} END {print "matching_conntrack=" n+0}' /proc/net/nf_conntrack
stop
count() { ./tcpdump -nn -r "$1" "$2" 2>/dev/null | wc -l; }
tx=$(count awg.pcap "dst host $dst and udp dst port $port")
rx=$(count awg.pcap "src host $dst and udp src port $port")
clear=$(count wan.pcap "dst host $dst and udp dst port $port")
outer=$(count wan.pcap "dst host ${peer%:*} and udp dst port ${peer##*:}")
printf 'AWG requests=%s replies=%s WAN clear=%s AWG outer=%s\n' "$tx" "$rx" "$clear" "$outer"
grep -qx '0 packets dropped by kernel' awg.log
grep -qx '0 packets dropped by kernel' wan.log
[ "$(nft -s list ruleset | sha256sum)" = "$nft0" ]
[ "$(ip -N -4 -j rule show | sha256sum)" = "$ip0" ]
echo 'nft and policy unchanged'
[ "$rc" = 0 ] && [ "$tx" -ge 4 ] && [ "$rx" -ge 4 ] && [ "$clear" = 0 ] && [ "$outer" -gt 0 ]
