#!/bin/sh
# Independent procd timer for the synthetic DNS trial, not a router installer.
set -eu
umask 077
. /mnt/lab/native-vm-only.sh
ns="$1"; dir="$2"; service="$3"
case "$ns:$dir:$service" in pkc-router-*:*/native-dns-vm.*:pkc-vm-dns-*) ;; *) exit 2 ;; esac
case "$ns:$dir:$service" in *[!A-Za-z0-9_./:-]*) exit 2 ;; esac
cd "$dir"
while :; do
	case "$(ucode /mnt/lab/trial-state.uc poll "$dir")" in
		waiting) sleep 1 ;;
		confirmed|restored) exit 0 ;;
		rollback) break ;;
		*) exit 1 ;;
	esac
done
# Re-validate the old DNS path before releasing managed interception.
sha256sum -c backup.sha256 >/dev/null
PKC_NATIVE_LAB=query ip netns exec "$ns" /mnt/lab/native-dns.test -test.run='^TestGuestFixture$' -- \
	127.0.0.1:53 tcp probe.protected.example. A NOERROR 1 | grep -qx 'address=203.0.113.80'
ip netns exec "$ns" nft -f old-fw4.nft
ip netns exec "$ns" nft -f release
ubus call service delete "{\"name\":\"$service\"}" >/dev/null 2>&1 || true
ucode /mnt/lab/trial-state.uc restored "$dir"
: > rollback-done
