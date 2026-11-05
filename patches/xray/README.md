# Bounded Transparent UDP Reply Cache

This is a downstream MPL-2.0 source change, not an official Xray release.
It replaces only dokodemo's transparent response PacketWriter. Full-cone
association/routing/outbound behavior remains unchanged. The old unbounded map
becomes a128-entry LRU with120s per-entry idle time and30s sweep. Evicted and
expired source sockets are recreated on demand, including the default source.
It is not a global FD/connection limit and does not prevent resource exhaustion
from genuinely excessive active sessions.

`udp_reply_cache.go` owns the lifecycle. Writes do not hold the cache mutex
while in kernel I/O, so Close can close the underlying socket and unblock a
stalled writer. Active writes are not evicted. Timer/write/close synchronization
prevents resurrection after close and double-close of cache entries.

Pinned build inputs:

| Core | Source archive SHA256 | Host Go |
| --- | --- | --- |
| v26.3.27 | `992a4997e6bb846d11469435d687f99ef812fcde1e0a009bb8e95189ea20331d` | 1.26.10 |
| v26.10.31 | `be44f95d497ad4ba6e9d1dcfbbd71e8e51f812aff077d4c15c9947eff5e3046a` | 1.27.3 |

Run `GO=/path/to/pinned/go sh tools/build-xray-udp-cache.sh v26.10.31` on a
workstation, never on OpenWrt. It builds both baseline/patched Linux ARM64 test
programs and the complete core, runs host race tests, verifies Go modules, and
emits `.build/xray-udp-v26.10.31/release/SOURCE.json` plus `SHA256SUMS` and all
modified source files. The `podkopchik-udp-cache-v1` build marker is diagnostic,
not a signature. No keys/configs/geodata are part of these build outputs.

Linux tests require explicit `PODKOPCHIK_LOOPBACK_PROBE=1` and root. Keep them
in a private `/tmp/podkopchik-udp-lab-*` on the approved Xiaomi only. Use fixed
Go test timeouts and `ulimit -n 1024`; do not run broad unfiltered tests on a
working router. Tests use127/8 reply addresses and do not create nft state or
change routes. The isolated feature test runs a loopback-only child core from
the lab, with Pdeathsig/SIGKILL and CommandContext; it never selects that core
for Podkopchik. Its private config remains on the router and is deleted.

Before installing any candidate, read
[the evidence, incomplete gates and rollback procedure](../../docs/XRAY-UDP-CACHE-FIX-20261105.md).
MPL source availability must accompany any redistributed core binary. Port the
patch, rerun races/kernel/LAN tests and generate new hashes for future core
releases. Never assume an upstream version or matching banner proves this fix.
