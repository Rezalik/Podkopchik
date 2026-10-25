#!/bin/sh
set -eu
if ! command -v ucode >/dev/null 2>&1; then
	echo 'SKIP: native AWG parser/storage tests require local ucode + fs'
	exit 0
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
ucode -L "${UCODE_MODULE_DIR:-/usr/lib/ucode}" -L "$PWD/root/usr/libexec/podkopchik" tests/awg_model_smoke.uc "$tmp"
