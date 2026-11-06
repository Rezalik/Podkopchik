# Universal Routing Engine: AX6000 acceptance

**Decision: NOT READY for the household LAN or a stable release.**

Baseline: `2e99bea`, branch `feature/universal-routing-engine`.
This report separates current measurements, earlier physical pilots and VM
evidence. The home router still uses its original runtime.

## Architecture and changes

The experimental native path is LAN DNS → transactional classification and
synthetic lease → nftables DNAT and policy routing → independent adapter.
The kernel carries native AmneziaWG; only the VLESS adapter needs Xray.
Explicit direct policy remains a separate outcome, not a fallback when an
adapter fails. Firewall and RPDB guards run independently of adapters.
There is no continuously running WAN Guard daemon; the existing Podkopchik
startup, Apply and restore paths synchronize owned nftables/RPDB state.
Temporary procd watchdogs are used only during acceptance transactions.

The legacy working Apply does not activate the native engine. The new
`podkopchikctl native-preview INVENTORY.json` validates and compiles live
UCI rules for a separate LAN without installing rules or starting services.
It reports the DNS policy and nft plans, including both pools in the Core's
quarantine batch, and does not emit proxy credentials.
It rejects overlapping domain targets and refuses to reuse the active
legacy LAN. Inventory and health must be refreshed before activation.

| Area | Files and change |
| --- | --- |
| UCI and adapters | `generate.uc`, `universal_plan.uc`, `universal_selection.uc`, `awg_network.uc`: native plan compilation, AWG ownership inspection without a write lock, fresh-health selection, ordered backup, cooldown and all-down block. |
| DNS and guard | `native/dns/{policy,server,server_test}.go`, `virtual-pilot-plan.uc`, `fakedns_guard.uc`: active/retired pool handling, SERVFAIL for retired upstream addresses even on direct DNS, guard status that detects missing rules without writing state. |
| CLI and LuCI | `podkopchikctl`, `status.js`, Russian PO and LMO: report the actual legacy mode and installed/incomplete quarantine without offering an unverified switch. |
| Acceptance tooling | Native UCI/selector/status smokes, EFI reboot and DNS FD soak, bounded interface-bound UDP capture helper, and the existing staged guard rollback fixture and packaging. |

## Local acceptance

| Check | Status |
| --- | --- |
| Real UCI domain/IP/LAN mapping, plan rendering and credential redaction | PASS in VM; missing/overlapping plans rejected. The preview is not an active Apply. |
| Workstation validation | PASS: 51 smoke suites, 0 failures; the six UCI/Xray-only skips ran in the VM. Five Go race runs, Go vet, JS/JSON/shell checks, msgfmt and LuCI LMO coverage passed. |
| DNS UDP/TCP, CNAME, cache, TTL, concurrent queries, retired pools | PASS in tests. Atomic binding commit is required before synthetic answers; failures return SERVFAIL. |
| Native path, direct, VLESS, shared CDN and mixed policies | PASS in VM using veth transport stand-ins and actual Xray/VLESS test peers. Not a physical VLESS or kernel AWG test. |
| UDP round trip, conntrack expiry, delayed reply, TLS HTTPS and HTTP/3 | PASS in VM; a deliberately late reply was dropped after revocation. |
| Failover, all-down, TCP-only reserve, repeated Apply and fw4 reload | PASS in VM with supported transport combinations; unsupported UDP is denied, not sent direct. |
| Guard, both synthetic pools, rollback and service isolation | PASS in VM. The legacy FakeDNS listener remains usable; raw pool traffic does not leave the virtual WAN. The test-only procd watchdog restored the baseline. |
| Real EFI VM reboot and automatic procd restart | PASS. An unfinished prior-boot trial could not be confirmed, DNS ledger survived, and pre-reboot synthetic addresses were blocked. After reboot: 0 protected or plaintext DNS packets, 64 direct controls on virtual WAN; after rollback: 0 synthetic packets and 8 direct controls. |
| DNS resource soak | PASS: 180 seconds, 2,222 successful queries across transport switches. Classifier FD 11 → 13 peak → 11 after drain; RSS 4,248 → 9,244 KiB, final conntrack 1,177 in the isolated router namespace. This is not a long-running Xray leak test. |
| ARM64 review build | PASS: two builds matched byte for byte, archives contain only regular root-owned files, SHA256 verified. The archive is not an installer. |
| Production native Apply, general LAN migration and boot recovery | FAIL as a release gate: the real service still lacks a qualified native activation controller; laboratory lifecycle evidence is not production integration. |
| Hardware flow offloading and long-term physical FD stability | SKIPPED. The native preflight refuses configured software/hardware offload or a live flowtable. |

## Physical acceptance

