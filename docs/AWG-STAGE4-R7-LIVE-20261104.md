# AX6000 Stage 4 r7: Authorized Deployment And Verification

Date: 2026-11-04, Europe/Moscow. Only Xiaomi Redmi AX6000 via `ssh openwrt`
was used. `openwrt2` / GL-MT6000 was not accessed. The operator explicitly
authorized installation, diagnostics and controlled routing recovery, then
confirmed that the existing OFF state was not an intentional disable.

## Outcome

**r7 installed and committed. Routing restored through the currently assigned
main AWG.** SSH, LAN/WAN, Xray, FakeDNS and IPv4 TCP TPROXY work. Existing UDP
interception was already ON and remains ON; IPv6 interception remains OFF.
There was no firmware/kernel/package/core upgrade, reboot, network/SSH/Wi-Fi
configuration change, browser interaction or GitHub push.

The final operator choice was to preserve all connection roles. The second
healthy AWG therefore remains rules-only, not an automatic backup. VLESS remains
unavailable directly; successful AWG routing does not make that backup healthy.

## Baseline And Installed Build

- Board: `xiaomi,redmi-router-ax6000-stock`, stock flash layout.
- OpenWrt 25.12.6, kernel 6.12.112, aarch64_cortex-a53, apk.
- Xray 26.3.27-r1; AWG tools 3.1.20260812-r1;
  kmod-amneziawg 6.12.112.3.1.20260906-r1; ip-full 6.18.0-r2.
- Installed r6 core hashes matched the baseline in the
  [preparation report](AWG-STABILITY-FIXES-20261104.md).
- Before installation: routing OFF, no main Xray, health daemon running,
  two owned AWG interfaces, nft table `fw4` only. WAN HTTPS control returned 200.
- Initial free overlay 43292 KiB, available memory 357508 KiB; no immediate resource
  exhaustion or unfinished Apply/health locks were found.

The source/file overlay, not a signed APK, is:

```text
podkopchik-awg-stage4-r7-20261104.tar.gz
SHA256 edd0d5f89717537775009bf9f48c816fd0fec94f0f451dbcec787b0c28f21fec
```

All **46 regular installed files** were checked against a SHA256 manifest of
that archive and matched, including code, LuCI views, ACL, translations and
deployment helpers. The application still displays `0.1.0-beta`; r7 identifies
this overlay revision, not a separate application version or an APK upgrade.

## Current Connections

These names and roles were read from the current device, not inferred from old
reports. URI credentials and private keys were never printed.

| Connection | Protocol | Role | Result |
| --- | --- | --- | --- |
| homeGermanyDir | AWG 3.1 | Main | UP; exit 5.44.46.180 |
| HomeGermanyWARP | AWG 3.1 | Rules only | UP; exit 104.28.197.9 |
| novos / ibn | VLESS XHTTP + Reality | Backup 1 | DOWN; direct probe timeout |
| openWRTgerWARP | VLESS TCP + Reality | Disabled | Isolated direct check timed out; remains disabled |

AWG addresses are distinct `/32` assignments, MTU 1280. Both profiles use the
same server endpoint but separate owned interfaces, marks and private routing
tables 49028/47170, including terminal unreachable defaults. Main routing was
not changed. No address/ownership conflict or interface RX/TX error/drop was
observed in the snapshots; that is not an exhaustive PMTU test.

## Backup And Independent Recovery

Private router directory, mode700:
`/root/podkopchik-stage4-r7-live-20261104-01/`.

Matching private Mac directory, mode700, excluded from Git:
`.router-backups/awg-stability-20261104/live-20261104-r7/`.

Archives are mode600. All three snapshot/archive hashes were verified after
transfer to the Mac. They contain secrets: do not publish them.

| Archive | Purpose | Routing Intent |
| --- | --- | --- |
| full-backup.tar.gz | Disaster copy: all UCI, Xray binary/config-related files, canonical app snapshot, nft/policy/runtime diagnostics | Original OFF |
| snapshot.tar.gz | Canonical pre-r7 app/code/UCI/AWG/health-state rollback | Original OFF |
| working-r7-snapshot.tar.gz | Canonical known-working r7 app/code/config snapshot | Authorized ON |

