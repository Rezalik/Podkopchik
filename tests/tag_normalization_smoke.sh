#!/bin/sh
set -eu
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp/bin"
export PODKOPCHIK_REAL_TR="$(command -v tr)"
awk '/^clean_tag\(\)/,/^}/' root/usr/bin/podkopchikctl > "$tmp/function.sh"
cat > "$tmp/bin/tr" <<'EOF'
#!/bin/sh
# Reproduce a BusyBox build where character class expansion is unavailable.
case "$1" in *'[:upper:]'*|*'[:lower:]'*) exit 1 ;; esac
exec "$PODKOPCHIK_REAL_TR" "$@"
EOF
chmod +x "$tmp/bin/tr"
export PATH="$tmp/bin:$PATH"
check() {
	actual="$(sh -c '. "$1"; clean_tag "$2"' sh "$tmp/function.sh" "$1")"
	[ "$actual" = "$2" ] || { echo "FAIL: tag normalization: $1" >&2; exit 1; }
}
check auto_proxy_group auto_proxy_group
check port8444 port8444
check gerWARP gerwarp
check '  Main Proxy!  ' main_proxy
check 123proxy p_123proxy
echo 'tag normalization smoke OK (no tr character classes)'
