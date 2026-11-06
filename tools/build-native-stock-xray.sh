#!/bin/sh
# Unmodified upstream core for the isolated VM only, not a router update.
set -eu
umask 077
[ ! -f /etc/openwrt_release ] || exit 1
base="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
go="${GO:-go}"
export GOTOOLCHAIN=local GOENV=off GOFLAGS= GOEXPERIMENT= GOARM64=v8.0
[ "$("$go" version | awk '{print $3}')" = go1.26.10 ] || { echo 'Pinned Go 1.26.10 is required' >&2; exit 1; }
out="$base/.build/native-stock-xray"
archive="$base/.build/xray-udp-v26.3.27/source.tar.gz"
if [ ! -f "$archive" ]; then
	mkdir -p "$(dirname "$archive")"
	curl --proto '=https' --proto-redir '=https' -fsSL --connect-timeout 10 --max-time 120 \
		'https://codeload.github.com/XTLS/Xray-core/tar.gz/refs/tags/v26.3.27' -o "$archive.part"
	printf '%s  %s\n' 992a4997e6bb846d11469435d687f99ef812fcde1e0a009bb8e95189ea20331d "$archive.part" | shasum -a 256 -c
	mv "$archive.part" "$archive"
fi
printf '%s  %s\n' 992a4997e6bb846d11469435d687f99ef812fcde1e0a009bb8e95189ea20331d "$archive" | shasum -a 256 -c
mkdir -p "$out"
source=$(mktemp -d "$out/source.XXXXXX")
trap 'rm -rf "$source"' EXIT
trap 'exit 1' HUP INT TERM
tar -xzf "$archive" --strip-components=1 -C "$source"
"$go" -C "$source" mod verify
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 "$go" -C "$source" build -mod=readonly -trimpath -buildvcs=false \
	-ldflags='-s -w -buildid=' -o "$out/xray" ./main