| Check | Status and evidence |
| --- | --- |
| Household baseline | PASS. SSH from Mac, WAN HTTPS and HTTPS bound to each of the three live AWG interfaces. Home configuration was not changed. |
| Reserved management path | FAIL as a pilot gate. The current noninteractive SSH attempt through `media` did not authenticate. The prior physical rollback verification through it is historical evidence only. |
| DNS and native HTTPS without Xray | PASS in the earlier scoped AX6000 pilot. No new native pilot was run in this phase. |
| UDP through an already running AWG, independent of the new engine | FAIL for a round trip. Public and tunnel-internal echo listeners on `moscow` each passed local self-tests but did not receive the Xiaomi query. Each router capture saw one inner request, zero replies and zero clear UDP to the echo port on physical WAN. The internal probe saw matching conntrack `1/0` and encrypted AWG outer traffic. The loss point is not known; these results do not establish that AWG UDP is broken. |
| Public echo eligibility for the native virtual pilot | FAIL. The sole public IPv4 of `moscow` is an endpoint for two active profiles and is in bypass. Its tunnel-internal IP is not a valid real destination for the protected synthetic DNS policy. |
| Legacy FakeDNS on physical WAN | FAIL as a release gate. A prior physical capture showed ICMP to the old pool. In this phase both forwarded ICMP conntrack flows and the WAN route still existed without guard. The integrated fix was not installed or wire-tested on the household router. |
| Virtual-client UDP, QUIC, direct, route-loss and WAN capture in the new build | SKIPPED; no new virtual segment was armed. No physical VLESS profile was created or changed. |
| Physical rollback | Historical PASS for the earlier scoped pilot. SKIPPED for this candidate; no household mutation to undo. |

The echo listeners on `moscow` were temporary, source-restricted, and were
closed. The router used a temporary probe and capture tools in /tmp; no
package was installed and no policy or nftables state was changed. The
clear-WAN count is for the specific UDP probes, not a fresh FakeDNS
acceptance capture.

Physical post-probe sample: CPU 2.7% busy over two seconds; MemAvailable
293,092 KiB; main Xray RSS 59,492 KiB and 3,909/16,384 FD; conntrack
5,904/31,232. Available flash was 21,476 KiB and /tmp 247,280 KiB.

## Operational constraints

- Client DoH/DoT, cached real IPs, literal IPs and other DNS bypasses still
  require explicit client/network policy. A stale address that the legacy
  Xray allocator has reissued cannot be distinguished from its new binding
  by IP alone. The egress guard still blocks raw synthetic destinations.
- The virtual AX6000 scope is IPv4. The dual-stack VM does not prove
  physical IPv6 or MediaTek PPE behavior.
- Existing UCI group slots are the legacy configured ordered backups.
  The preview selects among observed healthy candidates but does not
  implement production health-driven switching or a migration UI.
- A VM load test cannot establish long-term FD behavior of the installed
  household Xray. There was no Xray patch, scheduled restart or FD-limit
  increase in this phase.

## Update and recovery

1. **Do not install the review archive over the working router.** Build
   with `tools/build-native-ax6000-review.sh`, verify both SHA256 sidecars
   and confirm the source commit. The archive is not an installer.
2. Before an authorized, isolated trial, restore the independent management
   login, verify a fresh private backup and autonomous rollback, and
   prequalify a working echo address that is not an endpoint or bypass.
   Check current routes, both pools, free space, guard ownership, capture
   path and the normal home DNS/WAN/AWG state. Do not use `moscow`'s
   current public address as the synthetic test target.
3. Follow `UNIVERSAL-AX6000-VIRTUAL-PILOT.md` and
   `UNIVERSAL-AX6000-FAKEDNS-UDP.md`. Keep the watchdog deadline and
   verify WAN capture with positive direct and encrypted controls. Stop on
   any critical failure. After rollback verify SSH, LuCI, DNS, routes,
   owned rules and all AWG; retain quarantine for already-issued addresses.
4. Household switching requires a separate approval after physical
   acceptance and a verified production activation/restore transaction.
   A scoped pilot or passing VM run does not authorize that step.

Keep `main` untouched. No stable release or router rollout is authorized by
this report. The exact source revision is recorded in
`source-revision.txt` in the workstation build directory alongside
the unsigned review artifacts.

- ARM64 review archive SHA256: `064803773d0d255135c3281135627595ca5aa21d5f7cc60467a5fcdb0a5c4df7`.
- Separate ARM64 UDP probe SHA256: `e7fd549926ff2d0d215d1f6748de2bbb6f48a4e3b4a3051cf3fc256a7f137d3e`.
- Review archive: 2,361,348 bytes. Modelled flash need with state, recovery
  and reserve: 13,426,688 bytes. Archive plus unpacked files in /tmp:
  8,450,048 bytes before optional probe, captures and rollback workspace.
