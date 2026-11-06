# AX6000 FakeDNS egress and UDP qualification

The previous physical retry proved native AWG HTTPS without Xray. The current
work did not install the guard or run a new pilot on Xiaomi. It did not connect
to the second router.

## Read-only finding

With no virtual client or classifier running, two DHCP clients on `br-lan`
(addresses ending in `.244` and `.248`) originated IPv4 ICMP Echo Requests to
`198.19.28.7`. During a 38-second observation the original-direction conntrack
counters rose for both entries; the reply-direction destination was the WAN
IPv4 address. A source/interface-specific route lookup selected `wan`; firewall4
allows LAN-to-WAN and its IPv4 WAN chain applies masquerade. The original
source, ICMP type, and NAT tuple distinguish forwarded traffic from locally
generated Xray/health traffic. Stock transparent interception matches TCP/UDP,
not ICMP. The installed router had neither the guard service nor its ledger.

The prior physical capture independently established that two ICMP Echo
Requests reached the wire. This observation used live conntrack, not a fresh
physical pcap (no capture binary was present and none was copied). No exact
packet-level correlation to the previous capture is claimed. Client software
and the origin/age of its synthetic address (DNS cache or another client-side
source) are not determined. DNS/FakeDNS can supply the address but is not the
source of these ICMP packets.

If per-packet confirmation is needed, a separately authorized diagnostic may
use its own temporary nft table, a `prerouting` filter at `-301` matching only
`iifname "br-lan" ip daddr 198.18.0.0/15 icmp type echo-request` and an
`output` filter at `-301` with the same destination and type. Both set only
`meta nftrace set 1`; use a bounded `nft monitor trace` and delete the exact
diagnostic table. Correlate timestamps, IPs, ICMP IDs and conntrack tuples with
filtered captures on `br-lan` and the actual WAN. No trace rule was installed.

## Persistent quarantine

The separate `inet podkopchik_fake_guard` table never changes firewall4
policy, the default route, the legacy Xray interception, or an AWG profile.
The root-only guard ledger records issued legacy and explicitly registered
native pools. Normal Apply never reserves an arbitrary RFC1918 range.

- RPDB blackhole at priority `10992`, after legacy TPROXY local delivery
  `10991`. A valid native destination is DNATed in prerouting before lookup,
  so its real destination does not match the synthetic blackhole.
- `output -90`: after standard OUTPUT DNAT, before SNAT. `forward -200`:
  after prerouting DNAT, before SNAT. `postrouting 300`: after srcnat and
  reverse DNAT. Raw fake destinations cannot leave; fake source addresses
  are only permitted on loopback or recorded LANs for legitimate replies.
- Conntrack's original tuple prevents DNAT from hiding a legacy destination.
  An original native flow can continue only after DNAT and through an actual
  Linux `amneziawg` output. This is an additional fence, not permission to
  bypass the native planner's exact mark/interface/lease checks. VLESS
  delivery is local INPUT; its subsequent real Xray connection is a
  separate flow.
- The scoped pilot also checks reverse traffic against its live lease,
  classifier heartbeat, DNAT status, mark and tunnel. A late reply must not
  reach the client after the lease is revoked.
- Keep the ledger and the current guard across firewall4 reload, Apply,
  Podkopchik working-config restore, and pilot rollback. The existing
  `podkopchik-fakedns` service reinstates the ledger at startup. Do not
  downgrade/remove this guard as part of routing rollback. Explicit
  uninstall/release is different and removes the quarantine.

A legacy cached address that Xray has independently reissued for another name
is not distinguishable from the new binding by an IP packet alone. The kernel
guard still prevents egress to that raw address. The scoped native allocator
does not reuse its previous reserved windows.

