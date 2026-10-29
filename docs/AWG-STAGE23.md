# AmneziaWG 3.1: Experimental Stages 2–3

## Scope And Safety

Local implementation baseline: Git `5a7becc12697e04aacf4033b6deb0eb7ae89b3b6`.
Only Xiaomi Redmi AX6000 stock was accessed through `ssh openwrt`.
During the initial isolated work no new Podkopchik version was installed, no packages or firmware updated, and
no WAN/LAN/Wi-Fi/SSH settings changed. No router reboot or GL-MT6000 access.
Stage 1 storage/import validation remains the foundation; see [AWG-STAGE1.md](AWG-STAGE1.md).

## Implemented Model

Import multiple profiles in AmneziaWG. Start creates an isolated kernel
interface, not a per-profile daemon. Check performs pinned-IP, interface-bound
HTTPS with certificate validation and requires an actual handshake. The card
distinguishes static config validity, interface state and measured availability.
HTTPS duration is request time, not ICMP RTT. Exit IP is available when the
configured probe returns `ip=ADDRESS`; an arbitrary valid HTTPS page may not.
Latest success expires after five minutes. Counters are actual kernel transfer
values for AWG and optional loopback Xray StatsService values for VLESS, never
fabricated zero-byte results. Interface counters include AWG transport overhead.

**Connection role** assigns main, backup1–3, rules only or disabled. A main or
backup must pass a real check. Selecting a main demotes the previous main to
rules only, preserving its URI and explicit targets. Roles share the existing
auto_proxy_group and health thresholds; all transports use ordered backups,
not fastest/random selection. Domain Groups, IP Rules, LAN Devices and presets
use the same enabled `proxy` tags without a second rule engine. Plain VLESS
profiles retain their format. Disable/delete refuses referenced profiles.
The first post-boot health decision triggers an apply when backup/blocked differs
from the configured default, even if no previous group state exists.

Example (illustrative IDs, no real credentials):

```uci
config proxy 'awg_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
 option protocol 'amneziawg'
 option awg_id 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
 option tag 'awg_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
 option name 'AWG main'
 option enabled '1'
 option role 'main'
 option autostart '1'
 option probe_url 'https://one.one.one.one/cdn-cgi/trace'
 option probe_address '1.1.1.1'
 option probe_timeout '10'

config proxy_group
 option tag 'auto_proxy_group'
 option enabled '1'
 option mode 'strict_primary'
 option primary 'awg_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
 option backup1 'existing_vless_tag'
 option failure_action 'switch_to_backup'
 option auto_return '1'
```

Keys remain in protected profile revisions, never UCI/argv/RPC output.
Manual Start records autostart without selecting a routing role. Stop records
autostart0 and blocks selected AWG traffic until health failover. Service shutdown
retains desired autostart settings. On restart/reboot, enabled-but-stopped
profiles get guards and blackhole outbounds; available profiles are reconciled
before Xray starts. No replacement is allowed while a profile is running/in use.

## Isolation And Fail-Closed

- Interface: `paw` + first12 ID hex digits, max15 characters.
- Table42000–50191, priority20000–28191, mark536870912+table, protocol186.
- Every namespace is checked live; collisions fail, never overwrite a service.
- At most ten owned AWG interfaces may be started simultaneously; imports do
  not automatically create interfaces or alter LAN routing.
- `ip -N` prevents symbolic table/protocol names from breaking ownership checks.
  Numeric JSON type7 is RTN_UNREACHABLE. Alias is set **after** AWG link creation
  because the tested AWG newlink discarded the alias passed to `ip link add`.
- Mark and oif rules exist for both families with terminal unreachable defaults.
  Interface routes are lower metric in private tables only. Stop retains guards;
  deletion removes exact owned rules/routes after active references are removed.
- Address uses noprefixroute, no auto IPv6 link-local generation; overlapping
  LAN/WAN/tunnel prefixes and strict global rp_filter are refused. Shared provider
  inner addresses cannot run simultaneously: import is allowed, start refuses
  conflicting active addresses. No silent renumbering or namespace trickery.
- No awg-quick, route hooks, user FwMark, DNS mutation or new main default.
  AWG outer packets use ordinary WAN and endpoints supplement bypass sets.
- AWG freedom outbounds bind interface/mark and ForceIP. Missing ownership,
  guards or interface yields blackhole. Startup validates regenerated config;
  if regeneration fails, stale AWG freedom outbounds are replaced by validated
  blackholes instead of allowing an ignored socket-bind failure to use WAN.
- Real TCP DNS for AWG domain recovery follows the active automatic connection,
  not each profile independently. If the automatic group is blocked, the first
  enabled connection with fresh measured UP may resolve for independent targets;
  this never unblocks automatic data rules. Otherwise DNS is blocked too.
  FakeDNS is skipped for these ForceIP lookups;
  there is no system-resolver fallback. Imported DNS is stored, not applied.

