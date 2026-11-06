#!/bin/sh
# Build the experimental DNS helper on a workstation, not on OpenWrt.
set -eu
umask 077
[ ! -f /etc/openwrt_release ] || { echo 'Build on a workstation' >&2; exit 1; }
base="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
out="${1:-$base/.build/native-dns}"
case "$out" in /*) ;; *) echo 'Use an absolute output directory' >&2; exit 1 ;; esac
go="${GO:-go}"
export GOTOOLCHAIN=local GOENV=off GOFLAGS= GOEXPERIMENT= GOARM64=v8.0
export GOSUMDB=sum.golang.org GONOSUMDB= GONOPROXY= GOPRIVATE=
[ "$("$go" version | awk '{print $3}')" = go1.26.10 ] || { echo 'Pinned Go 1.26.10 is required' >&2; exit 1; }
mkdir -p "$out"
"$go" -C "$base/native/dns" mod verify
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 "$go" -C "$base/native/dns" build -mod=readonly -trimpath -buildvcs=false \
	-ldflags='-s -w -buildid=' -o "$out/podkopchik-native-dns" .
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 "$go" -C "$base/native/dns" build -mod=readonly -trimpath -buildvcs=false \
	-ldflags='-s -w -buildid=' -o "$out/pilot-probe" ./cmd/pilot-probe
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 "$go" -C "$base/native/dns" test -mod=readonly -c -trimpath -ldflags='-buildid=' \
	-o "$out/native-dns.test" .
(cd "$out" && sha256sum podkopchik-native-dns pilot-probe native-dns.test > SHA256SUMS)
echo "Local ARM64 preview built: $out"
echo 'Unsigned laboratory artifact. Do not install on a router.'
