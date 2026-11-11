#!/bin/sh
# Installs the immutable helper only. Never starts a service or changes UCI.
set -eu
umask 077
base=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root="${PODKOPCHIK_INSTALL_ROOT:-}"
case "${1:---preflight}" in --preflight|--install) ;; *) echo 'Use --preflight or --install' >&2; exit 2;; esac
[ "$(id -u)" = 0 ] || { echo 'Root is required' >&2; exit 1; }
admission=admit
if [ -n "$root" ]; then
	case "$root" in /tmp/pkc-component-*) ;; *) echo 'Invalid isolated staging root' >&2; exit 1;; esac
	[ -d "$root" ] && [ ! -L "$root" ]
	[ "$(tr -d '\000' < /proc/device-tree/model)" = linux,dummy-virt ]
	[ "$(ls /sys/class/net)" = lo ]
	ucode -e 'import {lstat} from "fs"; let s=lstat(ARGV[0]);
		if(s?.type!="directory"||s.uid!=0||(s.mode&0o777)!=0o700) exit(1);' "$root"
	admission=verify
fi
expected=$(cat "$base/NATIVE_DNS_SHA256")
[ "${#expected}" = 64 ]
case "$expected" in *[!a-f0-9]*) exit 1;; esac
(cd "$base" && sha256sum -c SHA256SUMS >/dev/null)
lib="$base/root/usr/libexec/podkopchik"
ucode -L "$lib" "$lib/native_package_check.uc" "$admission" "$lib/native-targets.json" "$base"
source="$base/native-bin/$expected"
target="$root/etc/podkopchik/native-bin/$expected"
ucode -e 'import {lstat} from "fs";
	for(let p in ["/etc","/etc/podkopchik","/etc/podkopchik/native-bin","/usr","/usr/libexec","/usr/libexec/podkopchik"]){
		let s=lstat(ARGV[0]+p);if(s&&(s.type!="directory"||s.uid!=0||(s.mode&0o022)))die("unsafe Native component directory");
	}
	let s=lstat(ARGV[1]);if(s&&(s.type!="file"||s.uid!=0||s.nlink!=1||(s.mode&0o022)))die("unsafe Native component target");' "$root" "$target"
extra=$(( ($(wc -c < "$source") + 4095) / 4096 * 4 ))
if [ -e "$target" ]; then
	[ -f "$target" ] && [ ! -L "$target" ]
	[ "$(sha256sum "$target" | awk '{print $1}')" = "$expected" ]
	extra=0
fi
# 8 MiB untouched reserve, 4 MiB bounded DNS WAL, 1.5 MiB coordinator/snapshots.
required=$((extra + 13824))
volume="${root:-/overlay}"
free=$(df -Pk "$volume" | awk 'END {print $4}')
tmp_free=$(df -Pk /tmp | awk 'END {print $4}')
memory=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
printf 'new_helper_kib=%s required_flash_kib=%s free_flash_kib=%s tmp_free_kib=%s ram_available_kib=%s\n' "$extra" "$required" "$free" "$tmp_free" "$memory"
[ "$free" -ge "$required" ] && [ "$tmp_free" -ge 49152 ] && [ "$memory" -ge 98304 ]
[ "${1:---preflight}" = --install ] || exit 0
mkdir -p "$root/etc/podkopchik/native-bin" "$root/usr/libexec/podkopchik"
if [ ! -e "$target" ]; then
	stage="$target.new.$$"
	trap 'rm -f "$stage"' EXIT HUP INT TERM
	cp "$source" "$stage"
	chmod 755 "$stage"
	[ "$(sha256sum "$stage" | awk '{print $1}')" = "$expected" ]
	caps=$("$stage" -capabilities)
	printf '%s\n' "$caps" | ucode -e 'import {stdin} from "fs"; let c=json(stdin.read("all"));
		if(c?.schema!==3||c.bounded_commands!==true||c.persistent_dns!==true||c.protected_dns!==true) exit(1);'
	mv "$stage" "$target"
	trap - EXIT HUP INT TERM
fi
sync
echo 'Immutable Native DNS helper installed. Launcher publication belongs to the static bundle transaction.'
