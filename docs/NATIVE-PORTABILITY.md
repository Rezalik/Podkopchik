# Native Portability: Ten Stages

Work branch: `feature/universal-routing-engine`. Stages 1-8 cover local
implementation and isolated verification. They do not deploy anything to
either router, change live routing, or declare the Native RC stable.

## Roadmap

| Stage | Deliverable | State |
| --- | --- | --- |
| 1 | Shared preliminary requirements and read-only compatibility report | Complete, diagnostic only |
| 2 | Separate common LuCI/coordinator files from architecture-specific helper | Implemented |
| 3 | Platform-aware package manifests, builds and release assets | Implemented; Flint lab only |
| 4 | Installer/updater admission using the shared compatibility contract | Implemented; no activation |
| 5 | Per-router LAN, profile, namespace, address and port inventory | Implemented; read-only |
| 6 | Validated Legacy-to-Native transition with ordinary transactional confirmation | Implemented |
| 7 | LuCI compatibility, refusal explanations and compatible update selection | Implemented |
| 8 | Automated platform, package and network acceptance matrix | Implemented, isolated lab only |
| 9 | Separately authorized Flint 2 installation and physical acceptance | Native confirmed; primary IPv4 LAN accepted, backup not accepted |
| 10 | Public RC, support matrix, documentation and known limitations | Not started |

## Stage 1 Contract

`root/usr/libexec/podkopchik/native_platform.uc` is a pure assessment module.
`native_platform_check.uc` collects a bounded, non-secret inventory and prints
one JSON report. Stages 2-5 reuse its collector and assessment in the package
gate, but no Apply, service or LuCI path invokes the diagnostic CLI.

Input/output `schema` is 1. Assessment has three possible results:

| Status | Exit | Meaning |
| --- | --- | --- |
| `requirements_met` | 0 | Every preliminary observation is present and satisfies this baseline |
| `blocked` | 2 | At least one known requirement fails; unknown observations remain listed |
| `incomplete` | 3 | No known failure, but required observations are missing or malformed |

Usage/parse/runtime errors are nonzero and are not compatibility results.
Consumers must parse `status`; exit 0 is **not** installation authorization.
Every report sets `installation_authorized=false`, `activation_authorized=false`
and `physical_acceptance=not_assessed`, including reports for Xiaomi.

`current_candidate.board_guard` is a separate `match` / `mismatch` / `unknown`
observation for the original AX6000 package. It is not an installability check.
Flint 2 can satisfy preliminary requirements while this field is `mismatch`.
An unknown board with matching capabilities is not automatically certified.

## Initial Baseline

The first deliberately narrow baseline is `filogic-arm64-25.12.6-v1`:

- OpenWrt 25.12.6, `mediatek/filogic`, `aarch64_cortex-a53`, Linux `aarch64`.
- Kernel 6.12.112; other releases/kernels are unvalidated, not silently admitted.
- Required commands: ip-full, nft, fw4, ucode, uci, ubus, jsonfilter,
  sha256sum, curl, dnsmasq, Xray, rpcd and uhttpd.
- A previously verified schema-3 Native helper with bounded-command support,
  installed or staged from the verified package; no helper is installed here.
- Configured software/hardware flow offloading disabled, zero live flowtables,
  and an active `inet fw4` table.
- At least 96 MiB available RAM, 64 MiB free tmpfs and 24 MiB free overlay.
- For `--awg`, AmneziaWG tools 3.1 and an already loaded matching kernel module.
  Without `--awg`, no AWG installation or module is required by this assessment.

These are preliminary floors. Exact archive expansion, helper size, retained
generations, profile snapshots and recovery reserves still require admission
for the particular package and configuration. No kernel expression, profile,
DNS, HTTPS, UDP, QUIC, throughput, failover or long-session acceptance is claimed.
An installed command alone does not prove all its required features work.
Existing Legacy support is unchanged; this baseline does not admit Native on
OpenWrt 24.10 or other processor architectures.

## Read-only Use

From a matching source tree in an OpenWrt VM with ucode modules:

```sh
ucode -L root/usr/libexec/podkopchik \
  root/usr/libexec/podkopchik/native_platform_check.uc \
  --fixture tests/fixtures/native-platform-flint2.json
```

On a system where these diagnostic files have been separately installed:

```sh
ucode -L /usr/libexec/podkopchik \
  /usr/libexec/podkopchik/native_platform_check.uc --awg
```

This is not an instruction to install the AX6000 package on Flint 2. Stage 1
does not install the diagnostic on either physical router. `--fixture` is
explicitly labelled `source=fixture`; it does not read the running machine and
cannot be combined with `--awg`. The fixture is public, synthetic test data,
not a backup or evidence of physical Native operation.