```text
full-backup.tar.gz
23b616454d957796aa5103b10328208b0257ab75e32ea8676a4ad4d15cd421b6
snapshot.tar.gz
8387f7a6c0fe04f1d0472b5f252e7ef9d8b460de6f6aab039644fe8f741c5b5e
working-r7-snapshot.tar.gz
63de1f2522ab29b25621eb0e5344b6b6f4db09e4eaeb09e49db4fed5ce40a7dd
```

Only the health worker was briefly paused for the initial consistent snapshot;
WAN/LAN and AWG interfaces were left alone at that stage. The independent
procd watchdog restored an isolated canonical fixture after the SSH session
closed, proving that its timer/recovery did not depend on the shell connection.
The self-test service was removed before arming the real deployment watchdog.

The real watchdog verified the private canonical snapshot, armed a 1200-second
monotonic deadline, and supervised the dedicated procd installer worker. It
was committed only after successful installation, runtime/data checks and
cleanup. Final procd queries show no installer or watchdog test service.

This task did not deliberately restore the entire application on the live LAN.
The actual restore test used an isolated file; full runtime recovery branches
were regression-tested locally and snapshot paths/hashes were checked on-device.
Do not describe this as a live all-down or full r7-to-r6 failure-injection pass.

## Deployment Sequence

1. Rechecked identity, SSH, WAN control, space, versions, current roles, routing
   intent, nft/policy state, active config and locks. No pending UCI deltas.
2. Verified the prepared archive/hash and the project's installer `--check`.
3. Created and transferred private backups; verified checksums on both devices.
4. Installed with the project's guarded worker. Exit 0. At this point UCI was
   **byte-for-byte unchanged**, routing remained OFF and no main Xray was started.
5. Ran real `validate`, `generate` and Xray `run -test`. All passed.
6. Validated the actual proposed nft batch with native `nft -c`. Preview-only
   adapters suppressed IP writes and replaced nft commit with a second dry-run;
   the live table/policy state remained untouched during this check.
7. Confirmed fresh real UP for the currently assigned main AWG. With the
   operator's intent clarified, performed controlled `podkopchikctl apply`.
8. Verified LAN traffic and repeated Apply, observed stability, removed the
   counter-only audit table, committed the watchdog and saved working r7.

No runtime source correction was needed during deployment. One diagnostic used
`stat`, absent on this OpenWrt image; it was replaced with `ls`/`wc`. That
diagnostic failure did not change routing, and remaining checks were completed.

## Verification Results

PASS covers only the stated observed scope.

