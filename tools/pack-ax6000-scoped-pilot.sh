#!/bin/sh
# Operator workstation only. Canonical ownership for root-private router files.
set -eu
umask 077
[ "$(uname -s)" = Darwin ] && [ "$#" = 3 ] || exit 2
mode="$1"; dir="$2"; out="$3"
case "$out" in /*) ;; *) exit 2 ;; esac
case "$mode" in rehearsal|pilot) ;; *) exit 2 ;; esac
cd "$dir"
set -- ax6000-scoped-pilot-arm.sh ax6000-virtual-watch.sh trial-state.uc virtual-trial-cleanup.uc pilot.nft route.json run.json
if [ "$mode" = pilot ]; then
	[ "$(stat -f '%Lp' pilot.dns)" = 600 ] || exit 1
	set -- "$@" ax6000-scoped-pilot-exercise.sh pilot.dns podkopchik-native-dns
fi
for f in "$@" SHA256SUMS; do [ -f "$f" ] && [ ! -L "$f" ] || exit 1; done
shasum -a 256 -c SHA256SUMS
COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --uname root --gname root -cf "$out" "$@" SHA256SUMS
