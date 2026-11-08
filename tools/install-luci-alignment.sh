#!/bin/sh
# Scoped static-file update. Native Apply and web-service restarts are separate.
set -eu
umask 077
[ "$(id -u)" = 0 ]
[ "$(cat /tmp/sysinfo/board_name)" = xiaomi,redmi-router-ax6000-stock ]
[ "$#" = 2 ] || exit 2
action=$1
base=$(CDPATH= cd -- "$2" && pwd)
case "$base" in /tmp/pkc-luci-update.*) ;; *) exit 2 ;; esac
list="$base/files"
backup="$base/before"

validate() {
	ucode -e 'import * as fs from "fs";
		const base=ARGV[0],d=fs.lstat(base);
		if(d?.type!="directory"||d.uid!=0||(d.mode&0o077))die("unsafe update directory");
		const rows=split(trim(fs.readfile(base+"/files") || ""),"\n"),seen={};
		if(!length(rows)||length(rows)>64)die("invalid file list");
		for(let n in rows){
			if(seen[n]||index(n,"..")>=0||!match(n,/^[a-zA-Z0-9_.\/-]+$/))die("invalid update member");seen[n]=true;
			if(!match(n,/^www\/luci-static\/resources\/(view\/)?podkopchik\/[a-zA-Z0-9_-]+\.js$/)&&
				index(["usr/bin/podkopchikctl","usr/libexec/podkopchik/generate.uc","usr/libexec/podkopchik/native_runtime.uc",
				"usr/share/ucode/luci/i18n/podkopchik.ru.lmo","usr/lib/lua/luci/i18n/podkopchik.ru.lmo"],n)<0)die("unexpected update member");
			let s=fs.lstat(base+"/payload/"+n);if(s?.type!="file"||s.uid!=0||s.nlink!=1||(s.mode&0o022)||s.size>262144)die("unsafe update member");
			let parts=split("/"+n,"/");for(let i=2;i<=length(parts);i++){
				let p=join("/",slice(parts,0,i)),s=fs.lstat(p);if(!s)continue;
				if(s.uid!=0||(s.mode&0o022)||(i<length(parts)?s.type!="directory":s.type!="file"||s.nlink!=1))die("unsafe update target");
			}
		}
		for(let line in split(trim(fs.readfile(base+"/SHA256SUMS") || ""),"\n")){
			let m=match(line,/^[a-f0-9]{64}  (.+)$/);if(!m||!seen[m[1]])die("unexpected checksum member");delete seen[m[1]];
		}if(length(keys(seen)))die("missing checksum");' "$base"
	(cd "$base/payload" && sha256sum -c "$base/SHA256SUMS" >/dev/null)
}

restore() {
	[ -f "$backup/saved" ] && [ -f "$backup/missing" ] || return 1
	while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		[ -f "$backup/files/$rel" ] || return 1
		cp -p "$backup/files/$rel" "/$rel.pkc-restore.$$"
		mv "/$rel.pkc-restore.$$" "/$rel"
	done < "$backup/saved"
	while IFS= read -r rel; do
		[ -n "$rel" ] || continue
		if [ -f "/$rel" ]; then
			expected=$(awk -v path="$rel" '$2 == path { print $1 }' "$base/SHA256SUMS")
			actual=$(sha256sum "/$rel" | awk '{print $1}')
			[ "$actual" = "$expected" ] || return 1
			rm "/$rel"
		fi
	done < "$backup/missing"
	sync
}

case "$action" in
check) validate; echo 'Scoped payload and targets verified.' ;;
restore) validate; restore; echo 'Static files restored; no routing action performed.' ;;
install)
	validate
	[ ! -e "$backup" ] || { echo 'Backup already exists.' >&2; exit 1; }
	if [ "$(uci -q get podkopchik.main.native_recovery_policy 2>/dev/null || true)" = repair ]; then
		ucode /etc/podkopchik-native-emergency/recovery.uc verify >/dev/null
	fi
	[ "$(uci -q get podkopchik.main.routing_engine)" = native ]
	[ "$(uci -q get podkopchik.main.native_classification_mode)" = compatible ]
	[ "$(uci -q get podkopchik.main.native_migration_restrict_unknown)" = 0 ]
	before=$(sha256sum /etc/config/podkopchik)
	mkdir -m 700 "$backup"
	: > "$backup/saved"
	: > "$backup/missing"
	while IFS= read -r rel; do
		if [ -f "/$rel" ]; then
			mkdir -p "$backup/files/$(dirname "$rel")"
			cp -p "/$rel" "$backup/files/$rel"
			printf '%s\n' "$rel" >> "$backup/saved"
		else
			printf '%s\n' "$rel" >> "$backup/missing"
		fi
	done < "$list"
	printf '%s\n' "$before" > "$backup/uci.sha256"
	changed=0
	committed=0
	finish() { rc=$?; trap - EXIT HUP INT TERM; if [ "$changed" = 1 ] && [ "$committed" = 0 ]; then restore || rc=1; fi; exit "$rc"; }
	trap finish EXIT
	trap 'exit 1' HUP INT TERM
	changed=1
	while IFS= read -r rel; do
		mkdir -p "/$(dirname "$rel")"
		cp "$base/payload/$rel" "/$rel.pkc-new.$$"
		case "$rel" in usr/bin/*|usr/libexec/*) mode=755 ;; *) mode=644 ;; esac
		chmod "$mode" "/$rel.pkc-new.$$"
		mv "/$rel.pkc-new.$$" "/$rel"
	done < "$list"
	(cd / && sha256sum -c "$base/SHA256SUMS" >/dev/null)
	[ "$(sha256sum /etc/config/podkopchik)" = "$before" ]
	sh -n /usr/bin/podkopchikctl
	ucode -c -o "$base/native-runtime.ucb" -L /usr/libexec/podkopchik /usr/libexec/podkopchik/native_runtime.uc
	sync
	committed=1
	echo 'Static UI/status files installed; UCI unchanged. No service restarted; Native Apply remains separate.'
	;;
*) exit 2 ;;
esac
