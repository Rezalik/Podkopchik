# UDP Reply-Cache Root Cause And Full-Cone-Preserving Candidate

Date: 2026-11-05, Europe/Moscow. Approved device only: Xiaomi Redmi AX6000,
board `xiaomi,redmi-router-ax6000-stock`, OpenWrt25.12.6/kernel6.12.112.
`openwrt2` was never accessed. No main core switch, Apply, firmware/package
installation, role/rule/network/SSH change or reboot was performed.

## Scope And Decision

**Prepared, not deployed as the main core.** Option A is selected for this
repair: fix the lifetime of Xray's transparent UDP response sockets while
preserving full-cone, FakeDNS and the tested routing architecture. The earlier
cone-disabling init candidate was removed before deployment. The existing
16384FD limit is not increased and no periodic restart or threshold kill exists.

Option B, AWG-only without Xray, remains research, not a hidden/nonworking UI
mode. Its equivalence has not been established and dnsmasq on the device
explicitly reports no-nftset. See [the full coreless assessment](AWG-ONLY-WITHOUT-XRAY.md).

| Requirement | A: bounded Xray reply cache | B: native AWG forwarding |
| --- | --- | --- |
| Current domain/FakeDNS distinctions | Retained, isolated real-core test | Real-IP sets cannot distinguish conflicting shared-CDN targets |
| IP/CIDR and LAN rules | Existing generator/data path unchanged | New nft classification/precedence/connection marking required |
| AWG main/backups/health | Existing interfaces and controller retained | Reuse health but replace its runtime apply/failover publication |
| Fail-closed | Existing terminal AWG policies and guards retained | New forwarding/NAT/fw4 guards and transition proofs required |
| Unmatched/direct and endpoint bypass | Unchanged | Feasible, but exact exclusions/DNS/bootstrap semantics need tests |
| DNS/FakeDNS | Existing mapper preserved | Need capable resolver/sets or a separate bounded FakeIP translation engine |
| IPv6 | Existing opt-in gate remains off on this device | Separate classification, NAT/routing and failure gates required |
| Maintenance | Small downstream MPL core patch, port/test each upgrade | New DNS/kernel controller plus cache/TTL/CNAME/mark lifecycle |

Native routing could avoid per-flow userspace sockets, but it still has kernel
conntrack state. It is not proved to be equivalent or more stable here. DoH,
DoT, cached answers, CNAME/CDN TTLs, shared IPs, per-device policy and IPv6
complicate real-IP sets. Fake addresses must never be routed without a component
that recovers the domain and performs real-destination/reverse translation.
Replacing dnsmasq or silently relaxing these semantics is outside this fix.

## Current Device Evidence

Profiles/roles were read from the device, not restored from historical names:
three enabled AWG connections, one main, one backup1 and one rules-only;
no VLESS. The automatic group's primary/backup references agree with those roles.
The main process is PID3371 after a device boot during the earlier pause.
Early samples in this task were11919 and12213FD, with limit16384. The initial
morning series1823->10556FD/UDP1116->9796 belongs to the preceding PID24190 and
must not be treated as continuous across the reboot.

UDP interception ON, IPv6 OFF, FakeDNS/hijack ON. Installed generator/AWG helper/
nft application/init matched local pre-candidate hashes. Transparent dokodemo
accepts TCP+UDP, DNS uses its separate1053 listener/NAT redirect, and marked
freedom outbounds use the existing AWG interfaces. Unmatched traffic can enter
Xray and then go direct. No malformed timeout or invalid JSON was found.

The earlier inode-matched sample had9905UDP sockets,9874 bound to foreign public
IPv4 addresses/ports rather than router/AWG addresses. Only11 bindings were
in the fake pool. Most had no current conntrack endpoint match. These shapes
match transparent response sockets, not one new UDP resolver socket per DNS
question or the kernel AWG outer transport. Ports6881/51413 were common but do
not prove which application/client caused the churn. Per-FD creation and last
packet times are not available from these procfs snapshots.

## Reproduced Mechanism, Not Just Correlation

