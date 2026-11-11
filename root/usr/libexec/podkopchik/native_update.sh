#!/bin/sh
# Static update only: the confirmed immutable generation stays running.
set -eu
umask 077
LIB="${PODKOPCHIK_LIB:-/usr/libexec/podkopchik}"
fail() { echo "Native update: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || fail 'root is required'
catalog="$LIB/native-targets.json"
target=$(ucode -L "$LIB" "$LIB/native_package_check.uc" device "$catalog")
repo=$(uci -q get podkopchik.main.github_repo 2>/dev/null || echo Rezalik/Podkopchik)
printf '%s\n' "$repo" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || fail 'invalid repository'
# The API and asset URL have canonical casing, independent of old UCI defaults.
[ "$repo" != rezalik/Podkopchik ] || repo=Rezalik/Podkopchik
work=$(mktemp -d /tmp/podkopchik-native-update.XXXXXX)
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
curl -fLsS --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 30 --max-filesize 2097152 \
	"https://api.github.com/repos/$repo/releases?per_page=20" -o "$work/releases.json"
[ "$(wc -c < "$work/releases.json")" -le 2097152 ] || fail 'release metadata too large'
ucode "$LIB/native_update.uc" release "$work/releases.json" "$repo" "$target" "${1:-}" > "$work/release"
if [ "${1:-}" = check ]; then cat "$work/release"; exit 0; fi
[ "${1:-}" = install ] || fail 'use check or install'
status=$(sh "$LIB/native_runtime.sh" status)
[ -z "$(printf '%s' "$status" | jsonfilter -e '@.pending')" ] || fail 'confirm or abort the pending Apply first'
[ "$(printf '%s' "$status" | jsonfilter -e '@.recovery_policy')" = transactional ] || fail 'use transactional recovery before a package update'
free=$(df -Pk /tmp | awk 'END {print $4}')
[ "$free" -ge 65536 ] || fail 'at least 64 MiB free tmpfs is required'
url=$(sed -n 's/^archive_url=//p' "$work/release")
expected=$(sed -n 's/^sha256=//p' "$work/release")
curl -fLsS --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 120 --max-filesize 12582912 "$url" -o "$work/package.tar.gz"
[ "$(wc -c < "$work/package.tar.gz")" -le 12582912 ] || fail 'compressed archive too large'
[ "$(sha256sum "$work/package.tar.gz" | awk '{print $1}')" = "$expected" ] || fail 'archive SHA256 mismatch'
ucode "$LIB/native_update.uc" archive "$work/package.tar.gz"
mkdir "$work/package"
tar -xzf "$work/package.tar.gz" -C "$work/package"
base="$work/package"
(cd "$base" && sha256sum -c SHA256SUMS >/dev/null) || fail 'manifest verification failed'
ucode -L "$LIB" "$LIB/native_package_check.uc" admit "$catalog" "$base"
# The installer preflights every target before publishing any static file.
ucode "$LIB/native_update.uc" install "$base"
printf '%s\n' 'Update files installed. The confirmed Native generation is still active.' \
	'Open Status, run Apply, verify DNS and internet, then confirm Native Apply before its deadline.'
