#!/bin/sh
# Explicit operator rollback only. Retains CURRENT VLESS config and profiles.
set -eu
umask 077
fail() { echo "AWG rollback: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || fail 'root required'
[ "$(cat /tmp/sysinfo/board_name)" = xiaomi,redmi-router-ax6000-stock ] || fail 'wrong board'
# Refuse until the user has explicitly selected working VLESS and retargeted
# every AWG rule. Never silently fall back to direct or overwrite new VLESS.
ucode -e '
import { cursor } from "uci"; import * as fs from "fs";
let c=cursor(), main=0;
c.foreach("podkopchik","proxy",function(p){
 if(p.protocol=="amneziawg" && p.enabled!="0") die("Disable AWG assignments first");
 if(p.protocol!="amneziawg" && p.role=="rules_only") die("Assign a legacy-compatible VLESS role first");
 if(p.protocol!="amneziawg" && p.role=="main" && p.enabled!="0") main++;
});
if(main!=1) die("Select one working VLESS main first");
for(let t in ["domain_rule","ip_rule","lan_device","proxy_group"])
 c.foreach("podkopchik",t,function(r){
  for(let k in ["target","primary","backup1","backup2","backup3","fixed_proxy","manual_override_proxy"])
   if(match(r[k]||"",/^awg_/)) die("Explicitly retarget AWG rules/groups first");
 });
for(let o in json(fs.readfile("/etc/podkopchik/config.json")).outbounds||[])
 if(match(o.tag||"",/^awg_/)) die("Apply VLESS-only routing before rollback");
' || fail 'current configuration is not safe for the previous version'
case "${1:---check}" in
 --check) echo 'Rollback prerequisites OK; no changes made'; exit 0 ;;
 --restore) [ "$#" = 3 ] || fail 'usage: awg-rollback.sh --restore /root/BACKUP.tar.gz EXPECTED_SHA256' ;;
 *) fail 'usage: awg-rollback.sh --check | --restore /root/BACKUP.tar.gz EXPECTED_SHA256' ;;
esac
case "$2" in /root/*) ;; *) fail 'use the protected on-router backup' ;; esac
[ "$(sha256sum "$2" | awk '{print $1}')" = "$3" ] || fail 'backup checksum mismatch'
work="$(mktemp -d /tmp/podkopchik-rollback.XXXXXX)"
trap 'rm -rf "$work"' EXIT HUP INT TERM
tar -tzf "$2" > "$work/list"
if grep -q '^usr/libexec/podkopchik/awg_manage.uc$' "$work/list"; then
	fail 'this rollback tool requires a pre-Stage-2/3 backup, not another mixed-runtime release'
fi
for path in etc/init.d/podkopchik usr/bin/podkopchikctl usr/libexec/podkopchik \
 usr/libexec/rpcd/podkopchik.awg usr/share/luci/menu.d/luci-app-podkopchik.json \
 usr/share/rpcd/acl.d/luci-app-podkopchik.json www/luci-static/resources/view/podkopchik \
 lib/upgrade/keep.d/podkopchik-awg; do
	grep -q "^$path\(/\|$\)" "$work/list" || fail "backup lacks $path"
	printf '%s\n' "$path" >> "$work/restore"
done
for path in usr/share/ucode/luci/i18n/podkopchik.ru.lmo usr/lib/lua/luci/i18n/podkopchik.ru.lmo; do
	if grep -qx "$path" "$work/list"; then printf '%s\n' "$path" >> "$work/restore"; fi
done
# Only now stop the app and remove validated ownership, before restoring code.
/etc/init.d/podkopchik stop
ucode -L /usr/libexec/podkopchik /usr/libexec/podkopchik/awg_cli.uc dispose-all
cp -p /etc/config/podkopchik "$work/current-uci"
ucode -e '
import { cursor } from "uci";
let c=cursor(), remove=[];
c.foreach("podkopchik","proxy",function(p){if(p.protocol=="amneziawg")push(remove,p[".name"]);});
for(let id in remove)c.delete("podkopchik",id);
if(!c.commit("podkopchik"))exit(1);
'
if ! tar -xzf "$2" -C / $(cat "$work/restore"); then
	cp -p "$work/current-uci" /etc/config/podkopchik
	fail 'code restore failed; keep SSH open, use the protected deployment backup'
fi
rm -f /usr/libexec/podkopchik/awg_cli.uc /usr/libexec/podkopchik/awg_manage.uc /usr/libexec/podkopchik/awg_network.uc
podkopchikctl validate
podkopchikctl apply
/etc/init.d/rpcd reload
echo 'Previous public code restored; current VLESS settings and private AWG profiles retained'
