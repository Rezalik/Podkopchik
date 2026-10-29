# AmneziaWG Stage 4: Independent UDP/IPv6 And Failover Hardening

## Scope

Experimental local development for the existing AX6000 stock layout,
OpenWrt25.12.6/kernel6.12.112, AWG3.1 and Xray26.3.27. No firmware, core,
module or package update is required. This document began as local preparation.
The separately authorized deployment and live tests are recorded in
[the AX6000 live report](AWG-STAGE4-LIVE-20261029.md). GL-MT6000 was not accessed.

## Fixes And Configuration

The previous LuCI checkbox used `checked: false`. LuCI's DOM helper serializes
the value as an HTML attribute; the presence of `checked="false"` still checks
the box. Two independent DOM properties now reflect strictly boolean RPC fields.
The RPC saves both UCI flags transactionally and reads them back after success
or failure. Page reload/new-session smoke tests cover this regression.

```uci
config settings 'main'
 option udp_interception '0'
 option ipv6_interception '0'
 option fail_threshold '3'
 option restore_threshold '2'
 option switch_cooldown '60'
```

Missing flags default off. An old explicit `extended_interception=1` is read
only as fallback for missing new options; saving either new control writes
both values and removes the old option. Updates never turn extensions on or
rewrite existing user settings automatically. FakeDNS stays off by default.

UDP opt-in adds UDP TPROXY alongside TCP, using the same routing rules and
outbounds, for enabled address families. Unmatched traffic remains direct.
UDP by IP rules, LAN full-proxy rules and recovered FakeDNS names is supported
by this path. Arbitrary UDP to an unlisted real IP has no domain to match and
is not automatically protected. No UDP/443 block is installed.

When IPv6 is off, both TPROXY rules explicitly match IPv4, avoiding interception
without an IPv6 local route. IPv6 on adds table10991 local policy routing and
dual FakeDNS. ICMPv6/ND/RA are never intercepted; multicast, link-local, loopback
and private destinations stay bypassed. DNS TCP/UDP53 reaches the existing NAT
DNS chain via an earlier return when DNS redirection is configured. AWG outer
traffic is router output, not LAN prerouting. Automatic/manual endpoint bypass
returns stay before TPROXY. Neither system default route is changed.

The IPv6 toggle requires LAN IPv6 and **every enabled AWG profile** to have an
IPv6 interface address, AllowedIPs `::/0`, an owned live IPv6 default route and
a successful interface-bound, pinned IPv6 HTTPS check. VLESS candidates must
pass a pinned IPv6 HTTPS request through their own temporary Xray SOCKS listener.
No remote DNS or IPv4 fallback can make that IPv6 check pass. Partial IPv6
AllowedIPs are deliberately rejected by the simple toggle. WAN IPv6 by itself
is insufficient. The known `kaz` profile is IPv4-only: enabling IPv6 with that
profile must report an error without committing settings or replacing nft.
Later manual UCI Apply also checks structural LAN/profile compatibility.
Regular health checks test IPv6 HTTPS when IPv6 interception is enabled.

The shared automatic group keeps main+three ordered backups. Effective fail
and restore thresholds are at least2, so one failed request cannot trigger a
switch. Unknown/expired results reset consecutive counters. A backup must have
both threshold-UP and a latest successful real probe less than300s old. A
retained UP status with a latest failed probe is not a valid new candidate.
`switch_cooldown` defaults to60s (0–3600); it delays preferences/auto-return
only while the current path is freshly healthy. Failure escape and all-down
blocking are immediate after their normal thresholds, regardless of cooldown.
Events carry the reason; syslog and `last_switch_time` carry time, never keys.
Selection changes retain config validation, atomic replacement and rollback;
unchanged selection does not restart Xray. Existing sessions must reconnect.

## Evidence And Limits

**Observed on the real AX6000 before this stage's deployment**, read-only on
2026-10-29: `kaz` main, `novos` backup1, both fresh UP; active domain/IP rules
target AWG; marked route lookup uses its private table while main default uses
WAN; live logs contain transparent-to-AWG; one main Xray; no pending role
journal; FakeDNS returns198.18.x.x; endpoint bypass and TCP TPROXY exist.
The combined checkbox was visually checked but UCI and nft were TCP-only.
This is evidence for the preceding build, not a live test of Stage4.

