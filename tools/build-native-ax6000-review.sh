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
for f in universal_plan universal_selection native_pool awg awg_network fakedns_guard generate vless interception; do
	cp "$base/root/usr/libexec/podkopchik/$f.uc" "$root/"
done
cp "$base/root/usr/libexec/podkopchik/fakedns_guard.sh" "$root/"
cp "$base/root/usr/libexec/podkopchik/native_apply.sh" "$root/"
cp "$base/root/etc/init.d/podkopchik-fakedns" "$root/podkopchik-fakedns.init"
cp "$base/root/etc/hotplug.d/iface/95-podkopchik-fakedns" "$root/podkopchik-fakedns-hotplug.sh"
cp "$base/root/usr/libexec/podkopchik/trial-state.uc" "$root/"
cp "$base/native/runtime/pool-review.uc" "$root/"
for f in ax6000-recovery.sh ax6000-recovery-data.uc pkc-ax6000-recovery.init ax6000-virtual-watch.sh virtual-trial-cleanup.uc virtual-pilot-plan.uc; do cp "$base/native/runtime/$f" "$root/"; done
for f in ax6000-scoped-pilot-arm.sh ax6000-scoped-pilot-exercise.sh pack-ax6000-scoped-pilot.sh ax6000-awg-udp-control.sh; do
	cp "$base/tools/$f" "$root/"
done
cp "$base/docs/UNIVERSAL-RELEASE-VM-20261106.md" "$root/REVIEW.md"
cp "$base/docs/UNIVERSAL-MIXED-CANARY-20261106.md" "$root/CANARY.md"
cp "$base/docs/UNIVERSAL-AX6000-ACCEPTANCE.md" "$root/AX6000.md"
cp "$base/docs/UNIVERSAL-AX6000-PILOT.md" "$root/PILOT.md"
cp "$base/docs/UNIVERSAL-AX6000-VIRTUAL-PILOT.md" "$root/VIRTUAL-PILOT.md"
cp "$base/docs/UNIVERSAL-AX6000-FAKEDNS-UDP.md" "$root/FAKEDNS-UDP.md"
cp "$base/docs/UNIVERSAL-NATIVE-APPLY.md" "$root/NATIVE-APPLY.md"
printf '%s\n' 'board=xiaomi,redmi-router-ax6000-stock' 'openwrt=25.12.6' 'kernel=6.12.112' \
	'architecture=aarch64_cortex-a53' 'mode=review-only-no-installer' > "$root/TARGET"
chmod 755 "$root/podkopchik-native-dns"
chmod 644 "$root"/*.sh "$root"/*.uc "$root"/*.init "$root"/*.md "$root/TARGET"
(cd "$root" && LC_ALL=C sha256sum podkopchik-native-dns ./*.sh ./*.uc ./*.init ./*.md TARGET > SHA256SUMS)
chmod 644 "$root/SHA256SUMS"
touch -t 200001010000 "$root"/*
name=podkopchik-native-ax6000-25.12.6-REVIEW.tar.gz
(cd "$root" && COPYFILE_DISABLE=1 tar --format ustar --uid 0 --gid 0 --uname root --gname root -cf "$stage/package.tar" *)
gzip -n -c "$stage/package.tar" > "$out/$name"
cp "$stage/arm64/pilot-probe" "$out/"
(cd "$out" && sha256sum "$name" > "$name.sha256" && sha256sum pilot-probe > pilot-probe.sha256)
echo "Review package (not an installer): $out/$name"
