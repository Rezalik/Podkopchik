#!/bin/sh
set -eu
p=tools/xray-live-pilot.uc
m=tools/xray-live-measure.uc
grep -q 'xiaomi,redmi-router-ax6000-stock' "$p"
grep -q 'podkopchik-xray-pilot-watch' "$p"
grep -q 'candidate main absent or unexpectedly replaced' "$p"
grep -q 'FD safety threshold' "$p"
grep -q 'observation_seconds: 21600' "$p"
grep -q 'final_deadline: time() + 28800' "$p"
grep -q "instance('/usr/bin/xray')" "$p"
grep -q 'config-apply.lock' "$p"
grep -q 'health-check.lock' "$p"
grep -q 'pilot-owner' "$p"
grep -q 'observer table ownership mismatch' "$p"
grep -q 'unsafe RAM staging' "$p"
grep -q 'unsafe staged file' "$p"
grep -q 'WAN boundary counter failure' "$p"
grep -q 'postrouting priority 300' "$p"
grep -q 'Only owned socket inodes\|only owned socket inodes' "$m"
! grep -Eq 'nft (flush|delete table inet podkopchik[^_])|ip (route|rule) (add|del|replace)|uci .* (set|commit)|sysupgrade|reboot|killall|pkill' "$p"
! grep -q 'openwrt2' "$p"
if command -v ucode >/dev/null 2>&1; then
 tmp=$(mktemp -d)
 trap 'rm -rf "$tmp"' EXIT HUP INT TERM
 ucode -c -o "$tmp/pilot.ucb" "$p"
 ucode -c -o "$tmp/measure.ucb" "$m"
fi
echo 'One-off pilot static/syntax smoke PASS; not production failure injection'