**Local native/mock checks** cover checkbox semantics and reload, separate flags,
legacy reading, profile/route/HTTPS IPv6 gates, mixed AWG→VLESS→AWG thresholds,
rejected failed/stale candidates, cooldown, all-down blocked, private terminal
guards, generated domain/IP/LAN rules, UDP/IPv6 nft matrix, DNS rule order,
failed nft transaction retention, repeated Apply and scoped cleanup. The
deployment failure trap is tested with fake restore/apply commands.

**Subsequently verified live**: native nft/Xray syntax, installation, IPv4
TCP/UDP through AWG and VLESS, threshold failover/return, scoped real LAN/WAN
counters during all-down, and independent canonical snapshot restoration.
**Not PASS yet**: QUIC/HTTP3, an IPv6-capable peer, exhaustive pcap leak capture,
full stop/start/reboot and a signed APK. See the live report for PASS/FAIL/SKIPPED
details, transient failures and the resolved snapshot-permissions incident.
This macOS host cannot execute Linux nft or a router kernel namespace test.
Mocked guard checks are not proof of absence of WAN leaks. Disabled protocols,
direct/unmatched rules and explicit bypasses intentionally are not protected.
HTTPS health does not prove UDP support at the VPN server. Do not advertise
complete UDP/IPv6 or reboot/leak acceptance until those tests pass.

Final local check results:17 JavaScript smoke suites PASS;24 shell smoke suites PASS
in the general host run,7 platform-dependent suites SKIP. Two skipped AWG suites
were rerun successfully using native ucode (100 parser/storage assertions and
802 model/lifecycle/management assertions). Five legacy generator/parser shell
suites still require native OpenWrt UCI/jsonfilter. Mixed generator tests run
separately using native ucode plus a file-backed UCI adapter, not kernel traffic.
Both pinned OpenWrt ucode and the local current ucode build pass the mixed tests.
Expanded final shell syntax check109 scripts/fixtures, JavaScript parse43 files,
JSON5 files, msgfmt, i18n coverage,
real LMO smoke, documentation links/fences and git diff whitespace checks PASS.

## Changed Files

```text
README.md
Makefile
docs/ACCEPTANCE.md
docs/SPEC.md
docs/AWG-STAGE23.md
docs/AWG-STAGE4.md
po/ru/podkopchik.po
i18n/ru/podkopchik.ru.lmo
root/etc/config/podkopchik
root/usr/libexec/podkopchik/interception.uc
root/usr/libexec/podkopchik/apply_rules.sh
root/usr/libexec/podkopchik/awg_cli.uc
root/usr/libexec/podkopchik/awg_manage.uc
root/usr/libexec/podkopchik/awg_network.uc
root/usr/libexec/podkopchik/awg_rpc.uc
root/usr/libexec/podkopchik/connection_check.sh
root/usr/libexec/podkopchik/generate.uc
root/usr/libexec/podkopchik/health_check.sh
root/www/luci-static/resources/view/podkopchik/awg.js
tests/apply_preflight_smoke.sh
tests/awg_generate_smoke.js
tests/awg_integration_smoke.sh
tests/awg_interception_smoke.sh
tests/awg_manage_smoke.uc
tests/awg_network_smoke.uc
tests/awg_packaging_smoke.sh
tests/awg_rpc_smoke.js
tests/awg_ui_smoke.js
tests/awg_stage4_admin_smoke.sh
tests/interception_model_smoke.uc
tests/connection_check_smoke.sh
tests/fakedns_hijack_smoke.sh
tests/fakedns_milestone_smoke.sh
tests/health_failover_apply_race_smoke.sh
tests/manual_bypass_smoke.sh
tools/build-awg-apk.sh
tools/build-awg-stage23.sh
tools/awg-stage4-install.sh
tools/awg-stage4-watchdog.sh
tools/awg-stage4-guard-lock.uc
tools/awg-stage4-deploy-worker.sh
tools/stage4-audit.nft
tools/stage4-stun-lan.c
tools/awg-preflight.sh
tests/awg_snapshot_smoke.sh
tests/proxy_endpoint_bypass_smoke.sh
docs/AWG-STAGE4-LIVE-20261029.md
```

## Package And Approved Installation

The delivered `podkopchik-awg-stage4.tar.gz` is a complete **public source
overlay**, not a signed APK. It excludes default UCI, private profiles and all
user credentials. It includes the real Russian LMO catalog in both LuCI paths.
Build on the workstation, never on the router:

```sh
sh tools/build-awg-stage23.sh /absolute/path/podkopchik-awg-stage4.tar.gz
```