| Check | Result | Evidence |
| --- | --- | --- |
| Identity, ABI/tools and installer preflight | PASS | Approved stock AX6000, matching versions, archive/type/path checks |
| Independent watchdog | PASS | Restored a private fixture after SSH disconnect; real guard committed after verification |
| r7 install / integrity | PASS | Worker exit 0; all 46 installed hashes match |
| Configuration preservation | PASS | Network/wireless/firewall/dhcp/dropbear and AWG files unchanged; Xray binary unchanged |
| UCI preservation | PASS | Original UCI unchanged except authorized routing_enabled 0-to-1, including roles, links and rules |
| Validate / generate / Xray native test | PASS | Configuration OK for generated and active JSON |
| Routing / listeners | PASS | One main Xray, TCP 12345, DNS TCP/UDP 1053, loopback API 10085 |
| Policy routing | PASS | Exactly one fwmark 0x100000 rule at 10991, table 10991 local default via lo |
| Repeated Apply | PASS | Two additional Applies; same JSON/nft, one policy rule, new ready main PIDs, guard released |
| FakeDNS | PASS | Pool 198.18.0.0/15 excluded from reserved/direct; real LAN UDP/TCP queries return fake addresses |
| DNS hijack | PASS | LAN dig to both router and 9.9.9.9 returns FakeDNS over UDP/TCP; scoped LAN DNS forward-to-WAN counter 0 |
| LAN YouTube / X | PASS | HTTP 200 through fake IPs; actual transparent-to-main-AWG log entries |
| After repeated core restarts | PASS, fresh DNS | Fresh mappings and final YouTube/X HTTPS both HTTP 200 |
| Telegram IP rules | PASS, scoped | Seven CIDRs in active config; 149.154.167.41:443 uses main AWG in logs and packet counters |
| Unmatched/direct | PASS | Pinned HTTPS direct control HTTP 200; unmatched example.com via FakeDNS also HTTP 200, log target direct |
| Endpoint bypass / exclusions | PASS | Endpoint IPs present before TPROXY; LAN endpoint SYNs observed in WAN forwarding, not router proxy |
| Health cleanup / diagnostics | PASS | No stale probe JSON/raw errors/locks after completed cycle; main PID not killed; separate mode 600 Xray/curl logs, <=4096 bytes |
| Short stability observation | PASS, limited | Two-minute four-sample window, routing=1 throughout, unchanged main PID/selection, both AWG UP |
| LuCI / rpcd / dnsmasq | PASS, service-level | Processes alive; LuCI HTTP 403 body is the normal username/password login form; authenticated buttons not browser-tested |
| Destructive Apply/nft/all-down faults | NOT RUN live | Isolated regression suites only; no working tunnel/WAN was deliberately failed |
| Manual-OFF reboot persistence | NOT RUN live | OFF survived the update; explicit-OFF boot behavior is mock-tested, no reboot performed |
| Exhaustive leaks / QUIC / IPv6 | NOT RUN | Scoped counters are not packet-capture proof for all traffic/protocols |

The two-minute observation was 22:28:03-22:30:04 Moscow time. The main Xray PID
was 11502 throughout, selected main AWG unchanged. Load averages stayed low;
a later 2-second CPU sample measured 5.2%, memory available 311632 KiB and
conntrack 4674/31232. Main Xray RSS 57384 KiB. No matching OOM/kernel error was
observed. These short samples cannot establish absence of a long-term leak.

After initial activation and both repeat Applies, there were three normal
controlled core starts, not an uncontrolled restart loop. No selection change
or failover was induced while the main connection remained healthy.

## Scoped Packet Evidence

A temporary owned `inet podkopchik_stage4_audit` had **counter-only** rules,
no marking or forwarding verdict changes. It scoped LAN counters to the Mac
client and WAN/AWG counters to specific destinations. It was removed before
commit; only `fw4` and `podkopchik` remain.

- Telegram test149.154.167.41:443: LAN6 packets/405 bytes; AWG output6/401;
  WAN forward0/0 and WAN output0/0. The small HTTP request returned404 from
  that IP; this tests IP routing, not complete MTProto functionality.
- Direct control1.1.1.1:443: WAN output12 packets/1235 bytes and HTTP200.
  This positive control demonstrates that the WAN counter could increment.
- Endpoint5.42.117.16:443: WAN forward4 packets/256 bytes; direct TCP timed
  out. Bypass is correct even when that external path itself is unavailable.
- LAN DNS: UDP2 packets/130 bytes, TCP6/360; client DNS WAN-forward0/0.
  Fake-pool WAN-forward0/0. No exhaustive router-origin DNS capture is claimed.

## AWG And VLESS Findings

Both AWG profiles passed 3/3 pinned, certificate-verified HTTPS requests. Main
AWG sample total times were261-662ms; secondary279-284ms. Main ICMP:5/5 replies,
RTT min/avg/max 51.409/59.960/69.146 ms. Secondary: 0/5 ICMP replies **while all
HTTPS probes succeeded**. Do not call this 100% application packet loss.
No MTU or obfuscation parameters were changed. Longer intermittent loss, UDP
quality and path MTU still require a separate bounded measurement plan.

Fresh VLESS endpoint tests:

- `famalymovi.ru` resolves to5.42.117.16. Direct WAN TCP443 times out; via
  either AWG, HTTPS returns200 with certificate verification.
- `80.90.182.238:443`: WAN and main AWG TCP timeout; secondary AWG establishes
  TCP in about57ms, but TLS does not complete within the4-second probe.