Reference: [nftables manual: hooks, NAT and conntrack](https://netfilter.org/projects/nftables/manpage.html).
Flow offloading is unsupported for the native pilot. Registration rejects
configured software/hardware offload and live nft flowtables; do not enable
offload later without requalification. Confirm no PPE fast path. The guard
does not classify client-side DoH/DoT or traffic already using a real IP.

## Next physical pilot (not authorized here)

1. Repeat topology, inventory, backup and offload checks. Confirm the
   chosen WAN and the existing AWG link kind. Review AWG AllowedIPs, bypass
   exclusions, endpoints and route selectors before registering a private
   range. Verify a deterministic native DNS/HTTPS plan and bundle hashes.
2. Obtain separate authorization to install/sync the persistent guard and
   explicitly register the approved native range with
   `sh /usr/libexec/podkopchik/fakedns_guard.sh register-native 172.31.253.0/24`.
   This is system-wide and is not part of the virtual pilot transaction.
   Verify normal DNS, SSH, LuCI, Xray and all three AWG before proceeding.
3. Record a never-used allocation window for the pilot before arming it.
   The previous run issued at least `.1` and `.2`; do not use them. Use the
   renderer's `window` only after verifying the earlier record, and retire
   the entire reserved window after a run. The daemon fails closed if the
   window is exhausted. A missing or ambiguous historical allocation is
   grounds to stop, not to reset an old ledger.
4. On a controlled, firewall-restricted host, run `pilot-probe udp-serve
   SERVER_IP:PORT 300`. Restrict access to the tunnel exit; the listener is
   temporary and replies only to valid, equal-sized challenges. Confirm
   replies independently through the selected AWG using
   `pilot-probe udp-echo SERVER_IP:PORT AWG_INTERFACE` and a matching AWG
   capture. No package installation on Xiaomi is part of this test.
5. In the virtual client repeat four unique UDP challenges on the same
   socket via the synthetic address for `echo.pkc.invalid`. Check both
   directions in captures and the original/translated conntrack tuple.
   Check natural expiry of that exact tuple after cleanup without changing
   the household conntrack timers to fit the pilot deadline.
   The separate `quic` probe makes a TLS-verified HTTP/3 request, without
   falling back to TCP. Confirm zero synthetic and protected clear packets
   on WAN; AWG outer packets and the direct control must be visible.
6. Abort on a failed critical check. Keep the independent 125-second
   watchdog. Verify cleanup of namespace, rules, processes and routes, and
   compare household state with the post-guard, pre-pilot baseline. Keep
   persistent quarantine; do not rerun on a failed pilot.

## Reproduction

Build with pinned Go 1.26.10 on the workstation. Use
`tools/prepare-native-dns-vm.sh` and the NIC-free OpenWrt VM launcher
`tools/run-native-dns-vm.sh`; in the guest mount the read-only lab share
and run `sh /mnt/lab/setup-native-dns-guest.sh`. The focused FakeDNS test
first captures unguarded forwarded and local ICMP, then verifies both pools,
unchanged direct forwarding, firewall4 reload, retained guard ledger, and
DNAT fallback with the RPDB safety layer removed in the VM.

Use `tools/build-native-ax6000-review.sh` for the ARM64 review archive and
separate `/tmp` probe binary. Neither is an installer. Verify each SHA256
sidecar and compare two independent builds. Account for archive plus
unpacked bytes, bounded captures, guard ledger, watchdog and a reserve;
recheck live space before any physical deployment. No flash space was
consumed for this phase.

## Acceptance

| Scenario | Status |
| --- | --- |
| Old-pool ICMP on Xiaomi without a pilot | PASS: live forwarded ICMP and WAN SNAT tuples identified; no new physical pcap. |
| Old/new pool and direct control, isolated OpenWrt | PASS: two old-pool and one new-pool packets before protection; zero after. The ordinary direct control still arrived. |
| Real legacy Xray / FakeDNS | PASS: known address resolved and reached the fixture via TPROXY with the permanent guard active. |
| Firewall4 reload, rejected nft transaction, config rollback | PASS: both registered pools remained protected, including stale DNAT to a real WAN destination without the RPDB rules. |
| Scoped DNS UDP/TCP, native HTTPS and HTTP/3 | PASS: real TLS and HTTP/3 over the isolated transport stand-in. The production guard rejects the veth as AWG; a VM-only exact-device exception then exercises the rest of the same guard. |
| Controlled UDP and conntrack | PASS: direct echo control, four verified replies on one socket, tuple expiry, a fresh tuple, and a captured delayed reply blocked after revocation. |
| VLESS, failover, fail-closed, reapply, classifier restart | PASS: isolated real Xray with a test VLESS peer; dual-stack native stand-ins; AWG-to-VLESS and back, with UDP denied on TCP-only fallback; loss of both adapters and SIGKILL recovery. |
| Autonomous rollback | PASS: procd watchdog restored stock DNS; rollback WAN capture had zero synthetic packets and eight direct controls. |
| Real AWG bidirectional UDP and HTTP/3, fixed guard on physical WAN | SKIPPED: no new physical pilot or global guard activation was authorized. |

The scoped virtual WAN capture saw zero synthetic, protected clear, or DNS
bypass packets, with five direct and 28 tunnel-control packets. The broader
VM run captured zero protected and zero plaintext DNS packets, with 64
direct controls. Scoped classifier RSS was 4,092 KiB and nine FDs. Xiaomi
read-only headroom was 21,476 KiB overlay, 247,280 KiB in /tmp and 298,448
KiB MemAvailable. The review payload plus 2 MiB state, 1 MiB recovery and
4 MiB reserve is about 12.8 MiB of flash. Allow 24 MiB of temporary space
for the compressed/unpacked archive, separate probe and bounded captures;
verify fresh RAM/flash/temporary space before a physical trial. No new
physical runtime resource measurements were taken.
