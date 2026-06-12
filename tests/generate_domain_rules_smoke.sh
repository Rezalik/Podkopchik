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
	list domain 'youtube.com'
	list domain 'youtu.be'
	list domain 'googlevideo.com'
	list domain 'ytimg.com'
	option target 'direct'
	option group_name 'YouTube'
	option group_tag 'youtube'

config domain_rule
	option enabled '1'
	list domain 'x.com'
	list domain 'twitter.com'
	list domain 'twimg.com'
	option target 'direct'
	option group_name 'X / Twitter'
	option group_tag 'twitter'

config domain_rule
	option enabled '1'
	list domain 'instagram.com'
	list domain 'threads.net'
	list domain 'fbsbx.com'
	list domain 'messenger.com'
	list domain 'oculus.com'
	option target 'direct'
	option group_name 'Instagram'
	option group_tag 'instagram'

config domain_rule
	option enabled '1'
	list domain 'abs.twimg.com'
	list domain 'pbs.twimg.com'
	list domain 'twitterstat.us'
	list domain 'twtrdns.net'
	list domain 'twitterflightschool.com'
	option target 'direct'
	option group_name 'Twitter'
	option group_tag 'twitter_regression'

config domain_rule
	option enabled '1'
	list domain 'tiktokcdn-us.com'
	list domain 'byteoversea.com'
	list domain 'ibytedtos.com'
	list domain 'muscdn.com'
	list domain 'musical.ly'
	option target 'direct'
	option group_name 'TikTok'
	option group_tag 'tiktok'

config domain_rule
	option enabled '1'
	option domain 'mixed.example.com, mixed2.example.com; mixed3.example.com'
	option target 'direct'
	option group_name 'Mixed'
	option group_tag 'mixed'

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
grep -q '"domain:youtube.com"' "$out"
grep -q '"domain:youtu.be"' "$out"
grep -q '"domain:googlevideo.com"' "$out"
grep -q '"domain:ytimg.com"' "$out"
grep -q '"domain:x.com"' "$out"
grep -q '"domain:twitter.com"' "$out"
grep -q '"domain:twimg.com"' "$out"
grep -q '"domain:mixed.example.com"' "$out"
grep -q '"domain:mixed2.example.com"' "$out"
grep -q '"domain:mixed3.example.com"' "$out"
grep -q '"domain:bulk001.example.com"' "$out"
grep -q '"domain:bulk100.example.com"' "$out"

for domain in \
	instagram.com \
	threads.net \
	fbsbx.com \
	messenger.com \
	oculus.com \
	abs.twimg.com \
	pbs.twimg.com \
	twitterstat.us \
	twtrdns.net \
	twitterflightschool.com \
	tiktokcdn-us.com \
	byteoversea.com \
	ibytedtos.com \
	muscdn.com \
	musical.ly; do
	grep -q "\"domain:$domain\"" "$out" || {
		echo "missing expected domain:$domain"
		exit 1
	}
done

for fragment in \
	in \
	tagram.com \
	thread \
	.net \
	ab \
	pb \
	twtrdn \
	twitterflight \
	chool.com \
	mu \
	ical.ly; do
	if grep -q "\"domain:$fragment\"" "$out"; then
		echo "unexpected broken domain fragment: domain:$fragment"
		exit 1
	fi
done

echo "generate domain rules smoke OK"
