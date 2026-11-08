#!/bin/sh
# Disposable no-NIC OpenWrt VM only; exercises the real sampling entry point.
set -eu
if [ ! -f /proc/device-tree/model ]; then
	echo 'SKIP: observer retirement fixture needs a disposable OpenWrt VM'
	exit 0
fi
case "$(tr -d '\000' < /proc/device-tree/model)" in *dummy-virt*) ;; *) echo 'SKIP: disposable OpenWrt VM only'; exit 0 ;; esac
[ ! -d /sys/class/net/eth0 ]
umask 077
src=/mnt/lab/observer-cleanup
work=$(mktemp -d /tmp/pkc-native-observe.XXXXXX)
mkdir -p /tmp/sysinfo /etc/podkopchik/native-state /tmp/podkopchik
printf '%s\n' xiaomi,redmi-router-ax6000-stock > /tmp/sysinfo/board_name
printf '%s\n' '{"phase":"active","repair":false}' > /etc/podkopchik/native-state/runtime.json
printf '%s\n' '{"compiled":{"adapters":{}},"automatic":{},"dns":{}}' > /tmp/podkopchik/native-runtime-plan.json
printf '%s\n' '{"proxies":{}}' > /tmp/podkopchik/state.json
ucode -e 'import {readfile,writefile} from "fs";let mono=int(split(readfile("/proc/uptime")," ")[0]);
	writefile(ARGV[0]+"/config.json",sprintf("%J",{owner:"pkc-native-observe-v1",started_epoch:time(),deadline_epoch:time()+3600,
		started_mono:mono,deadline_mono:mono+3600,boot:trim(readfile("/proc/sys/kernel/random/boot_id")),
		helper:ARGV[1]+"/helper",transports:[],interval:60,probe_interval:900,log_limit:524288}));
	writefile(ARGV[0]+"/summary.json",sprintf("%J",{schema:1,samples:0,last_probe_mono:mono}));' "$work" "$src"
chmod 600 "$work/config.json" "$work/summary.json"
test ! -e /etc/podkopchik-native-emergency/state.json
ucode -c -o /tmp/native-observe.ucb -L "$src" "$src/native-observe.uc"
ucode -L "$src" "$src/native_observe_smoke.uc"
ucode -L "$src" "$src/native-observe.uc" sample "$work"
ucode -e 'import {readfile} from "fs";let s=json(readfile(ARGV[0]+"/summary.json"));
	if(s.samples!=1||s.last.emergency.required||s.last.emergency.attention||index(s.last.warnings,"emergency_not_ready")>=0)
		die("transactional observation incorrectly requires emergency capsule");' "$work"
printf '%s\n' '{"phase":"active","repair":true}' > /etc/podkopchik/native-state/runtime.json
if ucode -L "$src" "$src/native-observe.uc" sample "$work" >/dev/null 2>&1; then
	echo 'Missing repair capsule was not rejected.' >&2
	exit 1
fi
echo 'PASS: real observer samples without retired capsule; repair still rejects a missing capsule'
