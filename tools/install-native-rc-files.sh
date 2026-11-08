#!/bin/sh
# Explicit static RC installation, without package installs or service restarts.
set -eu
umask 077
[ "$(id -u)" = 0 ] && [ "$(cat /tmp/sysinfo/board_name)" = xiaomi,redmi-router-ax6000-stock ]
[ "$#" = 1 ] && [ -d "$1/root" ] || exit 2
base=$(CDPATH= cd -- "$1" && pwd)
(cd "$base" && sha256sum -c SHA256SUMS >/dev/null)
if [ "$(uci -q get podkopchik.main.native_recovery_policy 2>/dev/null || true)" = repair ]; then
	ucode /etc/podkopchik-native-emergency/recovery.uc verify >/dev/null
fi
before=$(sha256sum /etc/config/podkopchik)
sh "$base/install-native-dns.sh" --preflight
sh "$base/install-native-dns.sh" --install
find "$base/root" -type f > "$base/install-files"
while IFS= read -r source; do
	rel=${source#"$base/root/"}
	case "$rel" in
		etc/config/podkopchik) continue ;;
		etc/init.d/podkopchik|etc/init.d/podkopchik-fakedns|etc/init.d/podkopchik-native-emergency|etc/hotplug.d/iface/95-podkopchik-fakedns|usr/bin/podkopchikctl|usr/libexec/rpcd/podkopchik.awg|usr/libexec/podkopchik/*.uc|usr/libexec/podkopchik/*.sh|usr/libexec/podkopchik/podkopchik-native-dns|lib/upgrade/keep.d/podkopchik-*|usr/share/luci/menu.d/luci-app-podkopchik.json|usr/share/rpcd/acl.d/luci-app-podkopchik.json|www/luci-static/resources/view/podkopchik/*.js|www/luci-static/resources/podkopchik/*.js) ;;
		*) echo "Unexpected RC payload member: $rel" >&2; exit 1 ;;
	esac
	ucode -e 'import {lstat} from "fs";let p=ARGV[0],parts=split(p,"/");
		for(let i=1;i<length(parts);i++){let d=join("/",slice(parts,0,i));if(!d)continue;let s=lstat(d);if(s&&(s.type!="directory"||s.uid!=0||(s.mode&0o022)))die("unsafe static target directory");}
		let s=lstat(p);if(s&&(s.type!="file"||s.uid!=0||s.nlink!=1||(s.mode&0o022)))die("unsafe static target file");' "/$rel"
	mkdir -p "/$(dirname "$rel")"
	chmod 755 "/$(dirname "$rel")"
	cp "$source" "/$rel.native-new.$$"
	case "$rel" in etc/init.d/*|etc/hotplug.d/*|usr/bin/*|usr/libexec/*) mode=755 ;; *) mode=644 ;; esac
	chmod "$mode" "/$rel.native-new.$$"
	mv "/$rel.native-new.$$" "/$rel"
done < "$base/install-files"
for dir in /usr/share/ucode/luci/i18n /usr/lib/lua/luci/i18n; do
	mkdir -p "$dir"
	cp "$base/i18n/ru/podkopchik.ru.lmo" "$dir/podkopchik.ru.lmo.native-new.$$"
	chmod 644 "$dir/podkopchik.ru.lmo.native-new.$$"
	mv "$dir/podkopchik.ru.lmo.native-new.$$" "$dir/podkopchik.ru.lmo"
done
[ "$(sha256sum /etc/config/podkopchik)" = "$before" ]
sync
echo 'RC files installed; existing UCI and running services retained. Native Apply is a separate explicit action.'