- Actual isolated VLESS checks directly through WAN remain DOWN/timeouts.
  Generic endpoint HTTPS is not a VLESS/Reality handshake over AWG.

This is path/source-dependent external reachability, not a missing nft bypass
or proof of a particular ISP/TSPU implementation. Server ACL, upstream routing
and filtering cannot be distinguished without independent/server-side data.
No URI, UUID, Reality settings or user roles were changed.

## Local Rechecks

All 17 JS smoke suites passed, including native mixed generation/failover, RPC,
rendering, runtime Apply mapping, translation coverage and the real LMO catalog.
Native ucode suites passed 100 parser/storage and 802 interception/lifecycle/UCI
assertions (902 total). Kernel/network parts of those suites remain mocks.

The following eight focused shell regression suites were rerun successfully:

```sh
sh tests/awg_snapshot_smoke.sh
sh tests/awg_stage4_admin_smoke.sh
sh tests/safe_apply_smoke.sh
sh tests/startup_safety_smoke.sh
sh tests/health_diagnostics_smoke.sh
sh tests/health_check_cleanup_smoke.sh
sh tests/health_failover_apply_race_smoke.sh
sh tests/xray_instance_restart_smoke.sh
```

Shell syntax 58 files, JS parse 31 files, JSON 3 files, `msgfmt -c`, docs
links/fences and `git diff --check` passed. No runtime source was edited in this
deployment task; documentation records the observed outcome and remaining gates.

## Remaining Limits

- Automatic redundancy is currently limited: main AWG is UP, configured VLESS
  backup1 is DOWN, and the other healthy AWG is rules-only by explicit operator
  choice. A main failure must not be represented as a tested healthy fallback.
- Live failover/all-down, deliberate nft/start failure and full rollback were
  not injected. Regression suites cover them with mocked kernel/network state.
- UDP1/IPv60 were preserved, not newly enabled. No claim of new UDP/IPv6/QUIC
  acceptance, UDP443 block or global leak protection is made.
- Xray restarts renew in-memory FakeDNS mappings. Final tests used fresh DNS;
  long-lived cached fake-IP sessions across restart were not accepted here.
- Source package manager cache warnings did not block installed-package checks;
  no apk update/install or trust bypass was used.

## Future Recovery

The pre-r7 snapshot restores its original **OFF** intent. To restore the known
working r7 **ON** state instead, use its canonical snapshot with a new private
guard directory on the same approved router:

```sh
src=/root/podkopchik-stage4-r7-live-20261104-01
restore=/root/podkopchik-stage4-r7-recover-$(date +%s)
umask 077
mkdir -m 700 "$restore"
cp "$src/working-r7-snapshot.tar.gz" "$restore/snapshot.tar.gz"
cp "$src/working-r7-snapshot.sha256" "$restore/snapshot.sha256"
cp "$src/watchdog.sh" "$restore/watchdog.sh"
cp "$src/guard-lock.uc" "$restore/guard-lock.uc"
printf '%s\n' restore > "$restore/kind"
sh "$restore/watchdog.sh" arm "$restore" 60
sh "$restore/watchdog.sh" request "$restore"
```

These recovery commands were **not** executed against the live application in
this task. Verify restored marker/logs, SSH, runtime/health, DNS and routes before
removing its completed watchdog service. Never reuse a committed directory,
unpack `full-backup.tar.gz` over `/`, flush nft or fabricate UP state.
Historical generic `podkopchikctl rollback` is not the mixed-AWG restore path.

Read-only repeat checks:

```sh
podkopchikctl status
podkopchikctl validate-active
pgrep -af xray
nft list table inet podkopchik
ip -4 rule show
ip -4 route show table 10991
ip -4 route show default
nslookup -port=1053 x.com 127.0.0.1
```

On a LAN client, test both `dig @192.168.1.1 x.com` and
`dig +tcp @192.168.1.1 x.com`, then real HTTPS with fresh DNS mappings.
Do not run failure injection or reboot on the working LAN merely to repeat
the non-destructive acceptance above.
