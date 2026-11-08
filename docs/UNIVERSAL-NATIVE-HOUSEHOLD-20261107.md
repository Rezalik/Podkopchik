# Xiaomi Household Native RC, 2026-11-07

Current operator-approved state on 2026-11-08 is selective Native with ordinary
transactional Apply. The later [cleanup](AX6000-CLEANUP-20261108.md) retired the
separate emergency capsule and removed old router backups. Strict/repair
settings, PIDs and backup locations below are historical rollout evidence,
not instructions for the current router. See the [Russian guide](GUIDE-RU.md).

## Selective Policy Correction, 2026-11-08

The operator explicitly replaced the earlier whole-LAN Strict policy below
with Podkopchik's selective policy: `native_classification_mode=compatible`
and `native_migration_restrict_unknown=0`. Apply was validated and confirmed;
81 domain names, seven IP rules, exclusions and all three AWG roles were kept.
Unmatched IPv4/IPv6 now uses Direct; selected services retain their transport.
Network, wireless, DHCP and SSH file hashes and the default route are unchanged.

Before correction, real Roblox game/STUN connections had no replies over the
main/backup WARP paths. The same two STUN endpoints each returned four matched
replies over the rules-only GermanyDir tunnel and WAN, independently of Native
LAN classification. After correction, both LAN STUN probes returned four
matched replies; Roblox HTTPS and protected YouTube/Instagram/X HTTPS passed.
The user subsequently confirmed successful gameplay on the home Wi-Fi and
that error 279 disappeared. This is acceptance for the reported client, not
a guarantee for every Roblox experience or transport endpoint.
No Roblox exception or broad shared-CDN Direct grant was added.

A bounded 15-second, 128-packet-per-interface capture of the two qualified
Roblox controls counted eight outgoing and eight incoming packets on LAN and
physical WAN, and zero on the main AWG. Only counts were retained; no packet
payloads or client addresses were saved. All temporary captures were stopped.

Local checks: 23 JavaScript smoke tests, JS/shell syntax and diff whitespace
checks passed. The real UCI generator selective-default regression and the
explicit Strict/Compatible planner regression passed in a NIC-free OpenWrt VM.
The unit-only VM explicitly skipped the generator's kernel `nft -c` step;
the installed physical generation separately passed `validate-active` and the
bounded transport checks above. No new package or system component was installed.

The normal Apply intentionally replaced the Native DNS PID (32577 to 19891).
The ongoing resource observation must distinguish the two policy/PID segments;
a restart-related FD drop is not evidence of a leak fix or one uninterrupted
48-hour same-configuration stability result. The historical initial rollout
and its Strict acceptance below remain the record for 2026-11-07.

To explicitly return to the former Strict policy, without restoring allocator
files or replacing current profiles/rules:

```sh
uci set podkopchik.main.native_classification_mode='strict'
uci set podkopchik.main.native_migration_restrict_unknown='1'
uci commit podkopchik
podkopchikctl apply
# After readiness checks, use the pending token printed by Apply:
podkopchikctl native-confirm TOKEN_FROM_APPLY
```

This is a deliberate policy rollback, not a recommended fix for Roblox. The
pre-change configuration remains root-private on the router; its checksum was
verified without transferring configuration secrets to the workstation.

## Actual Installed Mode

This is a physical whole-LAN pilot on Xiaomi Redmi Router AX6000 stock layout,
OpenWrt 25.12.6, kernel 6.12.112. It is not a namespace-only preview and is not
yet a stable release. Neither the second router nor GitHub main was touched.

The operator explicitly confirmed ordinary Native Apply. Active settings are:

```uci
option routing_engine 'native'
option native_recovery_policy 'repair'
option native_classification_mode 'strict'
option native_unknown_action 'protected'
option native_migration_restrict_unknown '1'
option native_direct_grants_confirmed '1'
option native_pool_v4 '172.30.0.0/16'
option native_dns_port '1053'
```

The port deliberately reuses the old DNS interception port, reducing the
migration hazard of pre-existing DNS NAT tuples. The held-socket acceptance
utility expired before its follow-up query: physical continuity of that exact
socket is **SKIPPED**, not PASS. New UDP and TCP LAN DNS queries passed.

Six domain groups, seven Telegram CIDRs, explicit Direct grants and existing
Main/Backup AWG roles are retained. AWG packet forwarding is kernel DNAT,
fwmark/RPDB and NAT. The three original AWG interfaces stay up. No Xray runs
in this AWG-only configuration; the installed Xray binary remains unchanged.
Unsupported native IPv6 is blocked, not sent to WAN. No default route, Wi-Fi,
network or DHCP change and no physical reboot was performed. Only owned
firewall includes and Native routing/protection resources were added.

## Results

