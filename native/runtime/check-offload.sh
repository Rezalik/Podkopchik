#!/bin/sh
# Read-only admission check. Never toggle fw4 settings or flush conntrack.
set -eu
fail() { echo "Native routing preflight: $*" >&2; exit 1; }
config=$(uci -q show firewall) || fail 'cannot read firewall defaults'
if printf '%s\n' "$config" | grep -Eq '\.flow_offloading(_hw)?=' &&
	printf '%s\n' "$config" | grep -E '\.flow_offloading(_hw)?=' | grep -Ev "='(0|false|no|off)'$" | grep -q .; then
	fail 'flow offloading must be disabled and existing offloaded flows drained'
fi
tables=$(nft -j list flowtables) || fail 'cannot inspect live flowtables'
if ! printf '%s\n' "$tables" | ucode -e '
import { stdin } from "fs";
let v=json(stdin.read("all"));
if(type(v?.nftables)!="array") exit(1);
for(let x in v.nftables) if(x.flowtable) exit(1);
'; then fail 'live flowtable or invalid kernel response'; fi
