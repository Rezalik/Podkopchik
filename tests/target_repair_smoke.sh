#!/bin/sh

set -eu

tmp="tests/.tmp.target-repair.$$"
rm -rf "$tmp"
mkdir -p "$tmp/bin" "$tmp/config" "$tmp/runtime"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/bin/uci" <<'EOF'
#!/bin/sh

[ "${1:-}" = "-q" ] && shift
cmd="${1:-}"
arg="${2:-}"

case "$cmd" in
	get)
		case "$arg" in
			podkopchik.@proxy\[0\]) echo proxy ;;
			podkopchik.@proxy\[0\].tag) echo proxy8444 ;;
			podkopchik.@proxy\[0\].enabled) echo 1 ;;
			podkopchik.@proxy\[0\].uri) exit 1 ;;
			podkopchik.@proxy\[1\]) exit 1 ;;

			podkopchik.@proxy_group\[0\]) echo proxy_group ;;
			podkopchik.@proxy_group\[0\].enabled) echo 1 ;;
			podkopchik.@proxy_group\[0\].tag) echo auto_proxy_group ;;
			podkopchik.@proxy_group\[0\].mode) echo strict_primary ;;
			podkopchik.@proxy_group\[0\].primary) echo proxy8444 ;;
			podkopchik.@proxy_group\[1\]) exit 1 ;;

			podkopchik.@domain_rule\[0\]) echo domain_rule ;;
			podkopchik.@domain_rule\[0\].enabled) echo 1 ;;
			podkopchik.@domain_rule\[0\].target) echo gerWARP ;;
			podkopchik.@domain_rule\[1\]) exit 1 ;;

			podkopchik.@ip_rule\[0\]) echo ip_rule ;;
			podkopchik.@ip_rule\[0\].enabled) echo 1 ;;
			podkopchik.@ip_rule\[0\].target) echo gerWARP ;;
			podkopchik.@ip_rule\[1\]) exit 1 ;;

			podkopchik.@lan_device\[0\]) echo lan_device ;;
			podkopchik.@lan_device\[0\].enabled) echo 1 ;;
			podkopchik.@lan_device\[0\].mode) echo full_proxy ;;
			podkopchik.@lan_device\[0\].target) echo gerWARP ;;
			podkopchik.@lan_device\[1\]) exit 1 ;;

			*) exit 1 ;;
		esac
		;;
	set)
		echo "set $arg" >> "$PODKOPCHIK_TEST_LOG"
		;;
	commit)
		echo "commit ${arg:-}" >> "$PODKOPCHIK_TEST_LOG"
		;;
	*)
		exit 1
		;;
esac
EOF

cat > "$tmp/bin/ucode" <<'EOF'
#!/bin/sh

echo '{"ok":true}'
EOF

cat > "$tmp/bin/logger" <<'EOF'
#!/bin/sh

echo "logger $*" >> "$PODKOPCHIK_TEST_LOG"
EOF

chmod +x "$tmp/bin/uci" "$tmp/bin/ucode" "$tmp/bin/logger"

log="$tmp/repair.log"
out="$tmp/generated.json"
err="$tmp/generate.err"

PATH="$tmp/bin:$PATH" \
	PODKOPCHIK_CONFIG_DIR="$tmp/config" \
	PODKOPCHIK_TMP_DIR="$tmp/runtime" \
	PODKOPCHIK_TEST_LOG="$log" \
	sh root/usr/bin/podkopchikctl generate "$out" 2>"$err" >/dev/null

grep -q "set podkopchik.@domain_rule\\[0\\].target=auto_proxy_group" "$log"
grep -q "set podkopchik.@ip_rule\\[0\\].target=auto_proxy_group" "$log"
grep -q "set podkopchik.@lan_device\\[0\\].target=auto_proxy_group" "$log"
grep -q "commit podkopchik" "$log"
grep -q "repaired stale routing target 'gerWARP'" "$err"
grep -q '"ok":true' "$out"

echo "target repair smoke OK"
