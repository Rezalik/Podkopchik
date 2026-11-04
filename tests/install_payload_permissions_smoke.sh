#!/bin/sh
set -eu

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
die() { echo "$*" >&2; exit 1; }
eval "$(sed -n '/^install_payload_dir() {/,/^}/p' install.sh)"

mode() { LC_ALL=C ls -ld "$1" | awk '{print substr($1, 1, 10)}'; }
for source_mode in 700 775; do
	payload="$tmp/payload-$source_mode"
	DESTDIR="$tmp/destination-$source_mode"
	mkdir -p "$payload/etc" "$DESTDIR/unrelated-private"
	chmod "$source_mode" "$payload" "$payload/etc"
	chmod 700 "$DESTDIR/unrelated-private"
	printf '%s\n' private-fixture > "$payload/etc/fixture"
	chmod 600 "$payload/etc/fixture"
	install_payload_dir "$payload"
	[ "$(mode "$DESTDIR")" = drwxr-xr-x ]
	[ "$(mode "$DESTDIR/etc")" = drwxr-xr-x ]
	[ "$(mode "$DESTDIR/etc/fixture")" = -rw------- ]
	[ "$(mode "$DESTDIR/unrelated-private")" = drwx------ ]
	[ "$(cat "$DESTDIR/etc/fixture")" = private-fixture ]
done
echo 'Installer payload permissions smoke OK (0700/0775 sources, private files retained)'
