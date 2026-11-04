# AX6000 Stage 4 r7 Stability Candidate

## Scope And Outcome

Prepared locally on 2026-11-04 against the installed Stage 4 r6 baseline.
Only `ssh openwrt`, Xiaomi Redmi AX6000 stock, was inspected. `openwrt2` /
GL-MT6000 was not accessed. No application update, package install, routing
Apply, service restart, reboot or configuration change was performed on the
router. Short network probes and a native `nft -c` guard syntax check were used.

**Not deployed.** The public r7 overlay is an unsigned source/file overlay, not
an APK. OpenWrt, kernel, Xray and AWG packages are not included or upgraded.
Runtime version stays `0.1.0-beta`; SDK package revision increments to 4.

## Router Evidence

- Board: `xiaomi,redmi-router-ax6000-stock`, OpenWrt 25.12.6,
  kernel 6.12.112, aarch64_cortex-a53.
- At diagnosis, `enabled=1` but **`routing_enabled=0` already**; no main Xray.
  The health daemon and two owned AWG interfaces were present.
- FakeDNS/hijack were configured ON, UDP interception ON, IPv6 interception OFF.
  Those flags were read, never changed.
- `homeGermanyDir` main and `HomeGermanyWARP` rules-only had fresh real UP
  results; `novos` / tag `ibn`, backup 1, had repeated failed checks.
- WAN and LAN links were up. WAN default remained
  `default via 10.77.196.1 dev wan ... src 10.77.196.229`.
- Initial resources: about 348 MiB available RAM and 42 MiB free overlay;
  no immediate memory/storage exhaustion was observed.

The installed SHA256 values matched the repository baseline for init,
`podkopchikctl`, `health_check.sh`, `apply_rules.sh`, `generate.uc` and
`awg_network.uc`. This ties the confirmed code defects to the deployed version,
but does **not** prove which action originally changed `routing_enabled` to OFF;
the retained logs did not establish that history.

Baseline Git revision: `3d55122561d5fa2d9e0e7d0c57c1e345d11494e4`.
Final read-only check reconfirmed the same installed hashes, OFF flag and WAN
default; no patched code was present on the device.

## VLESS Diagnosis

Safe metadata extraction showed `novos` uses a literal IPv4 endpoint
`80.90.182.238:443`, xhttp + Reality. No URI, UUID or Reality keys were printed.
DNS/AAAA selection therefore cannot explain these particular endpoint failures.

Bounded curl probes used 4-second connect / 5-second total timeouts, pinned
destinations and explicit interfaces, without changing routes or using VLESS
credentials:

| Path | Observation |
| --- | --- |
| WAN control, pinned 1.1.1.1 HTTPS | HTTP 200; TCP about 3.6 ms |
| VLESS endpoint via WAN | curl 28; TCP connect not completed |
| VLESS endpoint via homeGermanyDir | curl 28; TCP connect not completed |
| VLESS endpoint via HomeGermanyWARP | TCP completed in about 40 ms; TLS did not complete within 5 s |
| Mac en0 in the same LAN | curl 28; TCP connect not completed |

WAN output policy was accept, with no matching reject counter observed. Endpoint
bypass is LAN prerouting, not router OUTPUT, so it does not explain these
router-originated probes. Overall WAN connectivity worked.

**Conclusion:** path/source-dependent TCP reachability is confirmed. The server
is not proven globally down, since TCP connected over one WARP path. ISP
filtering, upstream routing or server-side filtering remain alternatives. The
same-LAN Mac is not an independent external vantage point. A TLS probe to an IP
is not a VLESS/Reality handshake and does not validate those credentials.

Next external evidence needed: VPS listener/firewall status and SYN capture
during one timed WAN probe, plus a genuinely independent client. Do not change
the VLESS URI or add tunnel chaining based on this evidence alone.

## Confirmed Code Defects And Fixes

1. Missing enabled connections/rules in Apply wrote `routing_enabled=0` and
   removed current interception. It now rejects before runtime mutation; normal
   validation errors preserve saved intent and the existing working pair.
2. Init logged nft failure but continued starting candidate Xray. It now refuses
   that startup, retains bounded private diagnostics and attempts validated
   last-working recovery. It cannot report live routing from UCI intent alone.
3. Previous-config rollback covered JSON incompletely, not the corresponding
   nft/runtime state. `routing_safety.sh` checkpoints a validated working pair,
   owns an independent forward guard, and restores exact owned routing state.
4. Failover published selection before an asynchronous Xray restart completed.
   The restart is synchronous and readiness excludes previous core PIDs;
   failed application retains previous selected state. Unchanged selection
   still causes no restart.
5. Curl stderr overwrote Xray stderr and public errors lost the original phase.
   Separate private files now retain redacted bounded diagnostics; curl 28 by
   itself is a probe timeout with an **unconfirmed** TCP stage, not proof of a
   TCP connect failure. Only an Xray dial timeout identifies that failure.
