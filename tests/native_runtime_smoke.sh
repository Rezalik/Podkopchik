#!/bin/sh
set -eu
ctl=root/usr/bin/podkopchikctl
core=root/usr/libexec/podkopchik/native_runtime.uc
grep -q 'routing_engine.*native' "$ctl"
grep -q 'native_runtime apply' "$ctl"
grep -q 'native-confirm)' "$ctl"
grep -q 'native-abort)' "$ctl"
grep -q 'native_runtime boot' root/etc/init.d/podkopchik
grep -q 'native_runtime stop' root/etc/init.d/podkopchik
grep -q 'native_runtime.sh early' root/etc/init.d/podkopchik-fakedns
grep -q "option routing_engine 'legacy'" root/etc/config/podkopchik
grep -q "option fakedns_enabled '0'" root/etc/config/podkopchik
grep -q "m.phase!='active'" "$core"
grep -q 'previous.*code.json' "$core"
grep -q 'refusing to reset a previously admitted DNS allocator' "$core"
grep -q 'issued pool cannot be reused' "$core"
grep -q 'position.*terminal' "$core"
grep -q "type.*script" "$core"
grep -q 'CURL_CA_BUNDLE' "$core"
grep -q 'matching ownership journal' "$core"
grep -q 'release_policy_routes' "$core"
grep -q 'readmit(g)' "$core"
grep -Fq "respawn:['3600','1','0']" "$core"
grep -q 'live flowtable prevents' "$core"
grep -q 'measured recovery snapshot' "$core"
grep -q 'update lacks permanent Native Apply support' "$ctl"
grep -q 'old rollback cannot restore permanent Native routing' "$ctl"
if grep -Eq 'flush ruleset|network restart|wifi reload|native-preview' "$core"; then exit 1; fi
sh -n root/usr/libexec/podkopchik/native_runtime.sh
printf '%s\n' 'Native lifecycle wiring PASS: ordinary Apply, confirmation, pinned boot/recovery, strict allocator and legacy defaults'
