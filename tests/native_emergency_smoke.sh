#!/bin/sh
set -eu
file=root/usr/libexec/podkopchik/native_emergency.uc
grep -Fq "respawn:['3600','1','0']" "$file"
grep -Fq "s.mode=='armed'&&(s.boot!=BOOT||now()>=s.deadline)" "$file"
grep -Fq "if(management())bad=0" "$file"
grep -Fq 'baseline retained; independent rehearsal completed' "$file"
grep -Fq 'native-emergency-blocked' "$file"
grep -Fq "if(quick)return m" "$file"
grep -Fq "nft(guard(manifest,true),true)" "$file"
grep -Fq "if(m.repair)emergency('request')" root/usr/libexec/podkopchik/native_runtime.uc
grep -Fq 's.repair!==true && now >= s.deadline' root/usr/libexec/podkopchik/trial-state.uc
if grep -Eq 'flush ruleset|firewall restart|network restart|wifi reload|killall|reboot' "$file"; then exit 1; fi
sh -n root/etc/init.d/podkopchik-native-emergency
sh -n root/usr/libexec/podkopchik/native_boot_guard.sh
grep -Fq 'Native selected but generation metadata is missing' root/etc/init.d/podkopchik
grep -Fq 'th dport 53 counter drop' root/usr/libexec/podkopchik/native_boot_guard.sh
grep -Fq 'clear_missing_guard()' root/usr/libexec/podkopchik/native_runtime.uc
echo 'Emergency wiring PASS: immutable scoped capsule, independent management lease, protected legacy fallback, no ordinary site/DNS rollback'
