#!/bin/sh
set -eu
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
export PODKOPCHIK_LIB="$tmp/lib"
export PODKOPCHIK_TMP_DIR="$tmp/runtime"
mkdir -p "$tmp/lib" "$tmp/runtime"
cp root/usr/libexec/podkopchik/xray_jobs.sh "$tmp/lib/"
cat > "$tmp/lib/xray_update.sh" <<'EOF'
#!/bin/sh
sleep 1
if [ "$1" = xray-check ]; then echo 'latest=26.10.21'; exit 0; fi
echo 'podkopchik Xray: synthetic startup failure' >&2
exit 1
EOF
script=root/usr/libexec/podkopchik/xray_jobs.sh
sh "$script" start xray-check official > "$tmp/result"
grep -q '^job_id=' "$tmp/result"
if sh "$script" start xray-check official > "$tmp/busy" 2>&1; then exit 1; fi
i=0
while [ -d "$tmp/runtime/xray-job.lock" ] && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done
grep -q 'job_status=done' "$tmp/runtime/xray-job.state"
sh "$script" start xray-install official > "$tmp/result"
i=0
while [ -d "$tmp/runtime/xray-job.lock" ] && [ "$i" -lt 10 ]; do sleep 1; i=$((i + 1)); done
grep -q 'job_status=failed' "$tmp/runtime/xray-job.state"
grep -q 'job_message=podkopchik Xray: synthetic startup failure' "$tmp/runtime/xray-job.state"
if sh "$script" start 'arbitrary-command' official > "$tmp/result" 2>&1; then exit 1; fi
echo 'Xray background job smoke OK'
