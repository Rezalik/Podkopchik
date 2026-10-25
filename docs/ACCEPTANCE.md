# Acceptance criteria for Podkopchik 0.1.0-beta

## Must exist

- Makefile
- README.md
- install.sh
- uninstall.sh
- root/etc/config/podkopchik
- root/etc/init.d/podkopchik
- root/usr/bin/podkopchikctl
- root/usr/libexec/podkopchik/generate.uc
- root/usr/libexec/podkopchik/parse_vless.uc
- root/usr/libexec/podkopchik/apply_rules.sh
- root/usr/libexec/podkopchik/cleanup_rules.sh
- root/usr/libexec/podkopchik/health_check.sh
- root/usr/share/luci/menu.d/luci-app-podkopchik.json
- root/usr/share/rpcd/acl.d/luci-app-podkopchik.json
- LuCI JS views for Status, Proxy Links, Presets, Domain Groups, IP Rules, Exclusions, LAN Devices, DNS, Updates, Logs, Advanced

## Functional requirements

- Add/edit/delete named VLESS links.
- Support VLESS TCP/REALITY.
- Support VLESS XHTTP/REALITY.
- Choose main/backup/disabled proxy roles in the simple Proxy Links UI.
- Maintain an internal automatic proxy group from proxy roles.
- Support strict_primary group mode.
- Support fixed_proxy group mode.
- Support manual override.
- Route domain groups to the automatic proxy group, a specific proxy, or direct.
- Route destination IP/CIDR to proxy groups.
- Add presets for Telegram, YouTube, Instagram, TikTok, X / Twitter, Discord, OpenAI / ChatGPT / Codex, and Canva.
- Presets create ordinary editable `domain_rule` and `ip_rule` sections; they must not introduce a separate routing system.
- Presets must skip duplicates by rule type, value, and target, and report added and skipped counts.
- LuCI Save & Apply on routing-affecting pages, including Proxy Links, Domain Groups, IP Rules, Exclusions, LAN Devices, DNS, and Advanced settings, and Add preset on Presets, updates the active runtime state through the Podkopchik apply/cleanup path when routing is active; manual SSH apply is not required.
- Add manual Exclusions for domain, IP, and CIDR destinations that must go direct without port matching.
- Manual Exclusions Save & Apply must run the Podkopchik runtime apply path; manual SSH apply is not required.
- Route source LAN IP devices to proxy groups/direct.
- Store LAN device speed limit settings and expose diagnostics without enabling real `tc`/`ifb` enforcement.
- Use dnsmasq as default DNS.
- Optionally redirect LAN UDP/TCP 53 DNS to router DNS.
- Enable Xray sniffing.
- Do not enable FakeDNS by default.
- Implement health checks.
- Implement failover to backups.
- Implement auto-return to primary.
- Generate Xray config.
- Validate config before applying.
- Manage only Podkopchik nftables rules.
- Provide LuCI update page with `main` development branch updates and `stable` GitHub Release updates.
- Preserve /etc/config/podkopchik on update/uninstall unless purge is explicitly requested.
- Generate/apply repairs stale enabled routing targets to `auto_proxy_group` only when the internal automatic proxy group is valid; otherwise it reports the broken target and UCI section without replacing the active Xray config.
- Service is enabled and started by install.sh, while TPROXY interception remains inactive until a valid proxy/rule set is applied.
- `install.sh` performs system preflight, `/overlay` free-space checks, conflict detection, dependency installation, dependency validation, file installation, LuCI restart/cache cleanup, and post-install status checks in that order.
- `install.sh` installs missing `ip-full` itself; BusyBox `ip` must not be accepted as sufficient for fwmark policy routing.
- `install.sh` stops before package installation when `/overlay` has less than 15 MB free, and warns when less than 25 MB is free.
- `install.sh` stops by default when conflicting proxy applications are installed or active, including Podkop, sing-box, Passwall, OpenClash, Mihomo/Clash, v2rayA, or standalone Xray service/config.
- `install.sh` treats existing `/etc/config/podkopchik` as update mode and preserves it.
- Health checks record real probe results when Xray plus curl probing is available; otherwise they report unknown with the reason and do not mark proxies up.
- Health-check cleanup removes stale temporary Xray processes using `/tmp/podkopchik/health-*.json` and never targets the main `/etc/podkopchik/config.json` Xray process.
- `podkopchikctl status` reports Xray as running only when the main process uses `/etc/podkopchik/config.json`; stale health probe processes must not be counted as the main service.
- If failover config apply cannot acquire the runtime apply path or fails validation/application, health state is not advanced to the new active proxy; the next health check can retry without drifting away from the active Xray config.

## Preset acceptance

