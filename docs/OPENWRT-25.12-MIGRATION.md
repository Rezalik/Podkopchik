# AX6000: preparation for OpenWrt 25.12.6

Date: 2026-10-25. Physical scope: Xiaomi Redmi Router AX6000 **stock layout**,
SSH alias `openwrt`, LAN 192.168.1.1. This preparation does not perform firmware
upgrades, install AWG, change networking or contact GL-MT6000. No changes from
this work have been installed on the physical router.

## Audit and package adapter

| Location | Finding / implementation |
| --- | --- |
| `install.sh` | Replaced direct opkg detection/status/update/install with `packages.sh`; raw bootstrap obtains the shared adapter from the source payload before package changes. Space/conflict checks remain before package installation. |
| `root/usr/libexec/podkopchik/packages.sh` | Selects opkg for 24.10, apk for 25.12. Missing native manager fails; unknown releases require exactly one manager. No manager-name option is taken from UCI. |
| `root/usr/libexec/podkopchik/xray_update.sh` | Uses native installed/candidate versions, ownership, refresh and targeted install/upgrade. Active executable version is separate from package metadata. |
| `root/usr/libexec/podkopchik/xray.sh` | Existing shared selector unchanged; package binary is resolved through PATH, managed official/rollback binary lives outside it. Update refuses a candidate whose path is not package-owned. |
| `root/usr/bin/podkopchikctl` | Application update delegates dependencies to the updated installer; its independent UCI backup, archive verification and application rollback are unchanged. |
| `uninstall.sh` | Raw install removes files without a package transaction; registered application/translation packages use native remove/del. UCI backup survives successful normal removal and failed package removal. Only explicit purge removes config/core copies. |
| `Makefile` | LuCI metadata for the matching release SDK; explicit `rpcd-mod-file` and `luci-light` dependencies added. APK package version uses `0.1.0_beta-r1`, while IPK/app display remains `0.1.0-beta`. No package manager executable hard dependency. |
| LuCI Updates / PO / LMO | Package source label is manager-neutral: opkg/apk. Backend action names and ACLs unchanged. |
| Init / apply / cleanup / health / generator | No package-manager operations, so no routing or health changes needed. |
| README / SPEC / ACCEPTANCE / Xray testing | Updated current requirements; older device stability observations remain historical evidence, not 25.12 acceptance. |

Commands, verified against the apk **3.0.5** source pinned by OpenWrt 25.12.6:

| Operation | opkg | apk |
| --- | --- | --- |
| Installed | `list-installed NAME` | `info --exists NAME` |
| Installed version | exact-name installed record | `query --from installed --match name --fields version --format json NAME` |
| Available version | exact-name `list NAME` record | `query --from repositories --match name --fields version --format json NAME` |
| Refresh / install | `update` / `install NAME` | `update` / `add NAME` |
| Update Xray | `upgrade xray-core` | `upgrade xray-core` |
| Ownership | `files NAME` | `info --contents NAME` |
| Remove registered app | `remove NAME` | `del NAME` |

The APK query result is a JSON array; `jsonfilter` reads the version. Never
guess from descriptive output. Neither manager runs a bare `upgrade`. Dependency
resolution can update necessary dependencies; it is not a firmware transaction.
APK verifies signatures by default. No untrusted, force, recursive removal,
repository replacement or signature-bypass flags are passed. Opkg signature
verification is required. Trust configuration of the native repositories still
belongs to the operator. Normal APK removal may remove unneeded automatic
dependencies according to its solver; no explicit dependency deletion is done.

## Verified dependency availability

All names below were checked in official `index.json` files and each resulting
APK URL returned HTTP 200. They happen to retain their 24.10 names; this is a
checked result, not an assumed mapping. `luci-light` supplies a usable LuCI shell
on a clean image; `rpcd-mod-file` supplies the views' fs RPC operations.
Snapshot: `tests/fixtures/openwrt-25.12.6-packages.json`. Versions are observations,
not runtime pins; feeds can change. Transitive dependencies remain solver-owned.

