#!/bin/sh
# Workstation-only, deterministic full source payload plus immutable ARM64 helper.
set -eu
umask 077
export LC_ALL=C TZ=UTC0 COPYFILE_DISABLE=1
[ ! -f /etc/openwrt_release ] || exit 1
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out="${1:-$base/.build/native-candidate}"
case "$out" in /*) ;; *) exit 2;; esac
if [ "$#" -gt 0 ]; then shift; fi
target=ax6000
reuse=
while [ "$#" -gt 0 ]; do
	[ "$#" -ge 2 ] || exit 2
	case "$1" in
		--target) target=$2 ;;
		--reuse-helper-from) reuse=$2 ;;
		*) echo 'Use OUTPUT [--target ax6000|flint2] [--reuse-helper-from VERIFIED_BUNDLE]' >&2; exit 2 ;;
	esac
	shift 2
done
name=$(node "$base/tools/native-package-manifest.js" asset "$target")
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
mkdir -p "$out" "$stage/package/native-bin"
if [ -n "$reuse" ]; then
	# A source-only release can retain an already verified immutable component.
	# Never silently reuse it after any change to its source/module/build recipe.
	node "$base/tools/verify-native-candidate.js" "$reuse"
	mkdir "$stage/prior" "$stage/arm64-a"
	tar -xzf "$reuse" -C "$stage/prior"
	# cmd/ contains independent diagnostic executables, not imported by the
	# packaged main helper. Compare every other source/module file exactly.
	node - "$base/native/dns" "$stage/prior/native/dns" <<'NODE'
const fs = require('fs'), path = require('path'), assert = require('assert');
function source(root, dir = '') {
 const out = {};
 for (const e of fs.readdirSync(path.join(root, dir), {withFileTypes:true})) {
  const rel = path.join(dir, e.name);
  if (rel === 'cmd') continue;
  if (e.isDirectory()) Object.assign(out, source(root, rel));
  else { assert(e.isFile(), 'Unexpected source entry'); out[rel] = fs.readFileSync(path.join(root, rel)).toString('base64'); }
 }
 return out;
}
assert.deepStrictEqual(source(process.argv[2]), source(process.argv[3]), 'Helper source changed; compile with pinned Go');
NODE
	cmp "$base/tools/build-native-dns.sh" "$stage/prior/tools/build-native-dns.sh"
	prior_hash=$(cat "$stage/prior/NATIVE_DNS_SHA256")
	cp "$stage/prior/native-bin/$prior_hash" "$stage/arm64-a/podkopchik-native-dns"
	echo 'Reusing verified helper with identical source/build recipe; no fresh Go compilation claimed.'
else
	sh "$base/tools/build-native-dns.sh" "$stage/arm64-a"
	sh "$base/tools/build-native-dns.sh" "$stage/arm64-b"
	cmp "$stage/arm64-a/podkopchik-native-dns" "$stage/arm64-b/podkopchik-native-dns"
fi
hash=$(sha256sum "$stage/arm64-a/podkopchik-native-dns" | awk '{print $1}')
sh "$base/tools/stage-native-common.sh" "$stage/package"
find "$stage/package" -name .DS_Store -delete
[ -z "$(find "$stage/package" -type l -print)" ] || { echo 'Symlinks are not permitted in the candidate payload' >&2; exit 1; }
cp "$stage/arm64-a/podkopchik-native-dns" "$stage/package/native-bin/$hash"
sed "s/@SHA256@/$hash/g" "$base/native/runtime/native-dns-launcher.sh.in" > "$stage/package/root/usr/libexec/podkopchik/podkopchik-native-dns"
cp "$base/install.sh" "$stage/package/"
cp "$base/uninstall.sh" "$stage/package/"
cp "$base/native/runtime/install-dns-component.sh" "$stage/package/install-native-dns.sh"
mkdir -p "$stage/package/native/runtime" "$stage/package/tools" "$stage/package/docs"
cp -R "$base/native/dns" "$stage/package/native/"
cp "$base/native/runtime/install-dns-component.sh" "$base/native/runtime/native-dns-launcher.sh.in" "$stage/package/native/runtime/"
cp "$base/tools/build-native-dns.sh" "$base/tools/build-native-candidate.sh" "$stage/package/tools/"
cp "$base/tools/verify-native-candidate.js" "$stage/package/tools/"
cp "$base/tools/stage-native-common.sh" "$base/tools/native-package-manifest.js" "$stage/package/tools/"
cp "$base/tools/install-native-rc-files.sh" "$base/tools/ax6000-protected-dns-check.sh" "$base/tools/native-live-pool-review.uc" "$stage/package/tools/"
cp "$base/README.md" "$stage/package/"
cp "$base/docs/UNIVERSAL-PERMANENT-APPLY.md" "$base/docs/SPEC.md" "$base/docs/ACCEPTANCE.md" "$stage/package/docs/"
cp "$base/docs/UNIVERSAL-NATIVE-HOUSEHOLD-20261107.md" "$stage/package/docs/"
cp "$base/docs/GUIDE-RU.md" "$base/docs/LOCAL-RELEASE-WORKFLOW.md" "$base/docs/NATIVE-SESSION-TTL-20261108.md" "$stage/package/docs/"
cp "$base/docs/NATIVE-PORTABILITY.md" "$stage/package/docs/"
find "$stage/package" -name .DS_Store -delete
[ -z "$(find "$stage/package" -type l -print)" ] || exit 1
find "$stage/package" -depth -type d -empty -delete
printf '%s\n' "$hash" > "$stage/package/NATIVE_DNS_SHA256"
find "$stage/package" -type d -exec chmod 755 {} \;
find "$stage/package" -type f -exec chmod 644 {} \;
find "$stage/package/root/usr/libexec/podkopchik" -type f \( -name '*.sh' -o -name '*.uc' \) -exec chmod 755 {} \;
chmod 755 "$stage/package/"*.sh "$stage/package/native-bin/$hash" "$stage/package/root/usr/libexec/podkopchik/podkopchik-native-dns" \
	"$stage/package/root/usr/bin/podkopchikctl" "$stage/package/root/etc/init.d/"*
chmod 600 "$stage/package/root/etc/config/podkopchik"
(cd "$stage/package" && find . -type f ! -name SHA256SUMS | sort | while IFS= read -r path; do sha256sum "$path"; done > SHA256SUMS)
node "$base/tools/native-package-manifest.js" write "$target" "$stage/package" "$hash"
chmod 644 "$stage/package/TARGET" "$stage/package/PLATFORM.json" "$stage/package/COMMON_SHA256SUMS"
(cd "$stage/package" && find . -type f ! -name SHA256SUMS | sort | while IFS= read -r path; do sha256sum "$path"; done > SHA256SUMS)
find "$stage/package" -exec touch -t 200001010000 {} \;
(cd "$stage/package" && find . -print | sort > "$stage/file-order" &&
	tar --no-recursion --format ustar --uid 0 --gid 0 --uname root --gname root -cf "$stage/package.tar" -T "$stage/file-order")
gzip -n -c "$stage/package.tar" > "$out/$name"
(cd "$out" && sha256sum "$name" > "$name.sha256")
printf 'ARM64 helper SHA256: %s\nCandidate: %s/%s\n' "$hash" "$out" "$name"
