# Universal Routing Engine: AX6000 Preview Held

Device: Xiaomi Redmi AX6000 stock, OpenWrt 25.12.6, Linux 6.12.112.
Only `ssh openwrt` was used. No production code, profiles, routes, DNS, Wi-Fi,
WAN/LAN configuration or packages were replaced. The current Stage 4 r7
installation still uses OpenWrt Xray 26.3.27 for TPROXY, FakeDNS and AWG dispatch.
Its executable, active JSON and Podkopchik UCI matched the pre-test backup.

## Traffic Classification Before Transport

`universal_plan.uc` compiles pre-transport policies for LAN sources, DNS address
sets and IP/CIDR destinations. Local management and explicit endpoint exceptions
remain outside transport; a FakeDNS range cannot overlap an exception. AWG
transports use their existing per-profile marks and tables, plus an owned
egress-interface check and per-profile masquerade. Losing the marked policy
does not turn a protected path into WAN forwarding. There is no Xray process in
the native fixture. The selection transaction changes only owned chains, so
it does not destroy classified addresses during main/backup/all-down changes.

The planner is not connected to production Apply or health events. UCI parsing,
transactional DNS and runtime lifecycle ownership must be integrated before the
native backend can be enabled. Reuse the existing threshold, cooldown and
real-HTTPS selection rather than inferring availability from handshake alone.
A future Xray transport adapter needs separately owned inbounds and an outbound
escape policy. The existing VLESS backend is unchanged; unsupported native
adapters are rejected, not silently routed direct.

## DNS Readiness Blocker

The installed minimal dnsmasq has no nftset support. Replacing it globally would
change the system DNS/DHCP service. Even an isolated, official dnsmasq-full 2.93
build is not a safe classifier as-is: deleting the target nft set produced an
nftset error but a client still received the address. The
[dnsmasq 2.93 source](https://thekelleys.org.uk/dnsmasq/dnsmasq-2.93.tar.xz)
confirms that answer extraction does not fail when `add_to_nftset()` fails.

Do not forward a protected DNS response until its classifications and stale
address quarantine commit atomically. A verified DNS component must handle UDP
and TCP, the CNAME chain, A/AAAA and HTTPS/SVCB address hints, TTLs, and shared-CDN
conflicts. Multiple names/targets may share the same real IP: DNS-to-IP alone
cannot infer the requested hostname in that case. Block ambiguous protected
targets or use per-domain synthetic addresses with verified kernel translation.
Do not claim coverage for bypassed DNS (DoH/DoT), old client caches or QUIC without
tests. The prototype's populated DNS sets are fixtures, not a DNS implementation.

## FakeDNS Quarantine

On stock r7, an unknown fake-IP can pass TPROXY to Xray without a mapping and
take the ordinary freedom path. In the absence of local interception, a packet
can also be routed by the main table. A physical `wan` capture, not a
postrouting counter, reproduced both LAN (6 TCP and 1 UDP) and router-originated
(2 TCP and 2 UDP) fake-destination packets. The normal HTTPS control returned
200, with 14 captured packets; capture reported zero kernel drops.

The preview blocks unresolved fake destinations in Xray and adds an independent
kernel barrier. Destination blackholes at priority 10992 are below the TPROXY
local route at 10991 but above AWG and the system main table. A separate owned
nft table blocks fake destinations at output, forward and postrouting; fake
sources may only leave through the recorded LAN interfaces or loopback. Real
interface/route/exclusion overlaps are rejected, not globally blackholed.
Root-only `/etc/podkopchik-fakedns-guard.json` retains previously issued pools
independently of working-config archives. `podkopchikctl fakedns-guard-status`
reports the installed barrier on a preview system. The boot service and
sysupgrade ledger preservation are implemented but have not been live reboot
tested. Flow offload, firewall flush/reload and physical WAN must be checked
before promotion. FakeDNS remains off by default.

## Acceptance Evidence

| Test | Result | Scope |
| --- | --- | --- |
| Stock unknown FakeDNS egress | FAIL | Physical Xiaomi `wan`, LAN and router, TCP/UDP |
| Known FakeDNS TCP/UDP, ordinary direct | PASS | AX6000 isolated namespaces, both Xray builds |
| Unknown IPv4/IPv6, stopped Xray, all-down, stale address | PASS | AX6000 isolated namespaces |
| Failed nft batch and previous-state restore | PASS | Actual preview `routing_safety.sh` restore in a namespace |
| FakeDNS packet capture after protection | PASS | Isolated WAN peer: 0 fake, 26 direct; transport peer: 24 TCP, 1 UDP |
| Native prerouting classification and failover | PASS | Veth stand-ins: 13 main, 26 backup, 13 direct, 0 protected WAN packets |
| Native lost policy, all-down, removed DNS lease | PASS | Isolated kernel packet tests, not live tunnel failure |
| Stock dnsmasq-full atomic DNS-to-nft | FAIL | Client receives A record despite missing nft set |
| Production Stage 4 r7 baseline | PASS | SSH, configuration validation, LAN DNS UDP/TCP, YouTube HTTPS 200, three interface-bound AWG HTTPS 200 |
| Candidate core syntax and isolated TCP/UDP | PASS | ARM64 Xray 26.10.31 patched, SHA256 below |
| Production native routing/physical leak capture after fix | SKIPPED | No unaccepted preview was deployed |
| Real-app Instagram/Telegram, QUIC, live VLESS and mixed failover | SKIPPED | No native deployment, current VLESS profiles absent |
| Multi-hour production acceptance of patched core | SKIPPED | Earlier pilot was reverted; lab is not a soak test |

Local smoke suites: 51 PASS, 5 environment skips, 0 failures. The five skipped
generator/core checks passed with native ucode, jsonfilter and Xray on the
isolated AX6000. Shell/JS/JSON, gettext, i18n and LMO checks passed. The nine
UDP-cache cases passed ten runs with Go's race detector on the workstation.

At 20:24 UTC the unchanged main PID 11907 had 2620/16384 FD (1787 UDP,
675 TCP), RSS 69888 KiB and conntrack 6790. At 20:31 it had 2768 FD
(1818 UDP, 799 TCP), RSS 70044 KiB, conntrack 5992 and 281328 KiB available RAM.
UDP growth on the stock build is still a risk. This is not evidence that the
UDP patch fixes the previous production rise from 1823 to 10556 FD in 5h31m.
See [the previous short live pilot](XRAY-UDP-LIVE-PILOT-20261105.md).

Candidate binary SHA256:
`f8ba3bf3c5023817ad0cd413e1f44324d5a9c9d7aba806663e9ed63b418858c8`.
Build on the workstation using [the pinned recipe](../patches/xray/README.md).
`tools/fakedns-kernel-lab.sh` requires the private official-tool sandbox and
three network namespaces; it never needs production VLESS or AWG keys.

## Recovery And Deployment Gate

No rollback is required now. The original private archive is retained on the
router and in the Git-ignored workstation backup. Both copies have SHA256
`66d4b7ef4d91d08ed2cd904bb2758b30a577564c415d5d69cdea0a5e11a70102`.
Verify the hash before use. Do not extract the full private archive into `/`
as a routine rollback: use the checked Stage 4 watchdog/snapshot workflow to
restore only owned files and the matching last-working runtime, with SSH kept
open. Keep the original package Xray and separate FakeDNS ledger intact.

Do not install this branch until the DNS transaction, owned lifecycle,
VLESS adapter and rollback are verified. Then repeat physical WAN capture with
a positive direct control, actual AWG failover/fail-closed and the multi-hour
load comparison before accepting any production change.