Live collection reuses the existing Native helper's bounded executor (4 seconds
per command) and a 64 KiB output limit per command. The default helper is
`/usr/libexec/podkopchik/podkopchik-native-dns`. `--helper ABSOLUTE_PATH` can
select a root-owned, non-writable executable staged from a separately verified
package; checksum/provenance verification must happen before executing it.
File permissions and reported capabilities are not a package signature.
Missing helper/binaries,
failed nft queries, unreadable firewall defaults and invalid data remain
unknown or failed; they are never converted into a success. Release metadata
is parsed as data, never sourced as shell code. Duplicate release keys are
ambiguous and rejected. No root escalation or package-manager command occurs.

The report contains board/release identity and scalar capability/resource
observations. It does not read proxy URIs, AWG keys, client DNS queries, packet
captures, logread or emergency state. It never changes UCI, nftables, routes,
interfaces, services, firmware or installed packages. It does not create state,
backups, locks, an emergency capsule or a watchdog.

A fresh Legacy router such as the current Flint 2 has no Native helper yet.
Without a verified staged helper, live collection reports an incomplete
inventory instead of running unbounded commands or installing a timeout tool.
The public fixture exercises the assessment without this live dependency.
Verified staging and invocation by the new bundle installer are separate.

## Stages 2-5 Contract

- `tools/stage-native-common.sh` stages LuCI, UCI defaults and coordinator
  scripts without building or including a helper or pinned launcher. The full
  archive adds the immutable ARM64 binary and its generated launcher.
- `native-targets.json` identifies the only two candidate targets, AX6000 stock
  and Flint 2. `PLATFORM.json` schema 2 binds one board, the complete OpenWrt
  baseline, asset name, helper ABI/capabilities and component SHA256 digests.
  `COMMON_SHA256SUMS` covers common root/i18n content without the launcher.
  The old TARGET marker/name for AX6000 remain compatible with its old reader.
- The updater selects only the matching asset, verifies the GitHub SHA256 and
  archive/manifest, then checks the package with the installed policy. The
  static installer repeats device and prerequisite admission before writes.
  Old v1 archives are usable as verified unchanged-helper build inputs, not
  as updates through the new gate. Missing evidence is a refusal. No package
  manager, emergency mechanism, restart or Apply is invoked.
- The helper is additive; launcher publication is part of the compensating
  static file transaction. Existing UCI, AWG profiles and issued-address
  state are not migrated or replaced. Apply and its validation stay separate.
- The Flint bundle is a CI lab artifact, not a published release asset. The
  existing prerelease job only publishes the AX6000 asset. Do not install
  either lab result until a separate maintenance window is approved.
- `native_inventory_check.uc` is a standalone read-only report. It reads
  the configured LAN, enabled VLESS/AWG profiles, numeric endpoints and
  exclusions, previously issued namespaces, local addresses/routes/RPDB,
  existing Native nft tables and socket occupancy. It emits issue codes
  and counts, not profile identifiers, endpoint hosts, addresses or keys.
  It does not resolve DNS, bind ports, acquire a profile write lock, allocate
  a namespace or invoke Apply. Existing resources may be ours; they require
  ownership review, not deletion. A clean snapshot is not authorization.

The inventory uses the installed bounded helper by default, or a verified
staged executable with `--helper ABSOLUTE_PATH`. An incomplete snapshot, a
named endpoint, or an existing reservation can produce `review_required`
(exit 2). A clean snapshot produces `no_observed_conflicts` (exit 0). Actual
profile validation, DNS bootstrap, ownership and kernel admission still
belong to the explicit transition.

## Acceptance

- Pure model and parsers: `tests/native_platform_smoke.uc`.
- Actual fixture CLI and argument rejection: `tests/native_platform_smoke.sh`.
- Live collector and helper admission, with unchanged UCI/nft in a disposable
  no-NIC VM: `tests/native_platform_vm_smoke.sh`.
- Workstation privacy/read-only/unchanged-guard assertions:
  `tests/native_platform_contract_smoke.js`.
- Mac without native ucode must report the ucode test SKIPPED. Real execution
  is required separately in an isolated OpenWrt VM; JS source assertions do
  not substitute for executing ucode.
- Full installation and network acceptance are outside stage 1. Stage 9 needs
  a new explicit maintenance authorization; no automated rollout is enabled.

## Stages 6-8

