#!/bin/sh
set -eu
umask 077
LIB="${PODKOPCHIK_LIB:-/usr/libexec/podkopchik}"
exec "${PODKOPCHIK_UCODE:-ucode}" -L "$LIB" -e 'require("fakedns_guard").cli(ARGV);' -- "$@"
