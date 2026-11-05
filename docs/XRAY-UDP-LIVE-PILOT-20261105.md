# AX6000 UDP Cache Pilot: Rolled Back, Release Held

Date: 2026-11-05, Europe/Moscow. Device: Xiaomi Redmi AX6000 stock,
OpenWrt 25.12.6 / kernel 6.12.112. Only `ssh openwrt` was accessed.

**Result: HELD.** A short controlled production pilot was performed and rolled
back when the WAN-boundary check failed. This is not a completed multi-hour
stability pass. The packet-cache repair remains a candidate, not the active core.
No commit, push, GitHub release, firmware/package installation or reboot occurred.

## Reviewed Build

| Item | Identity |
| --- | --- |
| Repository checkpoint before this task | `42cfdb4` |
| Original package core | Xray 26.3.27, OpenWrt build, Go 1.26.10 |
| Original executable SHA256 | `8f6e7cad58f4cc533471a88e8780c9cab1e46ea9232dbcc3bb234cadce25556e` |
| Pilot core | Xray 26.10.31, `podkopchik-udp-cache-v1`, Go 1.27.3, Linux ARM64 |
| Pilot executable SHA256 | `f8ba3bf3c5023817ad0cd413e1f44324d5a9c9d7aba806663e9ed63b418858c8` |

The preferred 26.10.31 build had already passed actual-device config validation
and isolated AWG/FakeDNS tests. Rebuilding with additional test cases retained
the same executable hash. Source archive/toolchain/module verification and the
MPL overlay remain in [the source-build instructions](../patches/xray/README.md).
These are locally built executables, not signed APKs or official OpenWrt builds.

The second review found no demonstrated race/use-after-close in the cache.
Nine cases passed ten race-enabled runs. New cases cover a completely busy
cache, retry after a failed socket factory, and retention of the recently used
peer. Close can interrupt blocked writes; entries cannot resurrect after Close.
In-flight writes are not evicted. The 128-entry bound can evict a recently active
*reply-source socket* under extreme fan-out, but recreates it when needed; it
does not close the outbound receive socket/full-cone association. This is not
a guarantee about every full-cone application or a global FD/flood limit.

## Controlled Switch And Recovery

Before the switch: PID 3371, 13274 FD / 16384, 12405 UDP, 586 TCP, 79640 KiB RSS.
Only about 31 MiB of overlay space was available. The normal manager's duplicate
binary recovery staging could not safely fit its conservative free-space gates.
No gate was disabled and no package file was overwritten.

The operator pilot instead retained the package executable in place, copied
it into private RAM and additionally saved that public executable on the Mac.
Private configuration/AWG/network/SSH backups and routing snapshots stayed
on the router under root700/600 permissions. No private configuration was
transferred to the workstation or included in publication artifacts.

The candidate was staged on UBIFS with an 8 MiB incompressible reserve. Only after
staging/hash validation and checking at least 8 MiB free was the selector changed.
About 14 MiB remained after the switch. Only the minimal `xray.sh` selector helper
was updated; existing procd limits remained 16384. The health daemon stayed PID 3370.
The Xray instance was replaced through procd without regenerating JSON, applying
nft rules, changing roles or restarting AWG. Main PID became 5506.

An independent procd watchdog had first restored a separate fixture without
SSH supervision. During the pilot it guarded startup, process identity, FD,
RAM and DNS, with a 6h observation window and an 8h unaccepted-trial deadline.
The actual early rollback was **operator-triggered**, not a claimed automatic
production failure-injection pass. It used the same recovery function and
restored package selection, the original helper and the original core.

Snapshots, restore scripts and the private backup remain at
`/root/podkopchik-xray-pilot-20261105-1908/`. They are not public release files.
The RAM staging directory, independent service and both owned test nft tables
were removed. The package core and helper hashes match their original values.

## Resource Measurements

All times below are MSK, same day. Procfs samples are non-atomic and inode-owned,
not namespace-wide socket counts. The simultaneous startup samples differed
as connections arrived; only one is shown here.

| Time | Main PID | FD | UDP | TCP | RSS KiB | Conntrack |
| --- | --- | --- | --- | --- | --- | --- |
| 22:08:07, original | 3371 | 13274 | 12405 | 586 | 79640 | 4459 |
| 22:08:57, patched startup | 5506 | 58 | 2 | 35 | 30828 | 4802 |
| 22:13:28, patched | 5506 | 1051 | 230 | 688 | 66280 | 6058 |
| 22:16:31, patched before rollback | 5506 | 1098 | 199 | 727 | 67532 | 5147 |
| 22:22:14, restored original | 11907 | 1158 | 403 | 643 | 66400 | 4761 |

For the 183s between the last two patched samples, 205 of 230 prior UDP socket
inodes disappeared; 25 survived and 174 current UDP sockets were new. UDP counts
fell230->199 while ordinary traffic continued. This supports active retirement,
unlike merely observing a lower FD count after restart. The sample had3 racing
FDs at the end; TCP/UDP classifications and inode churn are not atomic traces.

The patched process averaged approximately 0.971% of four-core capacity
(3.883% of one core) across the short measured window. Aggregate existing AWG
counters increased by about 202.12 MiB received and 15.30 MiB sent. This is a
workload indicator, not a throughput benchmark or identification of client apps.
RSS startup growth to 65.95 MiB is not sufficient to characterize long-term memory.