1. Keep Legacy selected. Save the LAN, pool, policy, rules and profiles in LuCI.
   **Advanced > Legacy to Native migration** runs a read-only board/firmware,
   helper, resources, offload and (when needed) AWG readiness check. Refusals
   report check IDs and statuses without exposing profiles or endpoints.
2. **Validate migration** compiles a candidate from saved settings and checks
   the kernel rules, UCI/profile/namespace inventory, Xray if needed, protected
   DNS configuration, port occupancy and Legacy routing ownership. It never
   activates the candidate or reserves a synthetic namespace. It can use
   bounded DNS bootstrap to validate configured endpoints.
3. **Migrate to Native** requires a separate explicit action. It repeats
   validation and arms the standard confirmation deadline. Check DNS and
   internet access from the intended LAN before confirming on **Status**.
   Before any cutover on the same boot, abort can retain untouched Legacy and
   restore its engine/enabled/routing flags. After cutover begins, first-trial
   abort/expiry goes to protected Native recovery, not unrestricted Legacy.
   Later failed Applies restore the last confirmed Native generation.
4. Native Updates displays the selected board asset and disables installation
   when no matching release is available. The server independently reselects
   and verifies the exact archive and still requires confirmed active Native
   for static installation. No source/other-board fallback is used.

Equivalent root commands: `podkopchikctl native-migration-readiness`,
`podkopchikctl native-migrate-check`, and `podkopchikctl native-migrate`.
Readiness is read-only; candidate validation and activation have separate
write ACL entries. Neither validation nor activation invokes an independent
emergency capsule.

### Matrix

- Workstation: `sh tools/check-native-local.sh` runs LuCI action and ACL tests,
  package contracts, shell/JS syntax, JSON validation and translation checks.
- Guest: `sh /mnt/lab/native-portability-matrix-vm-test.sh` combines the
  platform/manifest and static update fixtures with the permanent whole-LAN
  suite in a no-NIC ARM64 OpenWrt guest. It reports each group separately and
  returns nonzero if any group fails. Prepare the read-only share with the
  candidate archives and fixtures used by `native-portability-vm-test.sh`
  and `native-update-vm-test.sh`, and the verified test binaries and sources
  expected by `native-dns-vm-test.sh`. The guest needs matching iproute2,
  veth/tproxy, curl and tcpdump already available; the matrix installs no
  packages. The runtime fixture enables Strict explicitly; the separate
  classification suites cover selective behavior.
- VM routing uses local namespaces and virtual links. The actual VM identity
  is refused by the production gate. Runtime tests enter the existing
  QEMU-only namespace path. None of this substitutes for real Flint boot,
  WAN/Wi-Fi, AWG module, upstream QUIC or long-duration acceptance.

Stage 6-8 workstation verification: 55 PASS, 23 SKIPPED (missing local
dependencies or VM requirements), 0 FAIL. The ARM64 guest separately passed
the platform/manifest gates, static update, classification, first-trial abort,
confirmed migration, Legacy resource ownership checks, and dual-stack
HTTPS/UDP/QUIC on the virtual AWG paths. Injected nft failure recovered the
confirmed generation on a separate run with a longer VM test wait. A
separate real 60-second confirmation timeout also restored the previous
generation and its DNS answer; the expired token was rejected.

The full mixed AWG/VLESS scenario is not accepted: IPv4 HTTPS succeeded, but
IPv6 HTTPS hit the three-second fixture deadline. The cause is unconfirmed.
Do not infer a physical VLESS/IPv6 or QUIC result from these tests.

## Stage 9 Read-only Preflight

- Connected to `flint2` over the local LAN with strict verification of the
  existing SSH host key. The live board is `glinet,gl-mt6000`, OpenWrt 25.12.6
  / mediatek/filogic / aarch64_cortex-a53, kernel 6.12.112. The verified Flint
  archive matches this identity. AX6000 was not contacted.
- ip-full and the required commands were present. AmneziaWG tools 3.1 and
  its loaded module were present. Both offload options were unset, no live
  flowtable was found, and firewall4 was active. Available RAM was about
  824 MiB, with about 491 MiB free tmpfs and 7.0 GiB free overlay.
- The active nft table and saved intent are Legacy. Native helper, generation
  and configured synthetic pools are absent. Legacy FakeDNS is enabled. The
  saved configuration has one enabled AWG and two enabled VLESS profiles;
  the automatic group uses AWG as primary and VLESS as its first backup.
  No profile identifiers, endpoints or credentials were collected.
