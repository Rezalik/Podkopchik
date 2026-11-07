#!/bin/sh
set -eu
umask 077
. /mnt/lab/native-vm-only.sh
ucode -L /mnt/lab/source /mnt/lab/source/native_classification_smoke.uc
for mode in strict compatible; do
	for migration in 0 1; do
		PKC_VM_CHECK_CLASSIFICATION=1 PKC_VM_CLASSIFICATION="$mode" PKC_VM_MIGRATION="$migration" \
			sh /mnt/lab/native-dns-vm-test.sh
	done
done
PKC_VM_CHECK_CLASSIFICATION=1 PKC_VM_CLASSIFICATION=strict PKC_VM_UNKNOWN_ACTION=block \
	sh /mnt/lab/native-dns-vm-test.sh
