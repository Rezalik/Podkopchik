#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
grep -q 'sh "$LIB/native_update.sh" install' "$root/root/usr/bin/podkopchikctl"
grep -q 'sh "$LIB/native_update.sh" check' "$root/root/usr/bin/podkopchikctl"
grep -q 'confirmed generations, not the legacy update archive' "$root/root/usr/bin/podkopchikctl"
! grep -Eq 'restart|native-emergency|native-confirm|native_runtime.sh.*apply' "$root/root/usr/libexec/podkopchik/native_update.sh"
grep -q 'sha256:' "$root/root/usr/libexec/podkopchik/native_update.uc"
grep -q 'update-start' "$root/root/www/luci-static/resources/view/podkopchik/updates.js"
grep -q -- '--prerelease' "$root/.github/workflows/native-rc.yml"
if ! command -v ucode >/dev/null 2>&1; then
	echo 'SKIP actual ucode archive/release admission: run tools/native-update-vm-test.sh in isolated OpenWrt VM'
	exit 0
fi
echo 'Native update wiring PASS; actual archive adversarial tests are VM-only'
