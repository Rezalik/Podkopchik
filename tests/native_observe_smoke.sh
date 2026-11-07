#!/bin/sh
set -eu
command -v ucode >/dev/null 2>&1 || { echo 'SKIPPED: host ucode unavailable'; exit 0; }
ucode -L tools tests/native_observe_smoke.uc
sh -n tools/native-observe.sh
if grep -Eq 'uci (set|commit)|nft (add|delete|flush)|killall|sysupgrade|update-install|/etc/init.d/.*restart|tcpdump|logread' tools/native-observe.sh tools/native-observe.uc; then
	echo 'Observation unexpectedly contains a mutation or sensitive capture command' >&2; exit 1
fi
grep -Fq 'log_limit:524288' tools/native-observe.uc
grep -Fq 'respawn' tools/native-observe.sh && exit 1
grep -Fq '48' tools/native-observe.sh
echo 'PASS: observation safety, bounded logging and no production service mutations'