The pinned Xray implementation supports per-DNS-server tags and domain priority
but has a shared DNS client. Expanding to profile-specific DNS would need separate
domain policies and FakeDNS-priority tests, especially for LAN source rules:
[configuration](https://github.com/XTLS/Xray-core/blob/v26.3.27/infra/conf/dns.go),
[selection and FakeDNS skipping](https://github.com/XTLS/Xray-core/blob/v26.3.27/app/dns/dns.go).
The conservative shared resolver is deliberate; profiles must permit the public
probe/resolver addresses, or use supported literal-IP rules and a custom probe.
- All-down automatic routing uses blocked. Unmatched traffic stays direct.
  Explicit direct, private-range and endpoint exclusions remain intentional.

Role changes use native management locks plus the shared config-apply lock, a
private token and rollback journal. Health checks skip a live role transaction;
an existing health operation makes role assignment retryable, not concurrent.
Failed apply restores UCI, active config and selection. Interrupted transactions
are recovered explicitly (Recover connection change / `podkopchikctl awg-recover`)
or before startup. The journal is in tmpfs: this is not an fsync/power-loss
transaction guarantee. After reboot the committed UCI is reconciled safely.

nft application now checks and commits a complete replacement batch atomically.
The previous table survives failed validation/commit; only policy resources
newly acquired by that invocation are undone. Successful role/failover changes
restart only Xray, preserving AWG interfaces and existing interception. Existing
TCP connections are not transparently migrated; clients must reconnect.

## UDP, IPv6 And Acceleration

The original combined `extended_interception` setting is superseded by the
independent, off-by-default `udp_interception` and `ipv6_interception` controls
in [Stage 4](AWG-STAGE4.md). Old explicit settings remain readable. UDP does not
enable IPv6 DNS or policy routing. IPv6 FakeDNS uses2001:2::/48 outside reserved6.
No UDP/443 block is added.
All selected transports must actually support these flows. The real available
AWG profile has IPv4 only; real IPv6/UDP and dual-stack DNS acceptance is pending.
No global flow-offload setting is changed. Kernel/proxy local traffic is not
equivalent to ordinary forwarded/offloaded traffic; benchmark CPU/throughput
on AX6000 before claiming hardware acceleration compatibility.

## Packaging And Approved Deployment

Dependencies for AWG runtime, in addition to normal Podkopchik dependencies:
matching `kmod-amneziawg` and `amneziawg-tools`3.1, ip-full, curl/CA certificates,
ucode fs/uci with flock, and existing nft TPROXY support. On tested device:
kernel6.12.112, kmod6.12.112.3.1.20260906-r1, tools3.1.20260812-r1,
Xray26.3.27. These optional packages are not installed by this implementation;
VLESS-only OpenWrt24.10/opkg remains supported. Do not bypass APK trust or ABI.

Native APK build needs a Linux OpenWrt25.12.6 mediatek/filogic SDK with LuCI
feeds and CONFIG_USE_APK=y. `sh tools/build-awg-apk.sh /path/to/SDK` stages only
public package sources and builds with the existing Makefile. Inspect/sign the
result using your approved SDK key. **No native APK was built on this macOS
workstation**; native-package build/install acceptance remains pending.

An alternative complete public overlay is buildable locally:

```sh
sh tools/build-awg-stage23.sh "$PWD/.router-backups/podkopchik-awg-stage23.tar.gz"
```

This is a tar overlay, **not an APK**. It excludes default UCI and private profile
storage, includes every runtime helper plus ACL/UI/catalogs and admin tools.
The old partial Stage1 bundle builder now refuses mixed code to prevent an
incomplete deployment. Source overlays do not update native package ownership.

Do not execute deployment commands until the user separately approves it:

1. Keep SSH open; compare status/config/route/nft baseline and checksum bundle.
2. Copy the preflight tool, run `sh awg-preflight.sh --check`, then
   `sh awg-preflight.sh --backup /root/podkopchik-before-awg23-deploy.tar.gz`.
   The complete confidential backup stays root600 **on the router**; never paste
   its contents or transfer keys as part of diagnostics. Include both LMO paths.
3. Inspect archive paths and verify its SHA256 against the workstation before
   extracting the approved complete overlay with `tar -xzf ARCHIVE -C /`.
   If using native APK instead, let apk handle files; do not mix deployment methods.
4. Reload rpcd, clear LuCI cache/hard-refresh, validate/generate/test Xray before
   applying. No service restart is required merely to inspect imported profiles.
5. Start/check one AWG, assign its role, then perform the live matrix below while
   monitoring SSH and the default route. Do not change WAN/LAN/Wi-Fi/SSH.

## Recovery And Uninstall

Before reverting to Stage1/older UI, explicitly choose/check VLESS main, retarget
AWG-specific domain/IP/LAN/manual-group entries, give VLESS legacy-compatible
roles (no rules_only), disable/stop AWG, and Apply VLESS-only routing. Do not
silently change rules to direct or discard newly added VLESS profiles.

`sh /usr/share/podkopchik/tools/awg-rollback.sh --check` is read-only. It refuses
enabled/referenced AWG, incompatible roles or active AWG outbounds. After it
passes, `--restore /root/PRE-STAGE23-BACKUP.tar.gz EXPECTED_SHA256` stops the
service, disposes only validated AWG ownership, removes disabled AWG UCI bindings,
restores only old public code/catalogs, validates and applies current VLESS UCI.
It **does not restore old UCI/profile files** over current VLESS additions. This
script requires a pre-Stage2/3 backup; it refuses a mixed-runtime archive.
Its full live restoration has not been exercised on the working router.
Normal CLI update/rollback refuses a target version without mixed AWG support
while any AWG UCI binding remains; the explicit preparation must happen first.
Prepared bundles/SDK builds install these admin tools; for a direct source
installation, use tools/awg-preflight.sh and tools/awg-rollback.sh from the
verified matching checkout instead of assuming the installed admin path exists.

For an interrupted role transaction use the explicit recovery control first.
Keep SSH open on rollback failure and inspect the protected on-router backup;
do not run generic route flushes, delete foreign interfaces or use --purge.
Normal uninstall stops the app and disposes owned AWG policy before removing
helpers; private profiles/UCI remain. Only explicit purge removes private data.

## Verification Evidence, 2026-10-25

**Native unit/mock integration**: strict parser/storage100 assertions; lifecycle,
ownership, alias/ifindex, policy, guards and probes; real file-backed UCI role
transactions/rollback; generated mixed domain/IP/LAN rules, fail/restore thresholds,
all-down blocking and opt-in dual FakeDNS; LuCI RPC/actions/render/i18n; atomic nft
batch/repeated apply/failure retention and extended interception. These mocks
do not prove live VPN traffic or full deployed service behavior.

**Actual AX6000 isolated tests** (not an application deployment):

- Current board/firmware/kernel rechecked: stock AX6000,25.12.6,6.12.112.
- Existing real imported profile `kaz` used only on-device, no key disclosure.
- Kernel AWG HTTPS200/TLSverify0:546.552ms; temporary Xray-to-AWG HTTPS200/
  TLSverify0:658.152ms; handshake age2s, exitIP80.90.182.238.
- New controller executed only from private /tmp sources: idempotent start,
  final measured HTTPS434ms, actual handshake/counters/exitIP, stop leaves mark lookup
  unreachable, remove deletes temporary interface and both-family policy.
- Initial testing found missing alias, numeric type7 and detached-oif JSON mismatches; fixed
  and retested. An initially retained test interface was explicitly verified
  and removed; the corrected test asserts interface and table absence.
- Synthetic mixed generated config (including stats API and dual FakeDNS)
  accepted by actual Xray26.3.27 `run -test`, without replacing active config.
- The complete replacement nft batch, including the opt-in UDP/IPv6 syntax,
  passed actual `nft -c -f` on AX6000; no batch commit was performed and the
  live Podkopchik table hash was unchanged. This is syntax/dry-run evidence,
  not real UDP/IPv6 traffic acceptance.
- Read-only compatibility preflight passed on the actual AX6000. Xray's
  statsquery --help returns usage with a nonzero status; preflight validates
  the supported command/flags rather than treating that help status as failure.
- Native router UCI/FS role/group commit, rollback and delete passed in isolated
  /tmp configdir/savedir/conf2dir, with synthetic profiles and MOCK network/apply.
  This found and removed an incorrect mock-only section() API assumption:
  production uses native set(config, name, type) plus option setters. Live UCI,
  its empty delta, active config and routes were unchanged. This is not evidence
  of a full real service apply or failover.

**Pending at the initial checkpoint, not PASS**: deployment of the new app; live mixed role changes and
failover/auto-return; all-down LAN packet leak testing; reboot restoration;
real multiple peers with non-overlapping addresses; UDP, IPv6 and acceleration;
native APK build/install and full live code rollback. A valid IPv6-capable AWG
profile and separately approved deployment are needed for that part.

The subsequent authorized [Stage4 live pass](AWG-STAGE4-LIVE-20261029.md)
closes the narrower AX6000 deployment/IPv4 UDP/AWG→VLESS→AWG gates. It does not
close the broader multi-profile, IPv6, reboot, acceleration or signed APK gates.

## Commands After Deployment Approval

```sh
ubus -v list podkopchik.awg
podkopchikctl awg-list
podkopchikctl awg-start PROFILE_ID
podkopchikctl awg-check PROFILE_ID
podkopchikctl generate
xray run -test -config /etc/podkopchik/config.generated.json
podkopchikctl validate
podkopchikctl status
ip -N -4 rule show
ip -N -6 rule show
ip -4 route show table main
ip -6 route show table main
nft -s list table inet podkopchik
pgrep -a xray
nslookup -port=1053 x.com 127.0.0.1
```

Select roles through authenticated LuCI, not manual UCI edits. With a LAN test
client, independently verify domain/IP/device-specific VLESS and AWG targets,
unmatched direct traffic, preserved endpoint bypass, main failure/backup order,
all-down blocking and threshold-based return. Capture WAN to check for leaks,
including DNS; record current connections vs newly opened connections. Repeat
Apply, stop/start service, then separately approve a reboot recovery test.
Never print `awg showconf`, raw `.conf`, UCI VLESS URI or private backup contents.

## Local Check Commands

```sh
sh tests/awg_model_smoke.sh
sh tests/awg_integration_smoke.sh
sh tests/awg_interception_smoke.sh
sh tests/awg_admin_smoke.sh
sh tests/awg_packaging_smoke.sh
node tests/awg_generate_smoke.js
node tests/awg_rpc_smoke.js
node tests/awg_ui_smoke.js
node tests/status_speed_limits_render_smoke.js
node tests/i18n_coverage_smoke.js
node tools/po2lmo.js po/ru/podkopchik.po i18n/ru/podkopchik.ru.lmo
node tests/lmo_catalog_smoke.js
msgfmt -c po/ru/podkopchik.po -o /tmp/podkopchik-ru.mo
git diff --check
```

Native tests need workstation ucode/fs. Set UCODE_MODULE_DIR and UCODE and
prepend that binary directory to PATH for a custom build. The native fixture
cursor is test-only; production RPC does not accept its environment/path options.
Both the pinned OpenWrt ucode build and current workstation build were exercised.
Four legacy generator shell suites need native uci/jsonfilter unavailable on this
macOS host and explicitly SKIP; the file-backed native mixed generator is exercised
separately. Node/gettext are development tools only, not router dependencies.

## Changed Files

New:

```text
docs/AWG-STAGE23.md
root/usr/libexec/podkopchik/awg_network.uc
root/usr/libexec/podkopchik/awg_manage.uc
root/usr/libexec/podkopchik/awg_cli.uc
tests/awg_network_smoke.uc
tests/awg_manage_smoke.uc
tests/awg_generate_smoke.js
tests/awg_integration_smoke.sh
tests/awg_interception_smoke.sh
tests/awg_admin_smoke.sh
tests/ucode/uci.uc
tools/awg-preflight.sh
tools/awg-rollback.sh
tools/build-awg-apk.sh
tools/build-awg-stage23.sh
tools/router-awg-isolated-test.sh
tools/router-awg-controller-test.uc
tools/router-awg-native-uci-test.uc
```

Modified:

```text
Makefile
README.md
docs/SPEC.md
docs/ACCEPTANCE.md
docs/AWG-STAGE1.md
po/ru/podkopchik.po
i18n/ru/podkopchik.ru.lmo
root/etc/config/podkopchik
root/etc/init.d/podkopchik
root/usr/bin/podkopchikctl
root/usr/libexec/podkopchik/awg.uc
root/usr/libexec/podkopchik/awg_rpc.uc
root/usr/libexec/podkopchik/generate.uc
root/usr/libexec/podkopchik/apply_rules.sh
root/usr/libexec/podkopchik/cleanup_rules.sh
root/usr/libexec/podkopchik/health_check.sh
root/usr/libexec/podkopchik/connection_check.sh
root/usr/share/rpcd/acl.d/luci-app-podkopchik.json
root/www/luci-static/resources/view/podkopchik/awg.js
root/www/luci-static/resources/view/podkopchik/proxies.js
root/www/luci-static/resources/view/podkopchik/status.js
uninstall.sh
tools/build-awg-stage1.sh
tests/apply_preflight_smoke.sh
tests/awg_packaging_smoke.sh
tests/awg_rpc_smoke.js
tests/awg_ui_smoke.js
tests/fakedns_hijack_smoke.sh
tests/fakedns_milestone_smoke.sh
tests/generate_domain_rules_smoke.sh
tests/manual_bypass_smoke.sh
tests/podkopchikctl_stability_smoke.sh
tests/proxy_endpoint_bypass_smoke.sh
tests/status_speed_limits_render_smoke.js
tests/xray_instance_restart_smoke.sh
```