- The static destination check found 17 of 68 paths rejected by the
  installer's ownership/mode rule: existing root-owned, single-link package
  files with modes `0664` or `0775`. This affects LuCI views, its ACL and menu
  metadata, the AWG RPC executable, and the AWG upgrade-keep file. This is
  distinct from the older directory-permission issue. No files were changed.

### Stage 9 Static Installation

After the owner's explicit approval, the existing static files were backed
up privately and matched again on the router before writes. Corrected only
the 17 audited modes to `0644` or `0755` as appropriate. The verified Flint 2
archive passed the board and installer checks; all 68 destinations matched
the archive and the installed immutable helper reported capability schema 3.

Settings, AWG profile files, generated Legacy configuration, service PIDs,
boot identity, default routes, RPDB and the Legacy nft table matched before
and after. There was no Apply, restart, reboot or emergency activation.
`validate-active` passed and the running engine is still Legacy. From the
Flint LAN, YouTube and example.com answered DNS UDP/TCP and both HTTPS
responses completed with HTTP 200 and TLS verification success. Both DNS
answers were synthetic; this is not a Direct-path or Native test.

Immediately after static installation the new status reported
`Synthetic IP protection: incomplete`. Its separate
guard ledger, nft table and policy rules were absent at the read-only check.
The installation did not initialize the guard or change routing. Native
readiness reported only `pool_required`, not readiness to migrate.

### Stage 9 Native Migration

After a separate request to finish the migration, tested a temporary copy of
the saved configuration against the live kernel and confirmed that pinned
protected DNS answered through the existing AWG. The candidate selected the
non-overlapping IPv4 pool `100.127.224.0/20` and Compatible selective routing
without migration restriction. No IPv6 synthetic pool was added; the router
had no IPv6 default route and Legacy IPv6 interception was off.

After a private Legacy backup and validation of the saved candidate, the
ordinary 300-second transactional trial switched the Flint LAN to Native.
Confirmed only after the following LAN checks:

| Check | Result |
| --- | --- |
| Native readiness, active primary AWG, no pending trial after confirmation | PASS |
| YouTube DNS over UDP/TCP, eight Native synthetic answers in each mode | PASS |
| YouTube HTTPS, full body, HTTP 200 and TLS verified | PASS |
| example.com ordinary IPv4 DNS over UDP/TCP and full HTTPS body, HTTP 200 and TLS verified | PASS |
| Active configuration validation and synthetic guard | PASS; old and new pools quarantined |
| Existing UCI rules, transport roles and AWG profile bytes | Preserved |
| Firewall UCI | Only the two owned Native includes were added |
| VLESS backup, physical failover, IPv6 forwarding, QUIC and long-duration stability | Not accepted |

The configured VLESS backup was down before migration and reported unknown
in the post-confirmation snapshot. It was not disabled or reconfigured; no
forced failover was performed. The separate emergency mechanism was not
started or initialized. This is physical acceptance of the primary IPv4
path on this Flint only, not general device support or a release.

The existing residual Instagram pauses, unresolved PS Store issue, mixed
five-segment Xiaomi observation and unverified QUIC/long-UDP scenarios remain
known limitations. A platform inventory PASS does not resolve them.

## Stage 1 Verification: 2026-11-10

| Check | Result |
| --- | --- |
| Pure assessment and parsing in actual ARM64 OpenWrt 25.12.6 | PASS: 90 assertions |
| Actual CLI fixture source, exit 0/2/3, missing helper and invalid arguments | PASS in isolated VM |
| Live collector using an existing verified helper staged in VM tmpfs | PASS; virtual platform correctly refused |
| Firewall UCI hash and nft ruleset before/after live collection | PASS: unchanged |
| Symlink or group/world-writable helper | PASS: rejected, no compatibility success |
| Workstation contract/privacy checks and original AX6000 guards | PASS |
| Full workstation smoke run | 76 suites: 53 PASS, 23 SKIPPED, 0 FAIL |
| Shell syntax, LuCI JS syntax, JSON, translation and diff whitespace | PASS through tools/check-native-local.sh |
| Native installation or new diagnostic deployment on Flint 2 | SKIPPED: not authorized/performed in stage 1 |
| New architecture compilation, package release, Apply and physical network acceptance | SKIPPED: later stages |

The Mac has no native ucode. Both new shell tests therefore remain explicitly
SKIPPED in the workstation run; their actual model/CLI/live-collector behavior
was exercised separately in a disposable no-NIC VM with read-only host share,
no disk and only guest-tmpfs test writes. The VM was powered down afterward.
The staged helper was reused for testing, not rebuilt or installed on a router.
No commit, push, release publication, package-manager invocation, production
service restart, configuration migration or Xiaomi access was performed.