- Telegram preset creates 8 domain entries and 7 IP CIDR entries.
- YouTube preset creates 15 domain entries and no IP entries.
- Instagram preset creates 14 domain entries and no IP entries.
- TikTok preset creates 14 domain entries and no IP entries.
- X / Twitter preset creates 19 domain entries and no IP entries.
- Discord preset creates 11 domain entries and no IP entries.
- OpenAI / ChatGPT / Codex preset creates 14 domain entries and no IP entries.
- Canva preset creates 10 domain entries and no IP entries.
- Re-applying the same preset to the same target adds no duplicates.
- Presets can target the automatic proxy group, an existing proxy group, a specific proxy outbound, or direct.
- OpenAI / ChatGPT / Codex, Canva, Discord, and CDN domain lists are editable starting points because service hostnames can change.

## FakeDNS MVP acceptance

FakeDNS is experimental and must remain disabled by default.

When explicitly enabled with:

```sh
uci set podkopchik.main.fakedns_enabled='1'
uci set podkopchik.main.fakedns_hijack_dns='1'
uci set podkopchik.main.fakedns_port='1053'
uci set podkopchik.main.fakedns_listen=''
uci set podkopchik.main.fakedns_pool_v4='198.18.0.0/15'
uci commit podkopchik
```

the router acceptance checklist is:

- `xray run -test -config /etc/podkopchik/config.generated.json` reports `Configuration OK`.
- nft table `inet podkopchik` contains `dns_prerouting`.
- Xray listens on port `1053`.
- active FakeDNS pool `198.18.0.0/15` is absent from nft `reserved4`.
- active FakeDNS pool `198.18.0.0/15` is absent from Xray private/reserved direct rule.
- a LAN client DNS query for `x.com` via router DNS returns `198.18.x.x` or `198.19.x.x`.
- X/Twitter app works on an iPhone LAN client.

The FakeDNS MVP must not add UDP TPROXY or UDP/443 blocking.

LuCI acceptance:

- Podkopchik -> DNS exposes Enable FakeDNS, Hijack LAN DNS queries, FakeDNS port, FakeDNS IPv4 pool, FakeDNS pool size, and FakeDNS listen address.
- FakeDNS remains disabled by default.
- FakeDNS-dependent fields are shown only when FakeDNS is enabled.
- Save & Apply on the DNS page saves UCI and runs the Podkopchik runtime apply path.
- The DNS page warns that clients using Private DNS, DoH, iCloud Private Relay, or another VPN may bypass router DNS.

## Stability pass verified on GL-MT6000 / OpenWrt 24.10.4

This stability checkpoint was verified on a GL.iNet Flint 2 / GL-MT6000 router
running OpenWrt 24.10.4 after `podkopchikctl update-install` from GitHub
`main`.

The checkpoint covers:

- update-install from GitHub `main`
- `rpcd` and `uhttpd` restart after update
- `podkopchikctl validate`
- `podkopchikctl generate`
- `xray run -test -config /etc/podkopchik/config.generated.json`
- repeated `podkopchikctl apply` idempotency
- exactly one final main Xray process using `/etc/podkopchik/config.json`
- no stale `/tmp/podkopchik/health-*.json` Xray processes after health checks
- no stale health port locks after health checks
- nftables rule order with `reserved4/6` and `proxy_bypass4/6` before final TCP TPROXY
- FakeDNS with `dns_prerouting`, active pool in Xray FakeDNS, and active pool absent from Xray direct reserved rules and nft `reserved4`
- direct FakeDNS query to `127.0.0.1:1053` returning `198.18.x.x` or `198.19.x.x`
- Telegram IP rules in active Xray config for `91.108.*` and `149.154.160.0/20`
- Exclusions in UCI, nft `proxy_bypass4`, and Xray direct domain rules
- LuCI runtime apply path on the installed version

Expected safe warnings:

- `health check skipped; another health check is already running` can appear during race sanity checks; this means the health lock worked.
- An active health probe Xray may be visible during a mid-check process snapshot; it is not stale if it disappears after the check completes.
- `ucode -V` can report `unrecognized option: V` on OpenWrt; this is not a Podkopchik failure.

Repeat the stability check on a router with:

