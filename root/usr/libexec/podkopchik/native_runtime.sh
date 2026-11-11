#!/bin/sh
set -eu
umask 077
LIB="${PODKOPCHIK_LIB:-/usr/libexec/podkopchik}"
# Boot, recovery and health use the immutable coordinator of the installed
# generation, not files that a package update may be replacing.
case "${1:-}" in
 apply|validate|generate|migration-readiness|migrate-check|migrate) ;;
 *)
	CONF="${PODKOPCHIK_CONFIG_DIR:-/etc/podkopchik}"
	if [ -f "$CONF/native-state/runtime.json" ]; then
		code=$(ucode -e 'import {lstat,readfile} from "fs";
			const root=ARGV[0]+"/native-state",file=root+"/runtime.json",s=lstat(file);
			if(s?.type!="file"||s.uid!=0||(s.mode&0o077)||s.nlink!=1)die("unsafe native pointer");
			const m=json(readfile(file));if(!m.code)return;
			if(index(m.code,root+"/code-")!=0||!match(substr(m.code,length(root+"/code-")),/^[a-f0-9]{64}$/))die("invalid recovery path");
			const d=lstat(m.code);if(d?.type!="directory"||d.uid!=0||(d.mode&0o077))die("unsafe recovery path");
			print(m.code);' "$CONF")
		if [ -n "$code" ]; then
			LIB="$code"
			export PODKOPCHIK_LIB="$LIB" PODKOPCHIK_NATIVE_DNS="$LIB/podkopchik-native-dns" PODKOPCHIK_CTL="$LIB/podkopchikctl"
		fi
	fi
	;;
esac
exec ucode -L "$LIB" "$LIB/native_runtime.uc" "$@"