For an actual APK use `sh tools/build-awg-apk.sh /path/to/OpenWrt-SDK` on a Linux
25.12.6 mediatek/filogic SDK host, inspect and sign using an approved key. No SDK
APK was built here. Never use `--allow-untrusted` or a forced kernel dependency.
Package release is incremented to3; the displayed application version stays
0.1.0-beta. This avoids reusing the previous APK package revision.

**Only after separate installation permission**, stage the overlay and matching
preflight/install/watchdog/guard-lock/deploy-worker helpers in a root700 directory
on AX6000. Verify SHA256, keep SSH open and avoid LuCI edits/parallel updates.
Check mode can run without activation:

```sh
sh /root/awg-stage4-install.sh --check /root/podkopchik-awg-stage4.tar.gz EXPECTED_SHA256
```

Check mode verifies model/versions/module/packages/space, active Xray and archive
paths/hash/types without applying routing. Install takes a root600 snapshot of
code/UCI/profiles, records both-family policy and nft diagnostics under `/root`,
uses the shared apply lock, does not stop interception, replaces only the health
worker, validates and applies through the existing controller, and restarts
rpcd/uhttpd. It never changes networking services, default routes or firmware.
Xray config validation and `nft -c -f` happen before their respective replacement.
Actual installation now requires an armed, matching **independent procd
watchdog**, with a monotonic deadline at least30s away. Its root-only canonical
snapshot must pass hash/path/type validation. Start the dedicated procd worker
with `PODKOPCHIK_STAGE4_GUARD` set to that directory. The worker runs the
installer; SSH disconnection does not cancel the timer. Explicitly commit the
guard only after independent SSH/LAN/DNS/core/health checks. An installer failure
requests independent recovery instead of racing another restore process.
See [live deployment/recovery evidence](AWG-STAGE4-LIVE-20261029.md).

Snapshot generation must use explicit canonical paths. Never repack a private
staging directory with `tar .`: its mode could replace `/` and system parents.
Guard and installer rollback reject root/system parent directory entries and
links. The backup helper includes health state as a file, not as a `/tmp`
directory entry. OS flock serializes restore/commit and is released on process
death. This protects SSH-session loss, not power loss, broken storage or a
failed procd/OS; a physical recovery method is still necessary.

For an explicit rollback, use the exact backup path/hash printed at installation:

```sh
sh /root/awg-stage4-install.sh --rollback /root/podkopchik-before-stage4-TIMESTAMP.tar.gz BACKUP_SHA256
```

Prefer a new independent guard with the chosen canonical snapshot and its hash,
followed by `watchdog.sh request DIR`; never re-use a committed guard. The direct
CLI rollback shown above is an explicit operator repair, not an independent timer.
Rollback restores that snapshot, including its user configuration, then reapplies
the previous version without generic route flushes. It cannot preserve edits
made after the snapshot. New unused helper files may remain; old code does not
reference them. The separate historical `awg-rollback.sh` is for pre-Stage2/3
code and must **not** be used to restore this mixed-runtime snapshot.

## Verification After Approval

```sh
ubus call system board
uci -q get podkopchik.main.udp_interception
uci -q get podkopchik.main.ipv6_interception
podkopchikctl validate
podkopchikctl generate
xray run -test -config /etc/podkopchik/config.generated.json
podkopchikctl status
pgrep -a xray
ip -N -4 rule show
ip -N -6 rule show
ip -4 route show table main
ip -6 route show table main
nft -a list table inet podkopchik
nslookup -port=1053 x.com 127.0.0.1
```

Refresh LuCI and verify two unchecked controls when both UCI flags are absent/0.
Enable UDP only, then reload LuCI: IPv6 must remain off. Test DNS UDP/TCP, QUIC
and a controlled UDP echo/IP target through each connection, plus unmatched
direct. IPv6-only opt-in must fail for the current IPv4-only AWG without changes.
Use a genuinely dual-stack AWG peer for success, then check AAAA FakeDNS, IPv6
TCP/UDP, ICMPv6 and unchanged main IPv6 routes. Capture WAN traffic on a test
client/network: allow only tunnel endpoint transport for protected targets.

Use local fixtures first for main-down, backup-down and restore; the working
AX6000's real main may be interrupted **only with separate permission**. Verify
fresh backup selection, cooldown, no restart on unchanged selection, all-down
blocking, reconnection behavior and post-test defaults. Reboot acceptance needs
an isolated test system or separate explicit permission, never an unattended
reboot of the working router. Never publish raw .conf/UCI/probe stderr/private
snapshot contents. Stop after packaging/report until deployment is authorized.
