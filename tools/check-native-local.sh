#!/bin/sh
# Workstation checks only. Network/boot acceptance is a separate QEMU run.
set -u
umask 077
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$base" || exit 1
out="$base/.build/native-local-checks"
mkdir -p "$out"
failed=0
for test in tests/*_smoke.sh tests/*_smoke.js; do
	name=$(basename "$test")
	case "$test" in *.js) runner=node;; *) runner=sh;; esac
	if (umask 022; "$runner" "$test") > "$out/$name.log" 2>&1; then
		if grep -qi 'SKIP' "$out/$name.log"; then printf 'SKIPPED %s\n' "$name"
		else printf 'PASS %s\n' "$name"; fi
	else
		printf 'FAIL %s\n' "$name"
		tail -12 "$out/$name.log"
		failed=1
	fi
done
find root tools tests native/runtime -type f \( -name '*.sh' -o -path 'root/etc/init.d/*' \) -print > "$out/shell-files"
while IFS= read -r path; do sh -n "$path" || failed=1; done < "$out/shell-files"
for path in root/www/luci-static/resources/view/podkopchik/*.js; do node --check "$path" || failed=1; done
node -e 'const f=require("fs"),p=require("path");function check(d){for(const x of f.readdirSync(d,{withFileTypes:true})){const n=p.join(d,x.name);if(x.isDirectory())check(n);else if(n.endsWith(".json"))JSON.parse(f.readFileSync(n,"utf8"));}}check("root");check("tests/fixtures");' || failed=1
msgfmt -c po/ru/podkopchik.po -o "$out/podkopchik-ru.mo" || failed=1
git diff --check || failed=1
exit "$failed"
