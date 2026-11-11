#!/bin/sh
set -eu
if ! command -v ucode >/dev/null 2>&1; then echo 'SKIP: real ucode required for platform assessment'; exit 0; fi
base=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$base"
lib="$base/root/usr/libexec/podkopchik"
work=$(mktemp -d /tmp/pkc-platform-test.XXXXXX)
trap 'rm -rf "$work"' EXIT HUP INT TERM
check() { ucode -L "${UCODE_MODULE_DIR:-/usr/lib/ucode}" -L "$lib" "$lib/native_platform_check.uc" "$@"; }
ucode -L "${UCODE_MODULE_DIR:-/usr/lib/ucode}" -L "$lib" tests/native_platform_smoke.uc
check --fixture tests/fixtures/native-platform-flint2.json > "$work/pass.json"
ucode -e 'import {readfile} from "fs";let r=json(readfile(ARGV[0]));if(r.source!="fixture"||r.status!="requirements_met"||r.installation_authorized||r.current_candidate.board_guard!="mismatch")die("fixture CLI contract failed");' "$work/pass.json"
ucode -e 'import {readfile,writefile} from "fs";let v=json(readfile(ARGV[0]));v.resources.mem_available_kib=1;writefile(ARGV[1],sprintf("%J",v));writefile(ARGV[2],"{}");' tests/fixtures/native-platform-flint2.json "$work/blocked.json" "$work/incomplete.json"
if check --fixture "$work/blocked.json" > "$work/result.json"; then exit 1; else [ "$?" = 2 ]; fi
if check --fixture "$work/incomplete.json" > "$work/result.json"; then exit 1; else [ "$?" = 3 ]; fi
if check --install >/dev/null 2>&1; then echo 'FAIL: mutating CLI argument accepted'; exit 1; fi
if check --fixture tests/fixtures/native-platform-flint2.json --awg >/dev/null 2>&1; then exit 1; fi
if check --fixture tests/fixtures/native-platform-flint2.json --helper /usr/libexec/podkopchik/podkopchik-native-dns >/dev/null 2>&1; then exit 1; fi
if check --helper /path/that/does/not/exist > "$work/result.json"; then exit 1; else code=$?; [ "$code" = 2 ] || [ "$code" = 3 ]; fi
ucode -e 'import {readfile} from "fs";let r=json(readfile(ARGV[0]));if(r.source!="live_read_only"||index(r.unknown_checks,"bounded_executor")<0||r.installation_authorized)die("unavailable executor incorrectly admitted");' "$work/result.json"
echo 'PASS: actual CLI success/refusal/incomplete exits, fixture isolation, unavailable helper and rejected install argument'
