#!/bin/sh
# Package reviewed native components without installing or enabling anything.
set -eu
umask 077
export LC_ALL=C TZ=UTC0
[ ! -f /etc/openwrt_release ] || { echo 'Build on the workstation' >&2; exit 1; }
base="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
out="${1:-$base/.build/native-ax6000-review}"
case "$out" in /*) ;; *) echo 'Use an absolute output directory' >&2; exit 1 ;; esac
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT HUP INT TERM
mkdir -p "$out" "$stage/arm64" "$stage/package"
sh "$base/tools/build-native-dns.sh" "$stage/arm64"
root="$stage/package"
cp "$stage/arm64/podkopchik-native-dns" "$root/"
for f in check-offload.sh preflight-ax6000.sh procd-dns.sh; do cp "$base/native/runtime/$f" "$root/"; done
for f in universal_plan awg awg_network fakedns_guard; do cp "$base/root/usr/libexec/podkopchik/$f.uc" "$root/"; done
cp "$base/native/runtime/trial-state.uc" "$root/"
cp "$base/docs/UNIVERSAL-RELEASE-VM-20261106.md" "$root/REVIEW.md"
cp "$base/docs/UNIVERSAL-MIXED-CANARY-20261106.md" "$root/CANARY.md"
printf '%s\n' 'board=xiaomi,redmi-router-ax6000-stock' 'openwrt=25.12.6' 'kernel=6.12.112' \
	'architecture=aarch64_cortex-a53' 'mode=review-only-no-installer' > "$root/TARGET"
chmod 755 "$root/podkopchik-native-dns"
chmod 644 "$root"/*.sh "$root"/*.uc "$root"/*.md "$root/TARGET"
(cd "$root" && LC_ALL=C sha256sum podkopchik-native-dns ./*.sh ./*.uc ./*.md TARGET > SHA256SUMS)
chmod 644 "$root/SHA256SUMS"
touch -t 200001010000 "$root"/*
name=podkopchik-native-ax6000-25.12.6-REVIEW.tar.gz
(cd "$root" && COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --uname root --gname root -cf "$stage/package.tar" *)
gzip -n -c "$stage/package.tar" > "$out/$name"
(cd "$out" && sha256sum "$name" > "$name.sha256")
echo "Review package (not an installer): $out/$name"