```sh
podkopchikctl update-install
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
podkopchikctl validate
podkopchikctl generate
xray run -test -config /etc/podkopchik/config.generated.json
podkopchikctl apply
sleep 2
podkopchikctl apply
sleep 2
podkopchikctl status
pgrep -a xray || true
pgrep -af '/etc/podkopchik/config.json' | wc -l
pgrep -af '/tmp/podkopchik/health-.*.json' || echo 'OK: no stale health Xray'
ls -d /tmp/podkopchik/health-port-*.lock /tmp/podkopchik/health-check.lock 2>/dev/null || echo 'OK: no stale health locks'
nft -a list table inet podkopchik | grep -nE 'proxy_bypass|reserved|dns_prerouting|tproxy|chain prerouting|chain dns_prerouting'
jsonfilter -q -i /etc/podkopchik/config.generated.json -e '@.fakedns.ipPool' || true
jsonfilter -q -i /etc/podkopchik/config.generated.json -e '@.routing.rules[*].ip[*]' | grep '198.18.0.0/15' && echo 'WARNING: FakeDNS pool direct-routed' || echo 'OK: FakeDNS pool not direct-routed'
nft list set inet podkopchik reserved4 | grep '198.18.0.0/15' && echo 'WARNING: FakeDNS pool in reserved4' || echo 'OK: FakeDNS pool not in reserved4'
nslookup -port=1053 x.com 127.0.0.1 || true
grep -oE '91\.108\.[0-9.]+/[0-9]+|149\.154\.[0-9.]+/[0-9]+' /etc/podkopchik/config.json | sort -u
uci show podkopchik | grep -iE 'bypass_rule|host|comment' || true
nft list set inet podkopchik proxy_bypass4 || true
```

## Xray Manager And Connection Checks

Local tests cover the following; actual core-update success is not asserted for
either physical router until the on-device checks below pass.

- Updates renders installed source/version, architecture, last check/status and
  separate package/official actions; all new strings have Russian translations.
- Package update targets only `xray-core` with `opkg upgrade` or `apk upgrade`
  (install/add if absent); package-owned executables
  are never replaced by manual copies.
- Official update uses XTLS metadata, matching architecture, SHA256, space and
  ELF checks; invalid config/checksum/architecture is rejected before activation.
- Shared selector is used by CLI, init and probes. Candidate validation precedes
  restart; failed startup or primary verification restores the old executable.
- Active config, nft rules, FakeDNS and policy routing must remain unchanged.
- No router reboot, kernel upgrade, default-route change, UDP TPROXY or UDP/443
  blocking is introduced.
- VLESS checks return measured HTTPS duration, external IP and timestamps; expired
  success becomes unknown. Failed checks allow saving. Private URI values never
  appear in command arguments or diagnostic responses.
- Probe timeout/error paths terminate the isolated process and release its lock;
  a busy listener cannot produce a false UP result.
- Existing VLESS ordered failover, thresholds and health cleanup continue to pass.
- The original Stage 1 configuration manager did not change routing. Experimental
  Stages 2–3 and their separate verification limits are recorded below.

Physical router acceptance (GL-MT6000 24.10.4/6.6.110 and Redmi AX6000
24.10.1/6.6.86 must each be tested separately, with explicit operator approval):

1. Record UCI, active config digest, nft table and policy route before updating.
2. Check package/official available versions in LuCI; verify matching arm64 asset.
3. Use a known working VLESS main proxy, active routing and optional FakeDNS.
4. Install the chosen Xray update; verify installed version, one main process,
   listeners, actual LAN routing and FakeDNS, with no changes to saved URI/rules.
5. Verify external IP and HTTPS latency from the same connection in Proxy Links.
6. Test Restore previous Xray, then recheck LAN traffic, FakeDNS and health.
7. Separately test failure recovery using a controlled unavailable main proxy
   and verify the previous runtime executable remains selected.

```sh
podkopchikctl xray-status
podkopchikctl xray-check package
podkopchikctl xray-check official
podkopchikctl validate-active
podkopchikctl status
nft -s list table inet podkopchik
ip rule show
ip route show table 10991
netstat -lnptu | grep -E '1053|12345'
```

Run `podkopchikctl xray-install official` (or `package`) and
`podkopchikctl xray-rollback` only during the approved physical test.

## Dual Package Manager Preparation

- OpenWrt 24.10 selects opkg; OpenWrt 25.12 selects apk, even if both are in PATH.
- A missing native manager or ambiguous unknown release fails clearly.
- Installer fresh/repeated install, conflict/space/dependency failures and UCI
  preservation pass the isolated test matrix for both managers.
- Normal and package-registered uninstall preserve UCI; failed removal restores
  it, and explicit purge removes it. No recursive removal flags are used.
- APK version queries use JSON, not description text or guessed version numbers.
- Package and official Xray updates, failed package mutation recovery, missing
  package installation and previous-executable rollback pass both mock paths.
- No unsigned/untrusted flags, full-system upgrade or manual package-binary
  replacement are introduced; package dependencies are not rolled back.
- All 20 declared dependencies exist in the recorded official 25.12.6 filogic
  feeds; the snapshot test rejects new unverified dependencies.
- `tools/verify-clean-openwrt.sh` is opt-in, limited to a disposable 25.12.6
  x86/64 VM, and refuses the physical Xiaomi target.