6. Stage 4 deployment/rollback always called Apply, potentially overriding
   explicit OFF. It now restarts health/service without enabling interception
   when OFF. Downgrade guard release waits for a new ready main listener.
7. Uninstall removes its owned guard before deleting the helper, avoiding an
   orphaned forward block after an explicit uninstall.

`apply_rules.sh`, `cleanup_rules.sh`, `generate.uc`, the endpoint bypass,
FakeDNS/DNS redirect rules, proxy URI settings and health selection algorithms
are unchanged. Health changes concern diagnostics/cleanup and acknowledged
runtime application, not thresholds or backup preference.

## Safety Semantics

`routing_enabled` is persistent user intent. `Routing applied` requires a main
Xray PID owning the transparent TCP listener, an interception table and no
active guard. Health Xray and an old main PID cannot acknowledge a new restart.

Pure validation occurs before AWG synchronization or active file replacement.
After that, Apply arms `inet podkopchik_guard` before changing runtime state.
The guard only filters **forward**, priority -10, from the last applied and
pending LAN interfaces. It leaves router INPUT/OUTPUT and SSH untouched.

**Conservative failure tradeoff:** if recovery cannot complete, all forwarding
from those LAN interfaces is blocked, including otherwise-direct traffic. This
is not a per-domain kill switch. A completely unavailable nft subsystem cannot
install a guard; that condition is reported CRITICAL rather than claiming a
guarantee. Already offloaded flows require separate live testing.

Private checkpoints are `.working-*` directories under `/etc/podkopchik`, with
JSON, nft table, LAN/IPv6 metadata and checksums. An atomic pointer selects the
current generation; retain current and previous only. Restoring AWG runtime
starts the profiles referenced by restored outbounds, not pending UCI roles.
The profiles must still exist and satisfy ownership checks. Corrupt/missing
checkpoints or profiles fail guarded. This is controlled recovery, not fsync or
power-loss atomicity, and does not replace a full secret configuration backup.

`podkopchikctl cleanup` is deliberately different: it persists OFF, removes
owned interception/guard state and allows normal direct forwarding. Use it
only when that exposure is intended. Service stop/restart while intent is ON
retains protection. A stale lock after SIGKILL requires inspection, not a blind
lock deletion while another transaction may be running.

Health retained files are `health-TAG.xray.log` / `health-TAG.curl.log`, mode
0600 and at most 4096 bytes each. Raw stderr/config/IP files are removed after
the probe or interruption. No public health state contains raw core stderr.

## Verification

Commands run locally include:

```sh
sh tests/safe_apply_smoke.sh
sh tests/startup_safety_smoke.sh
sh tests/health_diagnostics_smoke.sh
sh tests/health_check_cleanup_smoke.sh
sh tests/health_failover_apply_race_smoke.sh
sh tests/xray_instance_restart_smoke.sh
sh tests/awg_stage4_admin_smoke.sh
```

The full shell smoke run passed 28 suites; 7 were initially skipped because
native OpenWrt tools were absent from PATH. AWG model/integration were rerun
successfully with a local native ucode + fs build: 100 parser/storage, 13
interception, 729 lifecycle and 60 UCI/rollback assertions. Five stock
ucode/UCI/jsonfilter shell suites remain skipped on this Mac; equivalent mixed
generator coverage uses native ucode with test UCI. All 17 JS smoke suites
passed, including mixed generation/failover, UI rendering, i18n and LMO.
Shell syntax (58 files), JS parse (31 files), JSON (3 files), native compilation
of `awg_cli.uc`, `msgfmt -c` and `git diff --check` also passed. Markdown was
reviewed manually; no markdownlint executable is available locally.

Tests cover missing rules/proxies, invalid config, nft/startup failure,
last-working recovery after simulated `/tmp` loss, foreign guard refusal,
fresh core readiness, explicit OFF on fresh init, AWG UP/VLESS UP,
AWG DOWN/VLESS UP, all-down blocking, AWG return, thresholds and cooldown.

These are **mocked kernel/procd/network scenarios**, not live WAN-leak or reboot
acceptance. Native nft dry-run on the approved router accepted guard syntax
without applying it. Real r7 startup/apply failure recovery, exhaustive packet
capture with flow offload and physical reboot/manual-OFF persistence remain
NOT TESTED. No production traffic interruption was induced.

## Prepared Update And Safe Deployment Plan

Local private artifact directory (ignored by Git):
`.router-backups/awg-stability-20261104/`.

- r7 public code overlay: `podkopchik-awg-stage4-r7-20261104.tar.gz`.
- Baseline public r6 code overlay: `podkopchik-awg-stage4-r6-rollback-20261104.tar.gz`.
- `SHA256SUMS` records both hashes. Neither archive includes default UCI,
  private AWG profiles or real proxy credentials. They are not signed packages.

