# Xray Update Manager delivery and verification

Date: 2026-10-25. Branch: `main`. Changes are local; no router was contacted,
updated, restarted or rebooted during this task. No GitHub push was performed.

## Delivered

- A single Xray selector shared by procd, CLI validation, health probes and
  isolated connection checks.
- Independent manual Xray updates in LuCI: installed version/source, available
  version, architecture, check date/status, package/official source selection,
  check/update/previous-binary restore actions.
- Background jobs and status polling for long-running LuCI operations.
- Signed native opkg/apk feed refresh and targeted update of `xray-core`; no manual writes to
  package-owned binaries. Official XTLS updates with bounded HTTPS download,
  SHA256, architecture/ELF and executable/config validation.
- A reserved previous executable/selector, atomic managed selection and automatic
  rollback for handled errors/signals after mutation. Recovery uses renames so
  a full filesystem does not require another executable-sized allocation.
- Startup verification: one selected main executable, listeners, unchanged
  config/nft/policy/default routes, real FakeDNS answer within the configured
  pool when enabled, and primary HTTPS internet egress.
- Isolated pre-save/repeat VLESS checks: status, normalized error category,
  HTTPS request latency, external IPv4 and timestamp. Saving remains possible
  when the connectivity check fails. Port ownership and live PID are required.
- Periodic health metrics with unchanged thresholds and ordered failover.
  Results expire in five minutes; stale success/metrics are removed from the
  visible proxy card even when the page stays open.
- Root-only temporary check configs/logs; generated configs and existing
  reusable health files are protected before secret content is written.
- Russian PO updates and a genuine LuCI LMO rebuilt with `tools/po2lmo.js`.

## Deferred by the AWG compatibility gate

AWG 3.1 type selection/upload, configuration parsing/storage, tunnel lifecycle,
AWG internet/handshake checks and mixed VLESS/AWG failover are not shipped.
No AWG implementation is selected as verified for either requested system.
The known OpenWrt 24.10.4 build is AWG 2.0, while the maintainer's published
3.1 build targets 24.10.8. That does not establish compatibility with kernel
6.6.110 or 6.6.86. See [the primary sources and follow-up plan](XRAY-AWG-RESEARCH.md).

No incompatible kmod, substitute WireGuard, interface, firewall zone, WAN/LAN
route or AWG secret has been added. A verified exact-ABI kernel module/tools
pair or tested 3.1 userspace runtime is required before those stages proceed.

## Local checks

- Shell syntax for installer/uninstaller, init/CLI, all helpers and shell tests.
- All LuCI/tool/test JavaScript parse checks.
- All 13 JavaScript smoke tests, including proxy/status render, core UI actions,
  connection freshness, URI secrecy and JS/menu Russian i18n coverage.
- The 21 shell smoke scripts: 16 executable test cases and 5 explicit environment
  skips. New cases cover updates, checksum rejection, signature policy,
  unsupported architecture, low space, config/startup/egress/FakeDNS failures,
  rollback, background jobs, Xray-only procd restart and connection cleanup.
- Existing endpoint bypass, FakeDNS nft rules, apply preflight,
  health cleanup, failover/apply race, installer and legacy-target tests.
- Menu/ACL JSON parse, `msgfmt -c`, real LMO catalog smoke and `git diff --check`.

Native generator/parser checks are **not claimed passed**: this Mac lacks
`ucode` (with fs/UCI modules) and `jsonfilter`. Skipped tests:

- `generate_connection_check_smoke.sh`
- `generate_domain_rules_smoke.sh`
- `generate_fakedns_smoke.sh`
- `generate_manual_bypass_smoke.sh`
- `vless_parser_smoke.sh`

The new backend tests use controlled mock binaries/HTTPS replies; they do not
prove that a real Xray release starts on either router. Physical acceptance
remains required separately on GL-MT6000 24.10.4/6.6.110 and Redmi AX6000
24.10.1/6.6.86, both mediatek/filogic, aarch64_cortex-a53.

