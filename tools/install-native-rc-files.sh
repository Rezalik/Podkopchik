#!/bin/sh
# Explicit static RC installation, without package installs or service restarts.
set -eu
umask 077
[ "$(id -u)" = 0 ]
root="${PODKOPCHIK_INSTALL_ROOT:-}"
if [ -n "$root" ]; then
	case "$root" in /tmp/pkc-component-*) ;; *) exit 2;; esac
	[ -d "$root" ] && [ ! -L "$root" ]
else
	[ "$(cat /tmp/sysinfo/board_name)" = xiaomi,redmi-router-ax6000-stock ]
fi
[ "$#" = 1 ] && [ -d "$1/root" ] || exit 2
base=$(CDPATH= cd -- "$1" && pwd)
(cd "$base" && sha256sum -c SHA256SUMS >/dev/null)
if [ -z "$root" ]; then
	if [ "$(uci -q get podkopchik.main.native_recovery_policy 2>/dev/null || true)" = repair ]; then
		ucode /etc/podkopchik-native-emergency/recovery.uc verify >/dev/null
	fi
fi
before=$(sha256sum "$root/etc/config/podkopchik")
sh "$base/install-native-dns.sh" --preflight
work=$(mktemp -d /tmp/pkc-static-update.XXXXXX)
committing=0
restore() {
	rc=$?
	trap - EXIT HUP INT TERM
	if [ "$rc" != 0 ] && [ "$committing" = 1 ]; then
		while IFS= read -r rel; do rm -f "$root/$rel.native-new.$$" "$root/$rel.native-restore.$$"; done < "$work/files"
		while IFS= read -r rel; do
			if [ -f "$work/old/$rel" ]; then
				cp -p "$work/old/$rel" "$root/$rel.native-restore.$$" && mv "$root/$rel.native-restore.$$" "$root/$rel" || rc=2
			else rm -f "$root/$rel"; fi
		done < "$work/files"
	fi
	if [ "$rc" = 2 ] && [ "$committing" = 1 ]; then
		echo "Static restoration needs attention; private backup retained at $work" >&2
		exit "$rc"
	fi
	rm -rf "$work"
	exit "$rc"
}
trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
find "$base/root" -type f > "$work/sources"
# Validate the entire target list before the first persistent write.
while IFS= read -r source; do
	rel=${source#"$base/root/"}
	case "$rel" in
		etc/config/podkopchik) continue ;;
		etc/init.d/podkopchik|etc/init.d/podkopchik-fakedns|etc/init.d/podkopchik-native-emergency|etc/hotplug.d/iface/95-podkopchik-fakedns|usr/bin/podkopchikctl|usr/libexec/rpcd/podkopchik.awg|usr/libexec/podkopchik/*.uc|usr/libexec/podkopchik/*.sh|usr/libexec/podkopchik/podkopchik-native-dns|lib/upgrade/keep.d/podkopchik-*|usr/share/luci/menu.d/luci-app-podkopchik.json|usr/share/rpcd/acl.d/luci-app-podkopchik.json|www/luci-static/resources/view/podkopchik/*.js|www/luci-static/resources/podkopchik/*.js) ;;
		*) echo "Unexpected RC payload member: $rel" >&2; exit 1 ;;
	esac
	printf '%s\n' "$rel" >> "$work/files"
done < "$work/sources"
for dir in /usr/share/ucode/luci/i18n /usr/lib/lua/luci/i18n; do
	printf '%s\n' "${dir#/}/podkopchik.ru.lmo" >> "$work/files"
done
while IFS= read -r rel; do
	ucode -e 'import {lstat} from "fs";let parts=split(ARGV[1],"/"),p=ARGV[0];
		for(let i=0;i<length(parts)-1;i++){p+="/"+parts[i];let s=lstat(p);if(s&&(s.type!="directory"||s.uid!=0||(s.mode&0o022)))die("unsafe static target directory");}
		let s=lstat(ARGV[0]+"/"+ARGV[1]);if(s&&(s.type!="file"||s.uid!=0||s.nlink!=1||(s.mode&0o022)))die("unsafe static target file");' "$root" "$rel"
	mkdir -p "$work/new/$(dirname "$rel")" "$work/old/$(dirname "$rel")"
	[ ! -f "$root/$rel" ] || cp -p "$root/$rel" "$work/old/$rel"
	case "$rel" in */i18n/podkopchik.ru.lmo) source="$base/i18n/ru/podkopchik.ru.lmo" ;; *) source="$base/root/$rel" ;; esac
	cp "$source" "$work/new/$rel"
	case "$rel" in etc/init.d/*|etc/hotplug.d/*|usr/bin/*|usr/libexec/*) mode=755 ;; *) mode=644 ;; esac
	chmod "$mode" "$work/new/$rel"
done < "$work/files"
# The immutable helper is additive; retain it if an interrupted static update
# needs retrying. The previous generation keeps its own pinned helper/launcher.
committing=1
sh "$base/install-native-dns.sh" --install
while IFS= read -r rel; do
	mkdir -p "$root/$(dirname "$rel")"
	cp -p "$work/new/$rel" "$root/$rel.native-new.$$"
	mv "$root/$rel.native-new.$$" "$root/$rel"
done < "$work/files"
[ "$(sha256sum "$root/etc/config/podkopchik")" = "$before" ]
sync
echo 'RC files installed; existing UCI and running services retained. Native Apply is a separate explicit action.'