Final SHA256:

```text
edd0d5f89717537775009bf9f48c816fd0fec94f0f451dbcec787b0c28f21fec  podkopchik-awg-stage4-r7-20261104.tar.gz
ebf0a31f0ae76516a0e7086e63ae281be70f73e5b427bbe01d3cb9f746cec5a3  podkopchik-awg-stage4-r6-rollback-20261104.tar.gz
```

The r7 extracted critical files and deployment helpers were compared byte for
byte with the final source. The r6 baseline core files match installed hashes.
The public r6 code overlay is **not** a canonical `--rollback` snapshot: it
contains no user state and must not be substituted for that private snapshot.

**Do not install yet.** Deployment requires separate permission and a fresh
canonical on-router snapshot of UCI, AWG profiles, active JSON, code and health
state, root-only 0600. The r6 code archive alone does not restore user config.
Keep a verified independent procd watchdog and recovery script outside the
files being replaced; follow the established Stage 4 canonical snapshot and
guarded-worker procedure in [the live report](AWG-STAGE4-LIVE-20261029.md).

Proposed order after approval:

1. Reconfirm board and SSH; compare WAN default, selected roles, checksums and
   persisted routing intent. Existing OFF is not permission to turn it ON.
2. Copy r7 overlay plus the new install/watchdog helpers; verify hashes, run
   archive/preflight checks and prepare a private canonical snapshot. Do not
   restore archive `.` or root/system-parent directory metadata.
3. Arm the matching independent watchdog; install through the guarded procd
   worker, not a bare SSH command. Existing OFF must remain OFF.
4. If intent was ON, verify a single new main Xray listener, requested/applied
   status, existing nft/FakeDNS/bypass/IP rules and actual client HTTPS before
   committing the watchdog. If OFF, verify health only, no interception/Xray.
5. Only separately approved, isolated tests may exercise all-down, nft failure,
   packet-capture leak checks and reboot. Do not create failures on the live LAN.

## Rollback Procedure

Keep SSH open. Use the **new independent watchdog saved outside the overlay**,
not the generic historical `podkopchikctl rollback` (it refuses mixed AWG):

```sh
# Only after an authorized deployment has prepared and armed this private DIR:
sh "$DIR/watchdog.sh" request "$DIR"
```

It verifies the canonical private snapshot/hash, restores code and user config,
and respects the restored routing intent. ON reapplies the old controller,
waits for a new main PID/listener and only then releases r7's owned guard.
OFF restarts without enabling routing and releases the guard. A rollback to
r6 alone cannot recognize/remove r7's guard: retain the new helper until this
verification completes. Never delete a guard merely because recovery failed.

If recovery fails, retain the snapshot, logs and guard, keep SSH and diagnose;
do not force-enable routing or flush nft. Explicit `podkopchikctl cleanup` is
an alternative only when the operator accepts direct forwarding.

Read-only post-deployment checks (do not themselves Apply):

```sh
podkopchikctl status
uci -q get podkopchik.main.routing_enabled
pgrep -a xray || true
netstat -lntp | grep -E '1053|12345' || true
nft list tables
ip route
ip rule
logread -e podkopchik | tail -80
```

No GitHub push or router deployment was performed as part of this preparation.

## Changed Files

- `root/usr/libexec/podkopchik/routing_safety.sh` (new): checkpoint, owned guard,
  listener readiness and controlled restore.
- `root/usr/bin/podkopchikctl`: transactional Apply/failover, runtime status,
  persisted explicit disable.
- `root/etc/init.d/podkopchik`: guarded startup/stop, nft failure handling,
  recovery and verified new core readiness.
- `root/usr/libexec/podkopchik/awg_cli.uc`: restore only referenced AWG runtime.
- `root/usr/libexec/podkopchik/health_check.sh`: private separated diagnostics,
  cleanup and synchronous failover acknowledgement.
- `tools/awg-stage4-install.sh`, `tools/awg-stage4-watchdog.sh`: preserve OFF,
  recover old code/config, release guard only after readiness.
- `uninstall.sh`: remove only the owned guard before deleting the helper.
- `Makefile`: package revision 4; no dependency or engine change.
- New `tests/safe_apply_smoke.sh`, `tests/startup_safety_smoke.sh`,
  `tests/health_diagnostics_smoke.sh`.
- Updated `tests/health_check_cleanup_smoke.sh`,
  `tests/xray_instance_restart_smoke.sh`, `tests/awg_stage4_admin_smoke.sh`.
- `README.md`, `docs/SPEC.md`, `docs/ACCEPTANCE.md`, this report: behavior,
  evidence, verification limits, deployment and rollback.