| Package | Observed version |
| --- | --- |
| luci-base, luci-light | 26.288.56989~75a306d |
| rpcd, rpcd-mod-file | 2026.10.04~d99f703e-r1 |
| rpcd-mod-luci | 20240305-r1 |
| uhttpd | 2026.08.24~373145f7-r1 |
| ucode, ucode-mod-fs, ucode-mod-uci, ucode-mod-ubus | 2026.01.16~85922056-r2 |
| curl | 8.23.0-r1 |
| ca-bundle | 20260816-r2 |
| jsonfilter | 2026.03.16~b9034210-r1 |
| nftables-json | 1.1.6-r2 |
| kmod-nft-tproxy | 6.12.112-r1 |
| firewall4 | 2025.03.17~b6e51575-r2 |
| ip-full | 6.18.0-r2 |
| dnsmasq | 2.93-r1 |
| xray-core | 26.3.27-r1 |
| unzip | 6.0-r9 |

Official feeds: [base](https://downloads.openwrt.org/releases/25.12.6/packages/aarch64_cortex-a53/base/index.json),
[packages](https://downloads.openwrt.org/releases/25.12.6/packages/aarch64_cortex-a53/packages/index.json),
[LuCI](https://downloads.openwrt.org/releases/25.12.6/packages/aarch64_cortex-a53/luci/index.json),
[exact filogic kmods](https://downloads.openwrt.org/releases/25.12.6/targets/mediatek/filogic/kmods/6.12.112-1-f0a7348f9cb959e1bf4d0447669b031e/index.json).
The module requires kernel `6.12.112~f0a7348f9cb959e1bf4d0447669b031e-r1`.
Never reuse a 24.10 IPK/kmod or an APK built for another kernel ABI.

## Executable and data paths

OpenWrt installs apk at `/usr/bin/apk`; opkg is found via PATH on 24.10.
The 25.12 xray-core recipe still installs `/usr/bin/xray` and its separate
standalone init script. Do not enable the standalone Xray service alongside
Podkopchik. Installer conflict detection already checks it. `ip` must identify
itself as iproute2; BusyBox ip is not sufficient regardless of manager.
LuCI source/menu/ACL and ucode i18n locations are unchanged. The Russian LMO is
also copied to the legacy Lua i18n location for compatibility.

Application updates/reinstalls do not overwrite `/usr/libexec/podkopchik-core/`.
Official executables never overwrite `/usr/bin/xray`. Package updates switch
the selector only after validation; failed startup/egress verification restores
the reserved previous executable. Package metadata/dependencies are **not**
downgraded. New status fields `package_manager` / `package_version` distinguish
this situation from the active `installed` executable version.

## Local and clean-VM checks

On the development machine, without SSH or any router mutation:

Recorded preparation checks: 37 smoke scripts (32 executed successfully, five
native ucode/parser scripts explicitly skipped because ucode/jsonfilter are
not available on this Mac), shell/JS syntax, JSON, msgfmt, i18n coverage, real
LuCI LMO catalog, Makefile version evaluation and `git diff --check`. The final
opkg/apk matrix was repeated after the package-query/rollback changes.

```sh
sh tests/dual_package_manager_smoke.sh
node tests/package_dependencies_smoke.js
```

The mock matrix covers fresh/repeated install, disabled/default routing,
conflicts, dependency failures, byte-identical UCI preservation, normal/purge/
failed registered uninstall, package version queries, targeted Xray install/
upgrade, official source separation and rollback after package mutation,
invalid config, startup, egress and FakeDNS verification failure.

For real apk/ucode/LuCI validation, boot a **disposable OpenWrt 25.12.6 x86/64
VM** in an isolated network with internet access and enough persistent storage.
Copy this checkout there (Node is not required on the guest). Run there only:

```sh
PODKOPCHIK_TEST_VM=disposable sh tools/verify-clean-openwrt.sh
```

The guard rejects mediatek/filogic and an existing Podkopchik config. The test
installs/reinstalls/uninstalls only in the VM; it checks network/SSH config
digests, default interception/FakeDNS off, generated config validation, package
status and retained UCI. Separately test LuCI login, Russian labels, settings
save/apply, application update and Xray update/rollback using a disposable test
proxy. Then test LAN/FakeDNS/TPROXY on AX6000 during the approved migration.
Neither the VM script nor the mock matrix proves real aarch64 VPN egress.
The package-version test evaluates the real Makefile conditional, not an SDK
build. Building/signed-installing a native IPK/APK with the matching SDK remains
separate acceptance; the primary deployment here is the source installer.

## Recovery after separately approved sysupgrade

This is a future operator procedure, **not executed by this preparation**.
Before firmware work, export the normal OpenWrt settings backup and save it on
the Mac, plus a separate root-only Podkopchik backup. It contains credentials:

```sh
umask 077
set -- etc/config/podkopchik
[ ! -d /usr/libexec/podkopchik-core ] || set -- "$@" usr/libexec/podkopchik-core
tar -czf /tmp/podkopchik-recovery.tar.gz -C / "$@"
```

Download that archive to protected Mac storage; a file only in `/tmp` does not
survive reboot. Keep a pinned copy of this application revision and, preferably,
a prepared offline dependency bundle from the matching signed 25.12.6 feeds.
Record the active Xray source and installed version before firmware work.
Normal sysupgrade preserves configuration, **not installed application files**.
Do not restore old opkg databases, 24.10 feed files or old kernel modules.

After approved firmware installation, verify board ID is still
`xiaomi,redmi-router-ax6000-stock`, OpenWrt is 25.12.6, kernel ABI matches and
native feeds point to that release. Restore SSH/LuCI over Ethernet first.
The saved LAN/WAN/Wi-Fi/SSH configuration must not be rewritten by Podkopchik.
The following commands are for that later recovery window only:

```sh
apk update
apk add curl ca-bundle luci-ssl luci-i18n-base-ru
# Upload the trusted recovery archive and the prepared application checkout.
# If UCI is already retained, first confirm it matches the saved file.
# Restore only the trusted Podkopchik paths, including its selector/binary
# together when an official/rollback core was selected. Do not print secrets.
tar -xzf /tmp/podkopchik-recovery.tar.gz -C /
# Run from the prepared, pinned application checkout:
sh install.sh
podkopchikctl xray-status
podkopchikctl validate
podkopchikctl generate
```

Validate the generated file with the **selected** Xray (not necessarily the
package `/usr/bin/xray`):

```sh
. /usr/libexec/podkopchik/xray.sh
"$(xray_bin)" run -test -config /etc/podkopchik/config.generated.json
# Only after validation, in the approved recovery window:
podkopchikctl apply
podkopchikctl status
```

The installer preserves the retained UCI byte-for-byte and may start previously
enabled routing as before; inspect the saved settings/core selection before
running it. Do not restore an incomplete official selector without its binary.
If a managed executable is incompatible, choose package mode only through an
explicit recovery decision, validate the existing UCI with that executable,
then apply. Do not purge/reinitialize user configuration to repair installation.

## Remaining gates

During the first AX6000 deployment, the native BusyBox `tr` did not expand
`[:upper:]` / `[:lower:]`; it corrupted `port8444` and `auto_proxy_group` during
CLI target validation. CLI normalization now uses explicit ASCII alphabets,
with a regression test that refuses character classes. This restores the same
tag semantics as ucode/LuCI without changing nftables or the failover algorithm.

The initial preparation did not include a real 25.12.6 VM or physical upgrade.
This Mac has no OpenWrt VM/emulator or native ucode runtime. Physical follow-up
confirmed AX6000 stock boot on 25.12.6/6.12.112 and native APK dependency
installation; service behavior, Xray 26.3.27, FakeDNS and LAN egress still need
their separate post-restore acceptance.
The previously diagnosed LuCI VLESS precheck RPC `env` denial is a separate
known issue, not repaired by package-manager migration. AWG remains uninstalled
and its UI/backend remain gated. Do not perform firmware work until separately
approved. Main-branch application archives retain their existing development
trust model (no release checksum); use a pinned revision for migration recovery.
