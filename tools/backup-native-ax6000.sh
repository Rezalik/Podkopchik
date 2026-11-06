#!/bin/sh
# Authorized operator action on the Mac; no files are written on OpenWrt.
set -eu
umask 077
[ "$(uname -s)" = Darwin ] && [ "${1:-}" = --capture-xiaomi ] && [ "$#" = 1 ] || {
	echo 'Usage on Mac after authorization: sh tools/backup-native-ax6000.sh --capture-xiaomi' >&2
	exit 2
}
base="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
parent="$base/.router-backups"
git -C "$base" check-ignore -q .router-backups/ax6000-native-backup
[ -d "$parent" ] && [ ! -L "$parent" ] && [ "$(stat -f '%u:%Lp' "$parent")" = "$(id -u):700" ] || {
	echo 'Backup parent must be a private directory owned by the current user' >&2
	exit 1
}
dest=$(mktemp -d "$parent/ax6000-native-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
raw="$dest/transfer.tar"
tmp="$dest/backup.tar.gz.part"
index="$dest/transfer.index"
trap 'rm -f "$raw" "$tmp" "$index"' EXIT
trap 'exit 1' HUP INT TERM

ssh -T -o BatchMode=yes -o ConnectTimeout=6 -o ServerAliveInterval=10 -o ServerAliveCountMax=2 \
	-o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o ClearAllForwardings=yes openwrt 'sh -s' > "$raw" <<'REMOTE'
set -eu
[ "$(cat /tmp/sysinfo/board_name)" = xiaomi,redmi-router-ax6000-stock ]
[ "$(uname -r)" = 6.12.112 ]
. /etc/openwrt_release
[ "$DISTRIB_RELEASE" = 25.12.6 ]
cd /
set -- etc usr/bin/podkopchikctl usr/bin/xray usr/libexec/podkopchik
for path in www/luci-static/resources/view/podkopchik usr/share/luci/menu.d/luci-app-podkopchik.json \
	usr/share/rpcd/acl.d/luci-app-podkopchik.json usr/share/ucode/luci/i18n/podkopchik.ru.lmo \
	usr/lib/lua/luci/i18n/podkopchik.ru.lmo usr/libexec/rpcd/podkopchik.awg \
	lib/upgrade/keep.d/podkopchik-awg lib/upgrade/keep.d/podkopchik-fakedns; do
	[ ! -e "$path" ] || set -- "$@" "$path"
done
if command -v nice >/dev/null; then exec nice -n 10 tar -cf - "$@"; fi
exec tar -cf - "$@"
REMOTE
tar -tf "$raw" > "$index"
awk '
	/^etc\/config\/network$/ {n=1}
	/^etc\/config\/firewall$/ {f=1}
	/^etc\/config\/dhcp$/ {d=1}
	/^etc\/config\/podkopchik$/ {p=1}
	/^etc\/podkopchik\/config.json$/ {x=1}
	/^etc\/podkopchik\/awg\/.+/ {a=1}
	/^usr\/bin\/xray$/ {b=1}
	END {exit !(n && f && d && p && x && a && b)}' "$index"
gzip -n -c "$raw" > "$tmp"
gzip -t "$tmp"
raw_hash=$(shasum -a 256 "$raw" | awk '{print $1}')
decoded_hash=$(gzip -dc "$tmp" | shasum -a 256 | awk '{print $1}')
[ "$raw_hash" = "$decoded_hash" ]
mv "$tmp" "$dest/backup.tar.gz"
(cd "$dest" && shasum -a 256 backup.tar.gz > SHA256SUMS && shasum -a 256 -c SHA256SUMS)
printf 'Private backup: %s\nCompressed bytes: %s\nTar bytes: %s\n' "$dest/backup.tar.gz" \
	"$(stat -f %z "$dest/backup.tar.gz")" "$(stat -f %z "$raw")"
