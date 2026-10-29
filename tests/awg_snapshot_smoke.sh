#!/bin/sh
set -eu
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT HUP INT TERM
awk '/^check_snapshot\(\)/{p=1} p{print} p && /^}/{exit}' tools/awg-stage4-watchdog.sh > "$root/check"
. "$root/check"
awk '/^validate_restore_paths\(\)/{p=1} p{print} p && /^}/{exit}' tools/awg-stage4-install.sh > "$root/restore-check"
. "$root/restore-check"
dir="$root/guard"
mkdir -m 700 "$dir" "$root/payload"
mkdir -p "$root/payload/etc/config" "$root/payload/etc/podkopchik/awg" "$root/payload/tmp/podkopchik"
printf 'synthetic\n' > "$root/payload/etc/config/podkopchik"
printf '{}\n' > "$root/payload/tmp/podkopchik/state.json"
printf 'restore\n' > "$dir/kind"
tar -czf "$dir/snapshot.tar.gz" -C "$root/payload" etc/config/podkopchik etc/podkopchik tmp/podkopchik/state.json
check_snapshot
validate_restore_paths < "$dir/snapshot.paths"
tar -czf "$dir/snapshot.tar.gz" -C "$root/payload" .
if check_snapshot; then echo 'FAIL: private staging root/parent metadata allowed'; exit 1; fi
if validate_restore_paths < "$dir/snapshot.paths"; then echo 'FAIL: installer rollback accepts root metadata'; exit 1; fi
tar -czf "$dir/snapshot.tar.gz" -C "$root/payload" tmp
if check_snapshot; then echo 'FAIL: system /tmp directory metadata allowed'; exit 1; fi
ln -s /etc/passwd "$root/payload/etc/podkopchik/link"
tar -czf "$dir/snapshot.tar.gz" -C "$root/payload" etc/podkopchik
if check_snapshot; then echo 'FAIL: snapshot links allowed'; exit 1; fi
echo 'Snapshot metadata regression smoke OK: canonical file paths only; root/parent entries and links rejected'