- Real clean-VM boot/install and physical AX6000 25.12.6 LAN/FakeDNS/egress
  acceptance remain pending. Mock tests and feed availability are not hardware
  acceptance. Do not contact/update GL-MT6000 for this migration.

See [the audit, VM procedure and post-sysupgrade recovery](OPENWRT-25.12-MIGRATION.md).

## AWG 3.1 Stage 1: Configuration Management

Local acceptance (not on-router deployment acceptance):

- Multiple valid synthetic 3.1 profiles import with independent IDs, including
  duplicate display/upload names; no artificial connection-count limit.
- Rename, replace, static revalidation and confirmed deletion work.
- Invalid keys, missing peers, invalid endpoints/IP/CIDR/ranges, overlapping
  headers, hooks, unsupported directives, unsafe paths and oversized files fail.
- Private keys never appear in metadata/list/RPC errors/notifications or UCI.
- Files are owner-only `0600`, storage directory `0700`; fixed storage and
  generated IDs prevent caller-selected filesystem paths.
- Native ucode tests cover real writes/flock, failed metadata commit preserving
  the previous config, and refusal of symlink configuration files.
- LuCI uses only authenticated rpcd methods with separate read/write ACLs,
  handles uploaded names as text and requires confirmation before deletion.
- List statuses indicate configuration validity only, never connected/UP.
- AWG backup inclusion and normal-uninstall preservation are verified.
- Existing VLESS, generator, FakeDNS, nft, health and routing code are unchanged.

Commands:

```sh
sh tests/awg_model_smoke.sh
node tests/awg_rpc_smoke.js
node tests/awg_ui_smoke.js
node tests/i18n_coverage_smoke.js
node tests/lmo_catalog_smoke.js
```

Native parser/storage/RPC tests require local ucode with fs; a SKIP is not PASS.
See [the historical Stage 1 plan](AWG-STAGE1.md).

## AWG 3.1 Stages 2–3: Verification Gates

- [x] Local native parser/storage, lifecycle ownership, role/UCI rollback and
  generated domain/IP/LAN mixed failover tests; no real network claims from mocks.
- [x] Main plus three ordered backups shared by VLESS/AWG, restore thresholds,
  all-down blocked, unavailable AWG outbounds blackholed, unmatched direct retained.
- [x] Separate alias assignment and numeric iproute2 type7 regression checks.
- [x] nft atomic batch, repeated apply, failed-batch retention and opt-in UDP/IPv6
  mocked checks. TCP-only and FakeDNS-off defaults retained; no UDP/443 block.
- [x] Read/write ACL, secret-free RPC/errors, JS UI/actions and Russian catalog tests.
- [x] Real AX6000 isolated kernel AWG handshake + HTTPS; temporary Xray-to-AWG
  HTTPS200 with certificate verification, main routing/nft unchanged.
- [x] New controller tested from private /tmp only: repeated start/check/stop,
  unreachable mark after stop and owned interface/both-family policy removal.
- [x] Actual Xray26.3.27 accepted synthetic mixed config; active config unchanged.
- [x] Actual nft dry-run accepted the replacement batch without changing the live
  table; real UDP/IPv6 enforcement is not inferred from this syntax check.
- [x] Actual native UCI role/group/rollback/delete against private /tmp fixtures,
  with mocked network/apply, preserved live UCI/delta/config/routes. No non-native
  cursor.section() assumption remains in production or its test adapter.
- [ ] New application deployment and full live VLESS→AWG→AWG→VLESS failover,
  auto-return, simultaneous rule targets and LAN all-down leak capture.
- [ ] Live multiple profiles without inner-address overlap, reboot recovery and
  complete protected code rollback; local mocks are not substitutes.
- [ ] Real UDP/IPv6, DNS leak capture and acceleration/throughput acceptance.
- [ ] Native signed APK build/install on the target SDK/device. Public overlay
  built/tested separately; never describe it as an APK.

Details, source bundle, preflight, recovery and remaining limitations:
[AWG-STAGE23.md](AWG-STAGE23.md). No new Podkopchik was installed on the working
AX6000 during development. GL-MT6000 was not accessed.
No new version is installed on the working router by development tests.
Physical import/ACL checks on 25.12.6 and handshake/HTTPS acceptance remain
separate operator-approved steps. Do not test on or contact GL-MT6000.

## Required commands

These commands must exist:

```sh
podkopchikctl status
podkopchikctl generate
podkopchikctl validate
podkopchikctl apply
podkopchikctl restart
podkopchikctl cleanup
podkopchikctl health
podkopchikctl shaping-status
podkopchikctl update-check
podkopchikctl update-install
podkopchikctl rollback
podkopchikctl xray-status
podkopchikctl xray-check package
podkopchikctl xray-check official
podkopchikctl xray-install official
podkopchikctl xray-install package
podkopchikctl xray-rollback
```