Version-pinned upstream
[PacketWriter](https://github.com/XTLS/Xray-core/blob/v26.3.27/proxy/dokodemo/dokodemo.go)
retains a map of one FakeUDP reply socket per observed response endpoint until
the complete writer closes or an individual send fails. The
[worker](https://github.com/XTLS/Xray-core/blob/v26.3.27/app/proxyman/inbound/worker.go)
normally shares a cone association across destinations of the same source.
Any traffic can refresh that parent's activity; the120s inactive-association
cleanup and the default300s freedom idle policy cannot expire old entries
inside a continuously active parent. The same reply-map mechanism was checked
in v26.10.31. A stock update is not demonstrated to remove it.

The same Linux ARM64 test fixture exercised original and patched PacketWriter/
FakeUDP code on AX6000. It used only127/8 socket addresses,576 sequential replies
across three rounds of new peers, a1024FD child limit and45s test timeout.
It created no route/interface/nft state and never used the production listener.

| Core implementation | Round1 FD | Round2 FD | Round3 FD | FD after writer close |
| --- | --- | --- | --- | --- |
| Stock26.3.27 | 199 | 391 | 583 | 7 |
| Stock26.10.31 | 199 | 391 | 583 | 7 |
| Patched, either tested core | 135 | 135 | 135 | 7 |

All576 payloads and response source IP/ports were checked, not just send success.
The patched default source was recreated after eviction. A separate kernel
test kept the parent busy with a hot peer: the cold response socket retired at
120.0s, its default source could be recreated, and the final FD count returned
to7. No shortened production timer or cone-disabling environment was used.

This proves the unbounded reply-map mechanism and its bounded replacement in
the real component. The live binding/cohort evidence strongly attributes the
observed accumulation to that mechanism; it does not classify every main-process
FD or prove that all other resource problems in Xray are impossible.

## Implementation

`patches/xray/` extracts PacketWriter and adds an owned128-entry LRU reply cache,
120s per-entry idle expiry and30s sweep. Socket replacement closes before
allocating, preserves IP/port/mark and never changes the outbound receive socket,
cone association key or routing decision. Expired/evicted peers are recreated
when needed, including packets without source metadata/default-source replies.

Mutex-protected entry ownership prevents use-after-eviction/double-close and
resurrection after Close. In-flight writes are not evicted. Kernel writes do
not hold the cache mutex, so shutdown can close a socket to interrupt a blocked
write. The timer stops for an empty/closed cache. LRU expiry examines only the
old tail rather than scanning every fresh entry on every packet.

This bounds reply FDs per writer, not all process FDs. Genuine large numbers
of active UDP sources/TCP sessions can still consume resources. New-source
flood control, performance under extreme churn and multi-hour production
acceptance are not implied by the cache budget.

The application accepts an explicitly approved local core through its existing
managed update/rollback path. Root stages a regular single-link executable in
a private owned directory and supplies a separately reviewed SHA256. ELF,
active config and patch build marker are validated before selection. Package
files are not overwritten. The `local` selector and `udp_reply_cache` diagnostic
are visible in LuCI, but no local upload/channel/write ACL is exposed there.
Stock updates carry a warning that they remove the patch. The marker is build
metadata, not a cryptographic signature or an official OpenWrt endorsement.

## Isolated Functional Evidence

A separate latest-core process used private loopback SOCKS/DNS/API listeners
and the current AWG outbounds/domain/IP rules. It had a fixed overall deadline,
CommandContext cleanup and Linux Pdeathsig/SIGKILL while its supervisor's OS
thread was pinned. Every listener was inode-matched to that child before use.
Its private config/logs stayed on the router and were deleted after the test.

- DNS UDP and TCP returned the child's FakeDNS IPv4 pool.
- YouTube, Instagram and Telegram public HTTPS returned200 with certificate
  verification; this is reachability, not authenticated apps or video playback.
- Each of the three current AWG outbounds passed HTTPS to the pinned1.1.1.1
  address with SNI`one.one.one.one`; domain requests had AWG access records.
- FakeDNS metadata-only recovery, with TLS/HTTP sniffing disabled on that test
  inbound, returned HTTPS200 for YouTube.
- A test-only blackhole outbound blocked HTTPS. This is not an AWG-down WAN
  packet capture or a claim about all fail-closed transitions.
- Telegram149.154.167.41:443 accepted a TCP connection through the isolated core;
  no Telegram credentials or authenticated client were used.
- Both actual active JSON and a synthetic mixed VLESS/Reality/AWG/FakeDNS JSON
  passed the new Linux core's `run -test`. Real VLESS was SKIPPED: no profiles.

One initial control assertion failed because literal-IP HEAD `/cdn-cgi/trace`
returned302 rather than200. A direct bounded control confirmed302. The final
probe uses the existing production probe's correct SNI/pinned address and a
bounded GET; all three AWG checks then passed. This was a test-fixture error,
not a tunnel/configuration change, and is not hidden as a first-run PASS.

SKIPPED: authenticated YouTube/Instagram/Telegram, real QUIC/HTTP3, LAN source
identity tests, IPv6-capable tunnel tests, physical AWG failure/return, exhaustive
WAN/DNS leak capture and multi-hour comparable-load observation. No tcpdump/
namespace tools or additional packages were installed to manufacture a PASS.
Existing source/IP/LAN/mixed-failover tests remain mocked/native-config gates.

## Reproducible Build And Release Boundary

Host-only build instructions and source hashes are in
[patches/xray/README.md](../patches/xray/README.md). Go1.27.3 is required for
v26.10.31; Go1.26.10 for the earlier core. There is no router Go/Node/Python
installation. Builds pin source SHA, toolchain, checksum database and ARMv8.0,
verify Go modules, use trimpath/no VCS/no build ID, run race tests and emit
`SOURCE.json`, MPL license/source files and `SHA256SUMS`. Repeated clean-source
builds of the same candidate must have identical core SHA256.

Artifacts live in ignored `.build/xray-udp-v26.10.31/release/`; they are locally
built unsigned core files, not an APK or official release. Native signed SDK APK
build/install is SKIPPED on this macOS host without a Linux SDK/signing setup.
Do not use `--allow-untrusted`, `--force` or call a local signing key official.
Private router backups and build trees are explicitly excluded from Git.
No commit, push or GitHub release is authorized by this checkpoint.

## Future Deployment And Recovery

No production selection happened during the isolated tests. A global pilot
still needs an approved independent recovery arrangement and acceptance window.

1. Save fresh current UCI/AWG/code/core selector and working JSON/nft checkpoints
   privately on the device. Do not restore historical VLESS profiles/roles.
2. Review the build inputs/source and expected binary SHA on the workstation.
   Atomically install only the reviewed application helpers needed for `local`
   source support, preserving current settings and the old executable/selector.
3. Stage the verified binary, then use the existing serialized manager:

```sh
mkdir -p /tmp/podkopchik/xray-local
chmod 700 /tmp/podkopchik/xray-local
# Put only the reviewed xray executable here using the approved transfer.
podkopchikctl xray-install local REVIEWED_BINARY_SHA256
podkopchikctl xray-status
```

4. An independent watchdog must be able to restore BOTH original helpers and
   executable/selector if SSH/worker dies. Keep the routing guard and terminal
   AWG policies until a new main listener/real probes are verified. An existing
   explicit OFF must stay OFF; the manager refuses to enable routing for updates.
5. Verify new main executable/build/FD limit and unchanged UCI/roles/rules/nft/
   default routes; measure FD/UDP/RSS under the old workload for at least the
   previous5.5h window and an idle period. Require retirement/plateau, not just
   absence of EMFILE. Test real full-cone apps, failover and protected WAN capture.
6. On regression, `podkopchikctl xray-rollback` restores the retained old core.
   If helpers/startup are broken, independent recovery restores their saved
   copies and the exact prior selector/executable, validates and starts it under
   the guard before release. A config-only restore cannot revert a binary change.
7. Recheck recovery, repeated Apply and cleanup in an isolated network. Restoring
   an old stock core may reintroduce accumulation. Do not implement scheduled
   restarts or silently raise the FD cap to hide it.

Do not paste the symbolic SHA placeholder literally or install an unreviewed
binary. Application updates alone do not install the custom core. A sysupgrade
can require explicit reinstallation/reselection of the managed local core;
private configuration preservation is not binary-patch preservation.

Before downgrading application helpers to a version without the `local` selector,
first restore the old core with the current manager and verify it. Alternatively,
restore the saved helpers, selector AND executable together under the independent
guard. An old selector helper alone cannot start a `selected=local` core.

## Final Verification Checkpoint

At 2026-11-05 21:48:24 MSK (18:48:24 UTC), the original main PID3371 still ran
with 12670FD/16384. These values fluctuate with live traffic; they are not a
production measurement of the patch. Its earlier samples11919/12213/12777 and
the original incident remain evidence that the unpatched process needs a
guarded pilot, not another limit increase.

The final Linux ARM64 v26.10.31 core SHA256 is:

```text
f8ba3bf3c5023817ad0cd413e1f44324d5a9c9d7aba806663e9ed63b418858c8
```

Repeated clean-source builds produced this same hash. The final hashed binary
and its matching test executable were rechecked on the Xiaomi: both JSON tests,
576-reply churn, actual120s idle cleanup and the isolated AWG/DNS/HTTPS tests
passed. The test directory and child processes were removed after completion.

The same final patch also builds against the installed v26.3.27 base, with
race tests and module verification passing. Its core SHA256 is
`f9fd8632e0a8e651fcfb5d5f1de9288e163c5ffff09da6a38d7fccfd064b75a0`;
artifacts are in `.build/xray-udp-v26.3.27/release/`. The final full v26.3.27
binary has not been selected or run on the router; earlier component tests
covered that upstream base. An eventual first pilot can retain this base to
separate the cache repair from unrelated upstream upgrades, but must still
validate the actual candidate/config and pass every live gate. The final
real-router full-core checks above refer specifically to v26.10.31.

Final local checks:

- 17 JavaScript smoke suites PASS, including native file-backed mixed generator,
  routing-model/failover tests, UI rendering, i18n coverage and real LMO decoding.
- 32 shell smoke suites PASS. Four generator wrappers SKIPPED because native
  UCI/jsonfilter are not installed on the Mac; the separate native file-backed
  generator suite and actual-router JSON validation are not those wrappers.
- Six reply-cache cases passed ten race-enabled runs per pinned core build.
- Shell/JavaScript parse, JSON, `msgfmt -c`, deterministic real-LMO rebuild,
  Markdown links/fences and `git diff --check` PASS.
- One shell rerun initially used a nonexistent workstation Xray path. With the
  actual private `macos-core/xray` path, the real-core syntax smoke passed;
  no router configuration was changed to address that runner error.

Post-test SHA comparisons confirmed byte-identical Podkopchik UCI, active JSON,
network/wireless/firewall/dropbear configuration, init/generator/nft helper,
Podkopchik nft table, IPv4 policy rules and IPv4/IPv6 main routes. No lab process
remained. The existing main core, package version and FD limit were unchanged.
Build/private-backup trees are ignored; the publication source set was checked
for private key blocks, AWG key assignments and sensitive VLESS links.

This checkpoint is **ready for review and an approved guarded pilot**, not a
claim that the installed production core is fixed. Multi-hour live acceptance,
real application/QUIC/full-cone behavior, AWG failure/return with protected WAN
capture, and a signed SDK APK remain SKIPPED. No Git commit/push/release or
production core installation occurred.

## Publication File Inventory

- Core overlay/probes: all eight files under `patches/xray/`.
- Host build: `tools/build-xray-udp-cache.sh`; ignored artifact/private trees
  are declared in `.gitignore`.
- Manual selection/status: `root/usr/libexec/podkopchik/xray.sh`,
  `root/usr/libexec/podkopchik/xray_update.sh`, `root/usr/bin/podkopchikctl`.
- Read-only UI diagnostics: `root/www/luci-static/resources/view/podkopchik/updates.js`,
  `po/ru/podkopchik.po`, `i18n/ru/podkopchik.ru.lmo`.
- Regressions: `tests/xray_update_smoke.sh`, `tests/xray_updates_ui_smoke.js`,
  `tests/xray_udp_session_smoke.sh`, `tests/startup_safety_smoke.sh`,
  `tests/xray_instance_restart_smoke.sh`.
- Documentation: `README.md`, `docs/SPEC.md`, `docs/ACCEPTANCE.md`, this report,
  `docs/AWG-ONLY-WITHOUT-XRAY.md`, `docs/XRAY-FD-20261105.md`,
  `docs/XRAY-UDP-RETENTION-20261105.md`.
- `root/etc/init.d/podkopchik` retains the earlier approved16384FD capacity
  change already deployed on this router. The withdrawn cone-disable candidate
  adds no environment workaround to this final diff.

The generator, nft application/cleanup, DNS/FakeDNS, health/failover and
persistent default UCI model have no changes in this publication candidate.
