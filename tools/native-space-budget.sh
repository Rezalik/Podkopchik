#!/bin/sh
# Account for the flat review archive without unpacking or contacting a router.
set -eu
[ "$#" = 1 ] || { echo 'usage: native-space-budget.sh REVIEW.tar.gz' >&2; exit 2; }
archive="$1"
[ -f "$archive" ]
base=$(CDPATH= cd -- "$(dirname -- "$archive")" && pwd)
file=$(basename -- "$archive")
(cd "$base" && shasum -a 256 -c "$file.sha256" >&2)
compressed=$(wc -c < "$archive")
members=$(LC_ALL=C tar -tvzf "$archive")
printf '%s\n' "$members" | awk -v compressed="$compressed" '
function blocks(n) { return int((n + 4095) / 4096) * 4096 }
$1 !~ /^-/ || $5 !~ /^[0-9]+$/ { bad=1; next }
{ data+=$5; rounded+=blocks($5); files++ }
END {
  if (bad || !files) exit 1
  printf "archive_bytes=%d\nfile_count=%d\npayload_bytes=%d\npayload_4k_model_bytes=%d\n", compressed, files, data, rounded
  printf "tmp_archive_plus_payload_4k_bytes=%d\n", blocks(compressed)+rounded
  printf "overlay_model_with_2MiB_state_1MiB_recovery_4MiB_margin_bytes=%d\n", rounded+7*1048576
}'
