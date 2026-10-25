#!/bin/sh
set -eu
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export TEST_ROOT="$tmp"
export PODKOPCHIK_LIB="$PWD/root/usr/libexec/podkopchik"
export PODKOPCHIK_TMP_DIR="$tmp/runtime"
export PODKOPCHIK_PROC_DIR="$tmp/proc"
export PODKOPCHIK_CORE_DIR="$tmp/core"
mkdir -p "$tmp/bin" "$tmp/runtime" "$tmp/proc"
export PATH="$tmp/bin:$PATH"
# The URI is deliberately synthetic. Never print it, even in failure output.
export PODKOPCHIK_PROBE_URI='vless://11111111-2222-3333-4444-555555555555@example.invalid:443?type=tcp&security=reality&pbk=AAAAAAAA#test'
cat > "$tmp/bin/xray" <<'EOF'
#!/bin/sh
if [ "$2" = '-test' ]; then
 [ "$(ls -ld "$4" | cut -c1-10)" = '-rw-------' ] || exit 1
 [ "$(ls -ld "${4%/*}" | cut -c1-10)" = 'drwx------' ] || exit 1
 exit 0
fi
echo "$*" >> "$TEST_ROOT/arguments"
echo "$$" > "$TEST_ROOT/listener-pid"
trap 'echo "$$" >> "$TEST_ROOT/stopped"; exit 0' TERM INT
if [ "${EXIT_PROBE:-0}" = 1 ]; then exit 1; fi
while :; do sleep 1; done
EOF
cat > "$tmp/bin/ucode" <<'EOF'
#!/bin/sh
case "$*" in
 *probe_result.uc*)
  if [ "${BAD_IP:-0}" = 1 ]; then exit 1; fi
  printf '198.51.100.1'
  ;;
 *)
  if [ "${BAD_CONFIG:-0}" = 1 ]; then echo 'secret parse error must not escape' >&2; exit 1; fi
  echo '{"outbounds":[{"tag":"synthetic"}]}'
  ;;
esac
EOF
cat > "$tmp/bin/netstat" <<'EOF'
#!/bin/sh
if [ "${BUSY_PORT:-0}" = 1 ]; then echo 'tcp 0 0 127.0.0.1:20999 0.0.0.0:* LISTEN 999/other'; exit 0; fi
if [ "$*" = '-lntp' ]; then
 echo "tcp 0 0 127.0.0.1:20999 0.0.0.0:* LISTEN $(cat "$TEST_ROOT/listener-pid")/xray"
fi
EOF
cat > "$tmp/bin/curl" <<'EOF'
#!/bin/sh
if [ "${PROBE_TIMEOUT:-0}" = 1 ]; then exit 28; fi
previous=''
for arg in "$@"; do
 if [ "$previous" = '-o' ]; then echo 198.51.100.1 > "$arg"; fi
 previous="$arg"
done
printf '0.084'
EOF
chmod +x "$tmp/bin/"*
script=root/usr/libexec/podkopchik/connection_check.sh
sh "$script" uri > "$tmp/result"
grep -q '"status":"up"' "$tmp/result"
grep -q '"latency_ms":84' "$tmp/result"
grep -q '"external_ip":"198.51.100.1"' "$tmp/result"
[ ! -d "$tmp/runtime/connection-check.lock" ]
[ "$(wc -l < "$tmp/stopped" | tr -d ' ')" = 1 ]
! grep -q 'vless://' "$tmp/arguments"
! grep -q 'vless://' "$tmp/result"
PROBE_TIMEOUT=1 sh "$script" uri > "$tmp/result"
grep -q '"reason":"timeout"' "$tmp/result"
grep -q '"status":"down"' "$tmp/result"
[ ! -d "$tmp/runtime/connection-check.lock" ]
BAD_CONFIG=1 sh "$script" uri > "$tmp/result"
grep -q '"reason":"invalid_configuration"' "$tmp/result"
! grep -q secret "$tmp/result"
BAD_IP=1 sh "$script" uri > "$tmp/result"
grep -q '"reason":"external_ip_error"' "$tmp/result"
BUSY_PORT=1 sh "$script" uri > "$tmp/result"
grep -q '"reason":"port_in_use"' "$tmp/result"
EXIT_PROBE=1 sh "$script" uri > "$tmp/result"
grep -q '"reason":"probe_start_failed"' "$tmp/result"
sh "$script" uri > "$tmp/result"
grep -q '"status":"up"' "$tmp/result"
[ ! -d "$tmp/runtime/connection-check.lock" ]
[ "$(wc -l < "$tmp/stopped" | tr -d ' ')" = 4 ]
echo 'Connection check smoke OK (mocked HTTPS egress, secret-free results)'