| Check | Result and boundary |
| --- | --- |
| Static install and preflight | PASS: checksummed ARM64 payload, root ownership/modes, original UCI preserved until explicit Native settings/Apply. |
| Pool admission | PASS: 172.30/16 admitted against addresses, VPN non-default AllowedIPs, 49 routes, 18 policy rules, endpoint/Direct grants and issued pools. |
| Protected upstream | PASS: certificate-verified DoT through each real AWG, provider fallback, bad certificate/changed-ifindex rejection, recovery without restart. Physical WAN matching DNS packets: 0; tunnel captures positive. |
| Real LAN DNS and HTTPS | PASS: UDP/TCP DNS; trusted HTTPS for YouTube, Instagram, X, Telegram and ordinary sites. Cached real-IP HTTPS uses Strict protected fallback, not domain inference. |
| Applications | PASS by user: after initial failure and client Wi-Fi refresh, apps work; after MSS repair the user reports improvement. Not a substitute for a long video-load test. |
| AWG independence | PASS: Native data and DoT work with no Xray process. The DNS process is not an application UDP-session proxy. |
| MSS | PASS: VM and physical SYN capture confirm 1460 becomes 1240 for tunnel MTU 1280. Profiles/interface MTU are unchanged. |
| Real failover | PASS: reject only the primary's locally generated HTTPS health probe, leave tunnel/data/DoT intact. Three failures select backup; LAN YouTube HTTPS succeeds. Independent procd timer removes only the fault table. Two successes return to primary. |
| Synthetic quarantine | PASS for tested paths: unknown Native, old FakeDNS and old pilot destinations are denied. Bounded WAN capture has no matching synthetic/clear DNS packets. Not a proof for every future firewall/hardware state. |
| Physical UDP | PARTIAL: primary AWG returns a correct UDP DNS response from Google; backup responds from Cloudflare. LAN STUN leaves through backup with 0 matching packets on WAN, but no STUN reply. No claim of full bidirectional Native UDP acceptance. |
| Private UDP echo | SKIPPED: temporary listener on the supplied remote host starts, but independent AWG controls receive no reply. Firewall inspection needs unavailable elevated access. A timeout is not proof of Native failure. |
| Physical QUIC | SKIPPED: HTTP/3 tests and independent direct-AWG controls time out. No UDP/443 block was added. |
| VM networking/lifecycle | PASS for DNS, dual-stack TCP/TLS/UDP echo/QUIC, shared CDN/cached IP, failover, all-down, scoped Direct, repeated Apply/live tuple, firewall4 reload and classifier/supervisor SIGKILL. Actual persistent VM reboots and standalone emergency recovery also pass. |
| Physical all-down/emergency reboot | SKIPPED: no destructive family-network test or reboot. Detached physical watchdog rehearsal passed; full protected restore passed in VM. |
| Resources | Short observation only; see address-free measurements below. Many-hour stability is NOT confirmed. |

## Repairs And Diagnostic Incidents

1. The first workstation probes accidentally used a phone hotspot interface.
   Those failures are invalid LAN evidence. Subsequent probes selected the
   interface from the route to the Xiaomi, and passed on Ethernet and Wi-Fi.
2. An overly broad three-minute AWG capture filled tmpfs. This interrupted
   health/DNS state updates. Only the operator-created capture processes/files
   were removed; Native recovered in place. No user data was deleted. Later
   captures are limited by packet count **and** duration, not duration alone.
   Initial app failures cannot be attributed solely to client DNS cache.
3. Native kernel forwarding initially lacked the MSS fix formerly supplied by
   Xray's local TCP stack. Scoped, mark/pin/interface-bound MSS rules now use
   route MTU in both directions, preserving explicit Direct traffic.
4. Periodic unnecessary AWG start operations contended with the health mutex.
   The controller now skips mutations only after checking owned live interface,
   revision, assigned addresses and terminal routing guards. Invalid resources
   still reconcile/fail closed. Successful selection clears a stale error.
5. The final VM teardown exposed named-vs-numeric `RTN_LOCAL` ownership handling
   for VLESS. Numeric type 2 is now accepted under the same strict ownership
   checks; foreign routes still fail. No physical VLESS profile was created.

Same-object 4 MiB diagnostic downloads, not a sustained speed test: LAN before
MSS about 0.94 MB/s, directly from router over AWG about 2.53 MB/s, LAN after
MSS about 1.17 MB/s. Backup LAN 2 MiB check about 1.31 MB/s. Different sampling
times and Wi-Fi contention prevent treating this as a causal throughput
benchmark. Remaining upstream/UDP and radio variability is not concealed.

## Recovery And Resource Boundary

The verified private legacy archive exists on the Mac and in router tmpfs;
the original Xray SHA256 is attested. A minimal frozen recovery capsule on
flash occupies about 56 KiB allocated (160 KiB logical), reuses that existing
binary and unchanged AWG profiles, and is supervised independently by procd.
It was armed before cutover and accepted only after external SSH/LuCI and
confirmed Native worked. It no longer depends on a Mac heartbeat. Ordinary
site/provider/transport faults do not roll back Native. Local management
listener loss or an explicit critical request invokes protected legacy rescue.
External management-path failure is not fully proved by a local-listener test.

