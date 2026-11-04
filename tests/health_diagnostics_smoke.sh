#!/bin/sh
set -eu
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
eval "$(sed -n '/^probe_failure_reason() {/,/^}/p' root/usr/libexec/podkopchik/health_check.sh)"
eval "$(sed -n '/^retain_probe_error() {/,/^}/p' root/usr/libexec/podkopchik/health_check.sh)"
: > "$tmp/xray"
probe_failure_reason 28 "$tmp/xray" | grep -q 'TCP stage unconfirmed'
echo 'failed to dial tcp 203.0.113.9:443: i/o timeout' > "$tmp/xray"
probe_failure_reason 28 "$tmp/xray" | grep -q tcp_connect_timeout
echo 'TLS handshake failed' > "$tmp/xray"
probe_failure_reason 28 "$tmp/xray" | grep -q tls_or_reality_error
awk 'BEGIN { for(i=0;i<2000;i++) print "uuid=SYNTHETIC_SECRET" }' > "$tmp/xray"
retain_probe_error "$tmp/xray" "$tmp/retained"
[ "$(wc -c < "$tmp/retained" | tr -d ' ')" -le 4096 ]
! grep -q SYNTHETIC_SECRET "$tmp/retained"
[ "$(ls -ld "$tmp/retained" | cut -c1-10)" = -rw------- ]
echo 'Health diagnostics smoke OK: separated causes, bounded redaction, no false TCP classification'
