#!/bin/sh
# Execute immutable, verified copies from guest tmpfs, not the shared 9p mount.
. /mnt/lab/native-vm-only.sh
PKC_VM_BIN="/tmp/pkc-native-bin-$(sha256sum /mnt/lab/SHA256SUMS | cut -c1-16)"
if mkdir -m 700 "$PKC_VM_BIN" 2>/dev/null; then
	for name in podkopchik-native-dns pilot-probe native-dns.test xray; do
		cp "/mnt/lab/$name" "$PKC_VM_BIN/$name" || exit 1
	done
	chmod 700 "$PKC_VM_BIN"/*
	(cd "$PKC_VM_BIN" && sha256sum -c /mnt/lab/SHA256SUMS &&
		printf '%s\n' 'b07ac0b0bc7c8ae09fefa5d93e3623ee32f0d52bba26cb809da82fede794461d  xray' | sha256sum -c) || exit 1
	touch "$PKC_VM_BIN/ready"
fi
ucode -e 'import {lstat} from "fs";const s=lstat(ARGV[0]);
	exit(s?.type!="directory" || s.uid!=0 || (s.mode&0o077)!=0);' "$PKC_VM_BIN" || exit 1
for attempt in 1 2 3 4 5 6 7 8 9 10; do
	[ ! -e "$PKC_VM_BIN/ready" ] || break
	sleep 1
done
[ -f "$PKC_VM_BIN/ready" ] || exit 1
export PKC_VM_BIN
