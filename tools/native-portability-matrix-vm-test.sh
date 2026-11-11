#!/bin/sh
# A prepared disposable ARM64 OpenWrt guest, with its fixture share read-only.
set -eu
. /mnt/lab/native-vm-only.sh
failed=0
run_case() {
	name=$1
	shift
	if "$@"; then printf 'MATRIX PASS %s\n' "$name"
	else
		printf 'MATRIX FAIL %s\n' "$name"
		failed=1
	fi
}
run_case classification ucode -L /mnt/lab/source /mnt/lab/source/native_classification_smoke.uc
run_case platform-and-package sh /mnt/lab/native-portability-vm-test.sh
run_case static-update sh /mnt/lab/native-update/native-update-vm-test.sh
run_case first-abort env PKC_VM_PERMANENT=1 PKC_VM_MIGRATION=1 PKC_VM_FIRST_MIGRATION_ABORT=1 sh /mnt/lab/native-dns-vm-test.sh
run_case migration-and-routing env PKC_VM_PERMANENT=1 PKC_VM_MIGRATION=1 PKC_VM_SKIP_MIXED=1 sh /mnt/lab/native-dns-vm-test.sh
run_case mixed-transports env PKC_VM_PERMANENT=1 PKC_VM_ONLY_MIXED=1 sh /mnt/lab/native-dns-vm-test.sh
exit "$failed"
