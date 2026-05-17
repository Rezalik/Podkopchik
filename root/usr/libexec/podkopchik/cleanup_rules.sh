#!/bin/sh

set -u

TMP_DIR="/tmp/podkopchik"
ROUTE_STATE="$TMP_DIR/routing.env"
PODKOPCHIK_MARK="0x100000"
PODKOPCHIK_TABLE="10991"
PODKOPCHIK_PRIO="10991"

cleanup_policy_route() {
	[ -f "$ROUTE_STATE" ] || return 0

	if [ "$(cat "$ROUTE_STATE" 2>/dev/null || true)" = "podkopchik-routing-v1" ]; then
		ip rule del fwmark "$PODKOPCHIK_MARK" table "$PODKOPCHIK_TABLE" priority "$PODKOPCHIK_PRIO" >/dev/null 2>&1 || true
		ip route del local default dev lo table "$PODKOPCHIK_TABLE" >/dev/null 2>&1 || true
	fi

	rm -f "$ROUTE_STATE"
}

nft list table inet podkopchik >/dev/null 2>&1 && nft delete table inet podkopchik >/dev/null 2>&1 || true

cleanup_policy_route

exit 0
