#!/bin/sh
# Workstation-only, deterministic full source payload plus immutable ARM64 helper.
set -eu
umask 077
export LC_ALL=C TZ=UTC0 COPYFILE_DISABLE=1
[ ! -f /etc/openwrt_release ] || exit 1
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="${1:-$base/.build/native-candidate}"
case "$out" in /*) ;; *) exit 2;; esac
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
mkdir -p "$out" "$stage/package/root" "$stage/package/i18n/ru" "$stage/package/native-bin"
sh "$base/tools/build-native-dns.sh" "$stage/arm64-a"
sh "$base/tools/build-native-dns.sh" "$stage/arm64-b"
cmp "$stage/arm64-a/podkopchik-native-dns" "$stage/arm64-b/podkopchik-native-dns"
hash=$(sha256sum "$stage/arm64-a/podkopchik-native-dns" | awk '{print $1}')
cp -R "$base/root/." "$stage/package/root/"
find "$stage/package" -name .DS_Store -delete
[ -z "$(find "$stage/package" -type l -print)" ] || { echo 'Symlinks are not permitted in the candidate payload' >&2; exit 1; }
cp "$stage/arm64-a/podkopchik-native-dns" "$stage/package/native-bin/$hash"
sed "s/@SHA256@/$hash/g" "$base/native/runtime/native-dns-launcher.sh.in" > "$stage/package/root/usr/libexec/podkopchik/podkopchik-native-dns"
cp "$base/install.sh" "$stage/package/"
cp "$base/uninstall.sh" "$stage/package/"
cp "$base/native/runtime/install-dns-component.sh" "$stage/package/install-native-dns.sh"
cp "$base/i18n/ru/podkopchik.ru.lmo" "$stage/package/i18n/ru/"
mkdir -p "$stage/package/native/runtime" "$stage/package/tools" "$stage/package/docs"
cp -R "$base/native/dns" "$stage/package/native/"
cp "$base/native/runtime/install-dns-component.sh" "$base/native/runtime/native-dns-launcher.sh.in" "$stage/package/native/runtime/"
cp "$base/tools/build-native-dns.sh" "$base/tools/build-native-candidate.sh" "$stage/package/tools/"
cp "$base/tools/verify-native-candidate.js" "$stage/package/tools/"
cp "$base/tools/install-native-rc-files.sh" "$base/tools/ax6000-protected-dns-check.sh" "$base/tools/native-live-pool-review.uc" "$stage/package/tools/"
cp "$base/README.md" "$stage/package/"
cp "$base/docs/UNIVERSAL-PERMANENT-APPLY.md" "$base/docs/SPEC.md" "$base/docs/ACCEPTANCE.md" "$stage/package/docs/"
cp "$base/docs/UNIVERSAL-NATIVE-HOUSEHOLD-20261107.md" "$stage/package/docs/"
find "$stage/package" -name .DS_Store -delete
[ -z "$(find "$stage/package" -type l -print)" ] || exit 1
printf '%s\n' "$hash" > "$stage/package/NATIVE_DNS_SHA256"
printf '%s\n' 'board=xiaomi,redmi-router-ax6000-stock' 'openwrt=25.12.6' 'architecture=aarch64_cortex-a53' \
	'activation=explicit-ordinary-apply' 'acceptance=requires-completed-vm-report-and-physical-preflight' > "$stage/package/TARGET"
find "$stage/package" -type d -exec chmod 755 {} \;
find "$stage/package" -type f -exec chmod 644 {} \;
find "$stage/package/root/usr/libexec/podkopchik" -type f \( -name '*.sh' -o -name '*.uc' \) -exec chmod 755 {} \;
chmod 755 "$stage/package/"*.sh "$stage/package/native-bin/$hash" "$stage/package/root/usr/libexec/podkopchik/podkopchik-native-dns" \
	"$stage/package/root/usr/bin/podkopchikctl" "$stage/package/root/etc/init.d/"*
chmod 600 "$stage/package/root/etc/config/podkopchik"
(cd "$stage/package" && find . -type f ! -name SHA256SUMS | sort | while IFS= read -r path; do sha256sum "$path"; done > SHA256SUMS)
find "$stage/package" -exec touch -t 200001010000 {} \;
(cd "$stage/package" && find . -print | sort > "$stage/file-order" &&
	tar --no-recursion --format ustar --uid 0 --gid 0 --uname root --gname root -cf "$stage/package.tar" -T "$stage/file-order")
name=podkopchik-native-ax6000-candidate.tar.gz
gzip -n -c "$stage/package.tar" > "$out/$name"
(cd "$out" && sha256sum "$name" > "$name.sha256")
printf 'ARM64 helper SHA256: %s\nCandidate: %s/%s\n' "$hash" "$out" "$name"
