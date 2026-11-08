# Native RC: 48-Hour Operational Observation

## Window And Status

Xiaomi Redmi AX6000 stock layout, OpenWrt 25.12.6 / kernel 6.12.112.
Observation started **2026-11-07 20:23:30 Europe/Moscow** and has a fixed
deadline **2026-11-09 20:23:30 Europe/Moscow**. The 24-hour checkpoint is
2026-11-08 20:23:30. The observation is **IN PROGRESS**, not a stability PASS.

At the start, Native was confirmed, Strict/repair, AWG-only without a running
Xray, with the independent emergency capsule accepted and running. No Apply,
update-install, reboot, package installation, firewall mutation or restart of
any working application/network service was performed for this observation.
All five UCI files (Podkopchik, network, wireless, DHCP and firewall) retain
their pre-observation hashes. DNS, network, SSH, LuCI, Wi-Fi, Native DNS/watch/
health and emergency service PIDs were compared and are unchanged.

Subsequent operator-approved maintenance is separate from this read-only job:
on 2026-11-08 routing became selective, LuCI alignment was deployed, and the
operator then [retired the emergency capsule and removed router backups](AX6000-CLEANUP-20261108.md).
The current confirmed generation uses transactional Apply without a separate
emergency service. The original observation window continues across the
documented PID/policy segments. Its sampler requires the capsule only when
the active generation uses repair mode; intentional absence in transactional
mode is not an emergency warning or a collection failure.

## Collection

An independent, temporary procd job `podkopchik-native-observe` runs from
`/tmp/pkc-native-observe.KkBDGk`. It has no boot link, no respawn loop and no
repair/rollback authority. It uses a fixed monotonic deadline, not a deadline
extended on each invocation. No production files or user settings are changed.

- Once per minute: system CPU, DNS process CPU, available RAM, RSS, FD counts,
  process-owned TCP/UDP/UNIX socket counts, TCP states and conntrack occupancy.
- Socket inodes are matched to the process descriptors. Namespace-wide
  `/proc/PID/net` entries are not counted as if all belonged to Native.
- AWG health age, probe state, failure counts, latency, handshake age, link
  index and byte-counter deltas. Counter resets are distinguished from traffic.
- Active transport changes, health-switch timestamps and PID changes are
  recorded without triggering tests or changing roles.
- Every 15 minutes: local Native DNS UDP/TCP readiness, real protected DoT,
  HTTPS bound to the active AWG, a root WAN HTTPS control, and owned nft table
  presence. Network commands are individually timed out; a full collection
  cycle is bounded by the existing helper's 30-second command deadline.
- FD >=85% of limit, RAM below 96 MiB, conntrack >=80%, stale health, DOWN
  transports, missing emergency readiness and failed probes create diagnostic
  flags only. No automatic Apply, service restart or recovery request exists.

The log is two rotating files of at most **512 KiB each**, plus a bounded
summary with at most 32 change events. Aggregated ranges and failure totals
retain the whole window even after rotation. Source/config/summary are small;
the total observation data stays around 1.2 MiB, not an unbounded 48-hour log.
Only tmpfs is written. No tcpdump, logread, client addresses, domain history,
private keys, endpoint credentials or imported configurations are recorded.
Connection labels are numbers, not uploaded names or URI contents.

CPU is derived from successive kernel counters, with separate system and
single-core DNS percentages. A process/PID change invalidates its CPU delta.
Some startup CPU samples were integer-quantized; subsequent samples preserve
fractions, and the report explicitly notes this instrumentation boundary.

## Initial Measurements, Not Final Acceptance

The early 14-sample checkpoint had:

| Metric | Measured range |
| --- | --- |
| System CPU | approximately 8-13% |
| DNS CPU | approximately 0-1% of one core |
| Available RAM | 275.8-290.3 MiB |
| DNS RSS | 13.4-13.8 MiB |
| DNS FD | 11 |
| DNS UDP sockets | 2 |
| Conntrack | 283-601 / 31,232 |
| DNS PID changes / observed failover | 0 / 0 |

