#!/bin/sh
# Launched only by the dedicated procd deployment service, never by LuCI.
set -eu
umask 077
dir="${1:-}"
case "$dir" in /root/podkopchik-stage4-*) ;; *) exit 1 ;; esac
exec >> "$dir/deploy.log" 2>&1
if [ ! -f "$dir/deploy.rc" ]; then
	export PODKOPCHIK_STAGE4_GUARD="$dir"
	rc=0
	sh "$dir/install.sh" --install "$dir/overlay.tar.gz" "$(cat "$dir/overlay.sha256")" || rc=$?
	printf '%s\n' "$rc" > "$dir/deploy.rc"
fi
# A procd restart cannot accidentally repeat an installation already completed.
while :; do sleep 5; done
