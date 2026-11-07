#!/bin/sh
# Diagnostic queries only: no shared service, interface or routing changes.
set -eu
umask 077
[ "$(cat /tmp/sysinfo/board_name)" = xiaomi,redmi-router-ax6000-stock ] || exit 2
helper=${1:?helper path required}
capture=${2:?directory containing verified tcpdump and libpcap required}
work=$(mktemp -d /tmp/pkc-dot-check.XXXXXX)
cap=
cleanup() {
	for p in $cap; do kill -INT "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
printf '%s\n' "$work"
make_state() {
	ucode -e 'import * as fs from "fs";
		const v=json(fs.readfile(ARGV[0])),i=+trim(fs.readfile("/sys/class/net/"+v.interface+"/ifindex"));
		const endpoints=ARGV[1]=="fail"?[{address:"1.1.1.1:853",name:"wrong-name.invalid"}]:
			ARGV[1]=="fallback"?[{address:"1.1.1.1:853",name:"wrong-name.invalid"},{address:"9.9.9.9:853",name:"dns.quad9.net"}]:
			[{address:"1.1.1.1:853",name:"one.one.one.one"},{address:"9.9.9.9:853",name:"dns.quad9.net"}];
		printf("%J\n",{schema:1,endpoints,transports:[{tag:"awg_"+v.id,type:"amneziawg",interface:v.interface,index:i+(ARGV[1]=="stale"?100000:0),mark:v.mark,ipv4:true,ipv6:false}]});
	' "$1" "$2" > "$work/state.json"
}
for resource in /tmp/podkopchik/awg/*.json; do
	case "$resource" in *.check.json) continue ;; esac
	id=$(jsonfilter -q -i "$resource" -e '@.id')
	interface=$(jsonfilter -q -i "$resource" -e '@.interface')
	[ -n "$id" ] && [ -n "$interface" ] || exit 2
	LD_LIBRARY_PATH="$capture" "$capture/tcpdump" -U -nn -i wan -s 96 -w "$work/$id-wan.pcap" \
		'(host 1.1.1.1 or host 9.9.9.9) and (port 53 or port 853)' > "$work/$id-wan.log" 2>&1 & wp=$!
	LD_LIBRARY_PATH="$capture" "$capture/tcpdump" -U -nn -i "$interface" -s 96 -w "$work/$id-awg.pcap" \
		'(host 1.1.1.1 or host 9.9.9.9) and port 853' > "$work/$id-awg.log" 2>&1 & ap=$!
	cap="$wp $ap"
	sleep 1
	make_state "$resource" normal
	"$helper" -protected-probe "$work/state.json" -probe-name www.youtube.com > "$work/$id-answer.json"
	make_state "$resource" fallback
	"$helper" -protected-probe "$work/state.json" -probe-name www.youtube.com > "$work/$id-backup.json"
	for mode in fail stale; do
		make_state "$resource" "$mode"
		if "$helper" -protected-probe "$work/state.json" -probe-name www.youtube.com > "$work/rejected.json" 2> "$work/rejected.err"; then
			echo "FAIL: $mode was accepted" >&2; exit 1
		fi
	done
	make_state "$resource" normal
	"$helper" -protected-probe "$work/state.json" -probe-name www.youtube.com > "$work/$id-recovered.json"
	sleep 1
	cleanup; cap=
	wan=$(LD_LIBRARY_PATH="$capture" "$capture/tcpdump" -nn -r "$work/$id-wan.pcap" 2>/dev/null | wc -l)
	awg=$(LD_LIBRARY_PATH="$capture" "$capture/tcpdump" -nn -r "$work/$id-awg.pcap" 2>/dev/null | wc -l)
	[ "$wan" = 0 ] && [ "$awg" -gt 0 ] || { echo "FAIL: capture WAN=$wan AWG=$awg"; exit 1; }
	printf 'PASS: %s TLS DNS, provider fallback, certificate refusal, stale interface refusal, recovery; WAN=%s AWG=%s\n' "$interface" "$wan" "$awg"
done