The physical detached rehearsal removed its own test table with household
UCI/nft/RPDB/default route and Xray PID unchanged. Full physical restore has not
been forced. The VM exercises the actual frozen rescue code, protected legacy
TCP, UDP/TCP DNS restoration and zero matching protected packets on test WAN.

Measured flash after deployment is about 18 MiB free; tmpfs after capture
cleanup exceeds 200 MiB free. No user files were removed. The snapshot/WAL
budget and immutable-generation retention remain enforced by preflight.
Ten samples over 270 seconds of one post-repair PID: 11-20 FD, exactly two UDP
listeners throughout, RSS 13,320-14,200 KiB, conntrack 229-723. The final
generation starts a new DNS PID with 11 FD and two UDP listeners. There is no
many-hour acceptance based on these samples, and restart-related drops are not
claimed as proof against a leak.

Both the original legacy backup and an accepted-Native configuration checkpoint
were copied to a mode-700 ignored directory on the Mac, archive mode 600, with
matching SHA256. A configuration backup is **not** authorization to rewind an
exposed synthetic allocator. Never restore an older watermark over the live
issued namespace: retain current allocation history, or retire/quarantine that
pool and admit a different nonoverlapping pool. Emergency legacy rescue retains
the Native-pool quarantine instead of reusing its addresses.

Reproducible workstation build:

```sh
sh tools/build-native-candidate.sh "$PWD/.build/native-home-rc-final"
node tools/verify-native-candidate.js .build/native-home-rc-final/podkopchik-native-ax6000-candidate.tar.gz
```

The build requires pinned Go 1.26.10 and verified module dependencies on the
workstation. It compares two independent ARM64 binaries and emits a manifest
plus external `.tar.gz.sha256`. The deployed helper SHA256 is
`008199436fca9f396056455ada6bea78f9851773e315a8db3b2f2b3be6e6fcba`.
This unsigned local artifact is not a signed OpenWrt package or stable release.

Address-free repeat measurement from the workstation:

```sh
scp -O tools/native-resource-snapshot.uc openwrt:/tmp/pkc-native-resource.uc
ssh openwrt 'date -u; ucode /tmp/pkc-native-resource.uc'
ssh openwrt 'podkopchikctl native-status; podkopchikctl fakedns-guard-status'
```

## Operator Checks And Emergency Recovery

```sh
ssh openwrt 'podkopchikctl status; podkopchikctl validate'
ssh openwrt 'podkopchikctl native-emergency status; ip rule; ip route show default'
ssh openwrt 'nft list table inet podkopchik_native; nft list table inet podkopchik_native_gate'
```

Do not run `update-install` from main over this feature RC without reviewing
compatibility. Do not change allocator files, recycle issued pools or delete
old guards to clear client caches. Old cached FakeDNS addresses are deliberately
denied; reconnect the client and refresh its resolver/application state.

For an actual critical emergency only, after verifying the frozen kit:

```sh
ssh openwrt 'podkopchikctl native-emergency verify'
ssh openwrt 'podkopchikctl native-emergency request'
ssh openwrt 'podkopchikctl native-emergency status; podkopchikctl status'
```

The independent watcher performs protected rescue without requiring the SSH
session to survive. Its result must be verified; it is not an unconditional
"internet guaranteed" button. Full archive recovery is a separate operator
procedure and must retain synthetic quarantine and saved allocation history.

Remaining physical gates: controlled bidirectional UDP/QUIC with a reachable
independent control, VLESS profile if supplied, native IPv6 tunnel, WAN hotplug,
actual physical boot/emergency restoration, and many-hour video-load resources.

## Local Release Checks

- 59 workstation smoke checks PASS, 0 FAIL, 6 host-only SKIPPED (OpenWrt UCI
  module unavailable). The skipped generator/core cases pass separately in the
  OpenWrt guest with the real Xray binary.
- Go race tests PASS, including concurrent protected DNS, negative TLS cases,
  provider/transport recovery and the bounded UDP diagnostic parser.
- Shell syntax, LuCI JS parse/render, JSON, gettext/LMO, i18n and diff checks PASS.
- The original mock health cleanup test had a timing race: its shell trap was
  deferred by a one-second sleep, exactly the production kill grace. The mock
  uses a shorter sleep; assertions and production health cleanup are unchanged.
- VM mixed VLESS teardown initially failed on numeric route type 2. The strict
  ownership fix passes its focused regression and real mixed-transport cleanup.
- Two independent ARM64 helper builds are byte-identical; archive path/type,
  owner, file manifest, size limits and ELF architecture checks PASS.