## Router test memo

After publishing this application revision and approving a test window, update
Podkopchik through the normal application update path. Confirm a working main
VLESS proxy and active routing. Record config hashes and nft/policy state first.

```sh
ubus call system board
uname -r
# OpenWrt 24.10:
opkg list-installed | grep -E '^xray-core|^unzip|^ip-full'
# OpenWrt 25.12 instead:
# apk query --from installed --fields name,version --format json xray-core unzip ip-full
podkopchikctl xray-status
podkopchikctl validate-active
podkopchikctl status
sha256sum /etc/config/podkopchik /etc/podkopchik/config.json
nft -s list table inet podkopchik
ip rule show
ip route show default
ip -6 route show default
ip route show table 10991
podkopchikctl xray-check package
podkopchikctl xray-check official
```

With separate operator approval, use Update Xray in LuCI or run exactly one
source explicitly:

```sh
podkopchikctl xray-install official
# Alternative: podkopchikctl xray-install package
podkopchikctl xray-status
podkopchikctl validate-active
podkopchikctl status
pgrep -af xray
netstat -lnptu | grep -E '1053|12345|20999'
nslookup -port=1053 x.com 127.0.0.1
nft -s list table inet podkopchik
ip rule show
ip route show default
logread -e podkopchik | tail -60
```

The DNS command applies when FakeDNS is enabled. Check actual proxied LAN
traffic (including X/Twitter and Telegram) and unaffected direct destinations.
In Proxy Links, paste a synthetic or private test URI, observe checking/result,
repeat, save an unreachable connection, and verify expiry after five minutes.
Never paste real links or private configuration into a public test report.

```sh
# Explicit runtime binary rollback, independent of application rollback:
podkopchikctl xray-rollback
podkopchikctl xray-status
podkopchikctl validate-active
podkopchikctl status
```

## Limits

- Linux arm64/x86_64 update assets only; other architectures are refused.
- HTTPS/provider reachability and sufficient temporary/persistent space are
  required. External IP currently uses the IPv4 `api.ipify.org` endpoint.
- A failed main-proxy check rolls back an update even if backups are usable.
- Package rollback restores the runtime executable, not opkg/apk dependencies or
  package metadata. Official-release checksums trust XTLS/GitHub publication.
- SIGKILL/power loss bypass traps. Inspect orphan locks/running workers and use
  the reserved executable as documented in README before retrying.
- AWG 3.1 and real on-router core-update acceptance remain unverified/deferred.

## Changed files

```text
Makefile
README.md
install.sh
uninstall.sh
docs/SPEC.md
docs/ACCEPTANCE.md
docs/XRAY-AWG-RESEARCH.md
docs/XRAY-UPDATES-TESTING.md
po/ru/podkopchik.po
i18n/ru/podkopchik.ru.lmo
root/etc/init.d/podkopchik
root/usr/bin/podkopchikctl
root/usr/libexec/podkopchik/xray.sh
root/usr/libexec/podkopchik/xray_update.sh
root/usr/libexec/podkopchik/xray_jobs.sh
root/usr/libexec/podkopchik/connection_check.sh
root/usr/libexec/podkopchik/probe_result.uc
root/usr/libexec/podkopchik/generate.uc
root/usr/libexec/podkopchik/health_check.sh
root/usr/share/rpcd/acl.d/luci-app-podkopchik.json
root/www/luci-static/resources/view/podkopchik/updates.js
root/www/luci-static/resources/view/podkopchik/proxies.js
tests/xray_update_smoke.sh
tests/xray_jobs_smoke.sh
tests/xray_instance_restart_smoke.sh
tests/xray_updates_ui_smoke.js
tests/connection_check_smoke.sh
tests/connection_checks_ui_smoke.js
tests/generate_connection_check_smoke.sh
tests/i18n_coverage_smoke.js
tests/proxy_links_render_smoke.js
tests/health_check_cleanup_smoke.sh
tests/health_failover_apply_race_smoke.sh
```
