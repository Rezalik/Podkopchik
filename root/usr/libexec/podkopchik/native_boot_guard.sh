#!/bin/sh
# No helper/metadata dependency: a selected but missing Native state must not
# start legacy routing or expose client DNS to the stock upstream.
set -eu
if [ -n "${PKC_NATIVE_VM_NS:-}" ] && [ "${PKC_NATIVE_BOOT_VM_INSIDE:-0}" != 1 ]; then
	[ "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)" = QEMU ] || [ "$(tr -d '\000' < /proc/device-tree/model 2>/dev/null)" = linux,dummy-virt ]
	case "$PKC_NATIVE_VM_NS" in pkc-router-[0-9]*|pkc-permanent-router) ;; *) exit 2 ;; esac
	case "$PKC_NATIVE_VM_NS" in *[!a-z0-9-]*) exit 2 ;; esac
	exec env PKC_NATIVE_BOOT_VM_INSIDE=1 /sbin/ip netns exec "$PKC_NATIVE_VM_NS" sh "$0" "$@"
fi
owner=podkopchik-native-runtime-v1
table=podkopchik_native_uninitialized
uci_cmd() {
	if [ -n "${PODKOPCHIK_UCI_CONFIG_DIR:-}" ]; then uci -c "$PODKOPCHIK_UCI_CONFIG_DIR" "$@"; else uci "$@"; fi
}
listed=$(nft -j list tables)
exists=0
if printf '%s' "$listed" | jsonfilter -q -e '@.nftables[*].table.name' | grep -qx "$table"; then
	[ "$(nft -j list table inet "$table" | jsonfilter -q -e '@.nftables[*].table.comment')" = "$owner" ] || exit 1
	exists=1
fi
case "${1:-}" in
 release)
	[ "$(uci_cmd -q get podkopchik.main.routing_enabled)" = 0 ] || exit 1
	[ "$exists" = 0 ] || nft delete table inet "$table"
	;;
 hold)
	lan=$(uci_cmd -q get podkopchik.main.lan_ifname || echo br-lan)
	printf '%s' "$lan" | grep -Eq '^[A-Za-z0-9_.-]{1,15}$'
	{
		[ "$exists" = 0 ] || printf 'delete table inet %s\n' "$table"
		printf 'add table inet %s { comment "%s"; }\n' "$table" "$owner"
		printf 'add chain inet %s pre { type filter hook prerouting priority -327; policy accept; }\n' "$table"
		printf 'add rule inet %s pre iifname "%s" meta l4proto { tcp, udp } th dport 53 counter drop\n' "$table" "$lan"
		printf 'add rule inet %s pre iifname "%s" fib daddr type { local, broadcast, multicast } return\n' "$table" "$lan"
		printf 'add rule inet %s pre iifname "%s" counter drop\n' "$table" "$lan"
	} | nft -f -
	;;
 *) exit 2 ;;
esac