The first periodic DNS, protected DoT, protected HTTPS, WAN-control HTTPS and
guard-presence probes passed. Three AWGs were UP. The short checkpoint is not
a substitute for the full window and is not a claim that resources cannot grow.

## Independent UDP And QUIC Controls

No transport, role, routing or firewall changes were made for these tests.
Temporary, checksummed diagnostic clients were built on the Mac, not on the
router. The provided `ssh moscow` VPS was used as an independent client.

| Test | Result | Meaning |
| --- | --- | --- |
| Public UDP DNS, independent VPS | PASS: correct A response for the fixed public test name from two public resolvers | The UDP controls answer independently of Native. |
| Same public UDP DNS through primary and backup AWG | PASS | Bidirectional UDP through both real tunnels for this protocol/endpoint. These are router-originated tests, not proof of all forwarded UDP. |
| Private UDP echo on supplied VPS | PASS locally: four matched nonce replies before and after the AWG trials | The listener works locally. External reachability/firewall allowance is not established. |
| That private echo through primary AWG | No reply | Inconclusive; not evidence that Native is defective. |
| Private echo through backup AWG | SKIPPED as an acceptance criterion | A different tunnel need not route to the first server's RFC1918 subnet. |
| Public STUN independent VPS | No reply | Unqualified control; no conclusion about Native from STUN failures. |
| HTTP/3 Cloudflare and Google, independent VPS | PASS: verified HTTP/3 200 | The QUIC client and those controls work independently. |
| Same HTTP/3 endpoints through the real AWGs and LAN | Timeout | FAIL for the tested AWG path; cause is not established. Direct bound-AWG controls also fail, so this does not isolate Native classification as the cause. |
| LAN protected HTTPS and TCP DNS | PASS | Native client path remains available. |
| Configured Direct destination TCP/443, root WAN and bound LAN client | PASS | Actual client Direct exclusion works for this destination/port. |
| Same destination TCP/22 | Timeout both in root WAN control and LAN | Not a Native-only failure. No SSH settings were changed. |

QUIC and unrestricted forwarded UDP are **not accepted** based on DNS-only
success or a silent echo. No UDP/443 block, transport reconfiguration or
unverified module/package was added to force a test result.

## Reports And Operations

An app-managed hourly read-only follow-up named `Native RC: наблюдение 48 часов`
checks the summaries and prepares a 24-hour interim and a 48-hour final report.
The router collector does not depend on Mac/SSH staying online. External
reports require the app and SSH path to be available; missing access must be
reported as a gap, not interpreted as stability. The bounded follow-up must
stop after the observation window, including an incomplete/failed window.

Read status without changing Native:

```sh
ssh openwrt 'w=$(cat /tmp/pkc-native-observe-current); sh "$w/native-observe.sh" status "$w"'
```

Fetch only private summary/config to the Mac, then format there:

```sh
scp -O openwrt:/tmp/pkc-native-observe.KkBDGk/config.json openwrt:/tmp/pkc-native-observe.KkBDGk/summary.json .router-backups/native-observation-20261107/
node tools/native-observe-report.js .router-backups/native-observation-20261107
```

To stop **only** the observer if needed:

```sh
ssh openwrt 'w=$(cat /tmp/pkc-native-observe-current); sh "$w/native-observe.sh" stop "$w"'
```

Stopping the observer does not stop Native or the emergency capsule. The full
48-hour stop is automatic. An unexpected reboot loses tmpfs data and does not
restart this operator-only observer; such a window is incomplete.

Limits: root AWG/WAN probes are not continuous LAN-client policy tests; table
presence is not packet-level leak proof; sub-minute outages may be missed;
counter aggregates after a PID change cannot prove an absence of accumulation.
No long-duration PASS may be assigned until actual measurements, coverage,
failure totals and relevant limitations have been reviewed after the deadline.
