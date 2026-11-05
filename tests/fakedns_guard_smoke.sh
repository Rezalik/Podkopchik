#!/bin/sh
set -eu
if ! command -v ucode >/dev/null 2>&1; then echo 'SKIP: native ucode required'; exit 0; fi
ucode -L "${UCODE_MODULE_DIR:-/usr/lib/ucode}" -L "$PWD/root/usr/libexec/podkopchik" tests/fakedns_guard_smoke.uc
sh -n root/usr/libexec/podkopchik/fakedns_guard.sh
sh -n root/etc/init.d/podkopchik-fakedns
grep -qx 'START=18' root/etc/init.d/podkopchik-fakedns
grep -q 'safety fake-sync' root/etc/init.d/podkopchik
grep -q 'safety fake-sync "$tmp"' root/usr/bin/podkopchikctl
grep -q 'fakedns_guard.sh.*release' uninstall.sh
! grep -q 'podkopchik_fake_guard' root/usr/libexec/podkopchik/cleanup_rules.sh
