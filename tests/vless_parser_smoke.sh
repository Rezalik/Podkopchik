#!/bin/sh

set -eu

if ! command -v ucode >/dev/null 2>&1; then
	echo "SKIP: ucode not available"
	exit 0
fi

LIB="root/usr/libexec/podkopchik"
UUID="11111111-2222-3333-4444-555555555555"
HOST="famalymovi.ru"
PORT="443"
PBK="FAKE_PUBLIC_KEY_FOR_PARSER_SMOKE"
SID="abcd"

parse_ok() {
	label="$1"
	uri="$2"
	expected_path="${3:-}"

	out="$(ucode -L "$LIB" "$LIB/parse_vless.uc" "$uri")" || {
		echo "FAIL: $label did not parse"
		exit 1
	}

	printf '%s\n' "$out" | grep -q '"host":"famalymovi.ru"' || {
		echo "FAIL: $label parsed wrong host"
		exit 1
	}

	printf '%s\n' "$out" | grep -q '"port":443' || {
		echo "FAIL: $label parsed wrong port"
		exit 1
	}

	if [ -n "$expected_path" ]; then
		printf '%s\n' "$out" | grep -q "\"path\":\"$expected_path\"" || {
			echo "FAIL: $label parsed wrong path"
			exit 1
		}
	fi
}

parse_expected_error() {
	label="$1"
	uri="$2"
	expected="$3"
	err="/tmp/podkopchik-vless-parser-smoke.err"

	if ucode -L "$LIB" "$LIB/parse_vless.uc" "$uri" >/dev/null 2>"$err"; then
		rm -f "$err"
		echo "FAIL: $label unexpectedly parsed"
		exit 1
	fi

	if grep -q "invalid port in VLESS URI" "$err"; then
		rm -f "$err"
		echo "FAIL: $label failed with invalid port"
		exit 1
	fi

	grep -q "$expected" "$err" || {
		rm -f "$err"
		echo "FAIL: $label failed with unexpected error"
		exit 1
	}

	rm -f "$err"
}

base="vless://$UUID@$HOST:$PORT"
common="security=reality&sni=$HOST&pbk=$PBK&sid=$SID"

parse_ok "query-after-port" "$base?type=tcp&$common#real-world-shape"
parse_ok "path-before-query" "$base/path?type=xhttp&$common#path-shape" "/path"
parse_ok "slash-before-query" "$base/?type=tcp&$common#slash-shape" "/"
parse_expected_error "unsupported-ws-path" "$base/ws?type=ws&$common#ws-shape" "unsupported VLESS transport: ws"

echo "VLESS parser smoke OK"
