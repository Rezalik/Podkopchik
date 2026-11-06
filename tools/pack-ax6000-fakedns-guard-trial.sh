#!/bin/sh
# Workstation only; package the standalone guard, not a router installer.
set -eu
umask 077
[ "$(uname -s)" = Darwin ] && [ "$#" = 1 ] || exit 2
case "$1" in /*.tar) ;; *) exit 2 ;; esac
out="$1"
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
trap 'exit 1' HUP INT TERM
cp "$base/tools/ax6000-fakedns-guard-trial.sh" "$base/root/usr/libexec/podkopchik/trial-state.uc" "$stage/"
for f in fakedns_guard.uc fakedns_guard.sh native_pool.uc; do cp "$base/root/usr/libexec/podkopchik/$f" "$stage/"; done
cp "$base/root/etc/init.d/podkopchik-fakedns" "$stage/"
cp "$base/root/etc/hotplug.d/iface/95-podkopchik-fakedns" "$stage/podkopchik-fakedns-hotplug.sh"
cp "$base/root/lib/upgrade/keep.d/podkopchik-fakedns" "$stage/podkopchik-fakedns.keep"
cd "$stage"
export LC_ALL=C TZ=UTC0
set -- ax6000-fakedns-guard-trial.sh trial-state.uc fakedns_guard.uc fakedns_guard.sh native_pool.uc podkopchik-fakedns podkopchik-fakedns-hotplug.sh podkopchik-fakedns.keep
shasum -a 256 "$@" > SHA256SUMS
chmod 600 "$@" SHA256SUMS
touch -t 200001010000 "$@" SHA256SUMS
COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --uname root --gname root -cf "$out" "$@" SHA256SUMS
(cd "$(dirname -- "$out")" && shasum -a 256 "$(basename -- "$out")" > "$(basename -- "$out").sha256")
