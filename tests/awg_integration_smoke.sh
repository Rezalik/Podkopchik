#!/bin/sh
set -eu
if ! command -v ucode >/dev/null 2>&1; then echo 'SKIP: AWG integration tests need local ucode + fs'; exit 0; fi
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT HUP INT TERM
flags="$PWD"
ucode -L "${UCODE_MODULE_DIR:-/usr/lib/ucode}" -L "$PWD/root/usr/libexec/podkopchik" tests/interception_model_smoke.uc
ucode -L "${UCODE_MODULE_DIR:-/usr/lib/ucode}" -L "$PWD/tests/ucode" -L "$PWD/root/usr/libexec/podkopchik" tests/awg_network_smoke.uc "$root"
mkdir "$root/model"
chmod 700 "$root/model"
PODKOPCHIK_TEST_UCI="$root/model/uci.json" ucode -L "${UCODE_MODULE_DIR:-/usr/lib/ucode}" -L "$PWD/tests/ucode" \
	-L "$PWD/root/usr/libexec/podkopchik" tests/awg_manage_smoke.uc "$root/model"