The historical 1823->10556 FD and 1116->9796 UDP over 5h31m correspond to roughly
1583 FD/h and 1573 UDP/h growth. They belong to an earlier PID/boot/load. A 7m34s
patched window cannot establish equivalent-load long-term stability or be
linearly extrapolated into a multi-hour PASS. The six-hour test was stopped.

## WAN Boundary Finding And Safe Stock Control

The temporary observer contained only counters: no packet marks, route changes
or accept/drop verdicts. Positive traffic reached the main AWG: one snapshot
counted 39310 TCP and 443 UDP packets. All marked-AWG-to-WAN counters were zero;
all three existing AWG tables retained terminal unreachable defaults.

However, late postrouting counters in the WAN direction also counted 11 TCP
packets / 660 bytes and 1 UDP packet / 76 bytes to 198.18.0.0/15, plus 5 ICMP packets.
Earlier forward-hook counts alone would not prove WAN traversal because fw4
could still drop later. The late postrouting observation failed this pilot's
conservative boundary gate. It is not a packet capture of delivery to a real
site or evidence of plaintext user credentials. Marked AWG transport and this
unmarked fake-destination fallback must not be conflated.

Rollback completed at 22:16:33 MSK. A subsequent **original-core** control used
only synthetic data to 198.19.255.254 TCP 9. A separately owned test output rule
counted and dropped this exact synthetic destination before WAN. The stock core
made 16 contained outbound attempts in that first control. Because that rule
did not distinguish egress interfaces, it alone did not prove direct WAN routing.
A second control explicitly matched the WAN interface and mark0: it counted
21 dropped SYN attempts / 1260 bytes on that path, and zero on the alternative
route catch rule. Both rules contained only the exact synthetic destination;
no synthetic test payload was allowed onto WAN. Both test tables were removed.

This reproduces the unknown/unmapped-fake-address direct-attempt behavior on
the original core, not just the patched 26.10.31 build. Restarting FakeDNS loses
the in-memory reverse map while clients may retain answers; that is a plausible
trigger for natural stale flows. The synthetic unmapped control supports the
fallback mechanism but does not attribute each observed production packet.
No DNS/routing guard was silently added to fix this separate behavior.

Before another production acceptance, separately review protection against
unmapped fake addresses reaching a direct outbound, including cache loss and
non-sniffable traffic, and repeat the scoped WAN/failure tests. This must preserve
valid recovered-domain direct/proxy routing. It is a separate routing change,
not an extra change to conceal inside the UDP lifecycle patch.

## PASS / FAIL / SKIPPED

| Gate | Result | Scope |
| --- | --- | --- |
| Cache concurrency/close/recreation review and race tests | PASS | Nine cases, ten runs; no core-source change this task |
| Candidate active JSON validation | PASS | Before promotion; real26.10.31 executable |
| Independent watchdog fixture recovery | PASS | No production outage injected |
| Controlled main-core promotion and protected rollback | PASS | Original binary/helper/config/routing preserved |
| LAN DNS UDP/TCP -> FakeDNS | PASS | Real Mac LAN queries returned198.19 addresses |
| YouTube HTTPS over LAN/TCP TPROXY | PASS | HTTP200; fixed-port TCP probe inode-owned by main Xray |
| All three current AWG connections | PASS | Each interface-bound pinned HTTPS check returned200 |
| Existing AWG terminal policies and marked output | PASS, scoped | Three terminal routes; marked WAN counters zero |
| Overall fake-address WAN boundary | FAIL | Late postrouting TCP/UDP counters nonzero; stock also reproduces direct attempts |
| Early UDP retirement under live traffic | PASS, short-window | 205/230 prior inodes retired in183s |
| Six-hour comparable-load FD/RSS stability | SKIPPED | Pilot stopped after7m34s at failed boundary gate |
| Authenticated Instagram/YouTube/Telegram, real video | SKIPPED | User observation not yet correlated to this short window |
| QUIC/HTTP3 | SKIPPED | Installed Mac/router curl lack HTTP3; no client installed |
| Destructive AWG down/return and exhaustive WAN/DNS capture | SKIPPED | No profiles/interfaces/default routes changed |
| Native signed SDK APK | SKIPPED | Local source/binary artifacts only |

## Current State And Next Checkpoint

Original Xray 26.3.27 is active again. All three AWG health records were UP after
restoration. Active JSON, UCI, network/wireless/firewall/dropbear configuration,
application nft table, policy rules and default routes match their snapshots.
No new automatic restart policy or FD-limit increase was introduced.
**The original UDP retention risk remains on the restored stock core.**

`tools/xray-live-pilot.uc` and `tools/xray-live-measure.uc` are one-off operator
tools, not installer payload or LuCI features. After the observed failure the
repository tool also includes late WAN counters and an automatic abort gate;
that subsequent extension has static/syntax coverage only, not a new live pass.
The synthetic containment test was not installed as a general firewall policy.

Final local regression checks: 17 JavaScript suites PASS, 33 shell suites PASS,
four generator wrapper suites SKIPPED for missing native UCI/jsonfilter on the
workstation, and zero failed suites. The separate native file-backed generator,
i18n coverage, LMO decoder, shell/JS/JSON checks, operator-tool ucode compilation,
`msgfmt -c` and `git diff --check` passed. The nine Go race cases passed ten
runs with the pinned host toolchain. These local results do not close the failed
live boundary or skipped long-term/app/failure-injection gates.

Do not publish this as a successful stable release. The review bundle contains
the reproducible core, source overlay, test/tool sources, checksums and this
HELD report; it contains no router backup. A new acceptance run is required
after separately resolving the fake-address boundary precondition.
