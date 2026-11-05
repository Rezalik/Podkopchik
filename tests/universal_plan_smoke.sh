#!/bin/sh
set -eu
if ! command -v ucode >/dev/null 2>&1; then echo 'SKIP: native ucode required'; exit 0; fi
ucode -L "${UCODE_MODULE_DIR:-/usr/lib/ucode}" -L "$PWD/root/usr/libexec/podkopchik" tests/universal_plan_smoke.uc
