#!/bin/sh
# Host-only reproducible source build. Never installs or selects a router core.
set -eu
umask 077
[ ! -f /etc/openwrt_release ] || { echo 'Build on a workstation/SDK host, never on the router' >&2; exit 1; }
base="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
tag="${1:-v26.10.31}"
case "$tag" in
	v26.3.27) source_sha=992a4997e6bb846d11469435d687f99ef812fcde1e0a009bb8e95189ea20331d; go_version=go1.26.10 ;;
	v26.10.31) source_sha=be44f95d497ad4ba6e9d1dcfbbd71e8e51f812aff077d4c15c9947eff5e3046a; go_version=go1.27.3 ;;
	*) echo 'Only reviewed, source-hash-pinned tags are supported' >&2; exit 1 ;;
esac
go="${GO:-go}"
[ "$("$go" version | awk '{print $3}')" = "$go_version" ] || { echo "Pinned $go_version is required" >&2; exit 1; }
work="$base/.build/xray-udp-$tag"
out="$work/release"
mkdir -p "$work" "$out"
archive="$work/source.tar.gz"
if [ ! -f "$archive" ]; then
	curl --proto '=https' --proto-redir '=https' -fsSL --connect-timeout 10 --max-time 120 \
		"https://codeload.github.com/XTLS/Xray-core/tar.gz/refs/tags/$tag" -o "$archive.new"
	mv "$archive.new" "$archive"
fi
[ "$(sha256sum "$archive" | awk '{print $1}')" = "$source_sha" ] || { echo 'Source archive hash mismatch' >&2; exit 1; }
source="$(mktemp -d "$work/source.XXXXXX")"
tar -xzf "$archive" --strip-components=1 -C "$source"
cp "$base/patches/xray/udp_retention_probe_test.go" "$source/proxy/dokodemo/"
export GOTOOLCHAIN=local GOENV=off GOFLAGS= GOEXPERIMENT= GOARM64=v8.0
export GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org GONOSUMDB= GONOPROXY= GOPRIVATE=
: "${GOMODCACHE:=$work/mod}"
: "${GOCACHE:=$work/cache}"
export GOMODCACHE GOCACHE

# Both Linux ARM64 test executables use the same fixture and a fixed test timeout.
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 "$go" -C "$source" test -c -trimpath -ldflags=-buildid= \
	-o "$out/upstream-probe" ./proxy/dokodemo
patch -d "$source" -p1 -F 0 -i "$base/patches/xray/0001-extract-packet-writer.patch"
cp "$base/patches/xray/udp_reply_cache.go" "$base/patches/xray/udp_packet_writer.go" \
	"$base/patches/xray/udp_reply_cache_test.go" "$base/patches/xray/udp_reply_cache_linux_test.go" \
	"$base/patches/xray/udp_child_integration_linux_test.go" "$source/proxy/dokodemo/"
GOOS="$("$go" env GOHOSTOS)" GOARCH="$("$go" env GOHOSTARCH)" CGO_ENABLED=1 \
	"$go" -C "$source" test -race -count=10 -run TestUDPReplyCache ./proxy/dokodemo
"$go" -C "$source" mod verify
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 "$go" -C "$source" test -c -trimpath -ldflags=-buildid= \
	-o "$out/patched-probe" ./proxy/dokodemo
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 "$go" -C "$source" build -trimpath -buildvcs=false \
	-ldflags='-s -w -buildid= -X github.com/xtls/xray-core/core.build=podkopchik-udp-cache-v1' \
	-o "$out/xray" ./main
chmod 755 "$out/xray" "$out/upstream-probe" "$out/patched-probe"
cp "$source/LICENSE" "$out/LICENSE.Xray"
mkdir -p "$out/patches"
cp "$base/patches/xray/"*.go "$base/patches/xray/"*.patch "$out/patches/"
binary_sha="$(sha256sum "$out/xray" | awk '{print $1}')"
patch_sha="$(sha256sum "$base/patches/xray/0001-extract-packet-writer.patch" | awk '{print $1}')"
printf '{"schema":1,"official":false,"upstream_tag":"%s","source_sha256":"%s","go":"%s","patch_id":"podkopchik-udp-cache-v1","patch_sha256":"%s","platform":"linux/arm64","binary_sha256":"%s","reply_cache_limit":128,"idle_seconds":120,"sweep_seconds":30}\n' \
	"$tag" "$source_sha" "$go_version" "$patch_sha" "$binary_sha" > "$out/SOURCE.json"
(cd "$out" && sha256sum xray upstream-probe patched-probe LICENSE.Xray SOURCE.json patches/* > SHA256SUMS)
echo "Local build ready: $out"
echo 'This is a locally built, unsigned core artifact, not an official release or a trusted APK.'
echo 'No router has been changed. Review SOURCE.json, SHA256SUMS and all live acceptance gates before installation.'
