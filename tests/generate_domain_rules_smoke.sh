#!/bin/sh

set -eu

if ! command -v ucode >/dev/null 2>&1; then
	echo "SKIP: ucode not available"
	exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/podkopchik" <<'EOF'
config settings 'main'
	option transparent_port '12345'
	option loglevel 'warning'

config domain_rule
	option enabled '1'
	option domain 'legacy.example.com'
	option target 'direct'
	option group_name 'Legacy'
	option group_tag 'legacy'

config domain_rule
	option enabled '1'
	list domain 'list1.example.com'
	list domain 'list2.example.com'
	option target 'direct'
	option group_name 'List'
	option group_tag 'list'

config domain_rule
	option enabled '1'
	option target 'direct'
	option group_name 'Hundred'
	option group_tag 'hundred'
EOF

i=1
while [ "$i" -le 100 ]; do
	printf "\tlist domain 'bulk%03d.example.com'\n" "$i" >> "$tmp/podkopchik"
	i=$((i + 1))
done

out="$tmp/config.json"
UCI_CONFIG_DIR="$tmp" ucode -L root/usr/libexec/podkopchik root/usr/libexec/podkopchik/generate.uc > "$out"

grep -q '"domain:legacy.example.com"' "$out"
grep -q '"domain:list1.example.com"' "$out"
grep -q '"domain:list2.example.com"' "$out"
grep -q '"domain:bulk001.example.com"' "$out"
grep -q '"domain:bulk100.example.com"' "$out"

echo "generate domain rules smoke OK"
