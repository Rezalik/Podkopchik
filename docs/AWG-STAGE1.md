# AmneziaWG 3.1: Stage 1

## Scope And Baseline

Development baseline: Git `24fe05826499b038468d69c71fd2f511685bd5ca`.
This change is local only; it does not deploy to the working AX6000.
No GL-MT6000 access is needed or permitted for this task.

The separate AmneziaWG tab imports, lists, statically validates, renames,
replaces and deletes multiple configurations. There are no tunnel commands,
interfaces, routing targets, probes or automatic failover. The list shows
configuration validity, not connectivity. Names need not be unique.

The earlier AX6000 stock/OpenWrt 25.12.6/kernel 6.12.112 installation verified:
`kmod-amneziawg 6.12.112.3.1.20260906-r1` and
`amneziawg-tools 3.1.20260812-r1`. Neither is required just to store a profile.
Do not substitute WireGuard/AWG 2.0 or install another kernel's module.
Handshake and AWG HTTPS have not been tested.

## Supported Profile

Source format references:

- [Pinned tools parser](https://github.com/amnezia-vpn/amneziawg-tools/blob/v3.1.20260812/src/config.c)
- [Pinned kernel CPS parser](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/blob/v3.1.20260906/src/junk.c)

One `[Interface]`, followed by one or more `[Peer]` sections, ASCII directives,
LF/CRLF, optional `#` comments. Comments are not stored. Required parameters:
Interface `PrivateKey`; each Peer `PublicKey`, `Endpoint`, `AllowedIPs`.
Keys must be canonical nonzero base64 values encoding 32 bytes. Endpoints
accept hostname/IPv4 plus port, or bracketed IPv6 plus port; no DNS query occurs.

Interface allowlist:

```text
PrivateKey ListenPort FwMark Address DNS MTU
Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5
HeaderProtectionKey ContentPaddingAddition RandomTrailers DisableCookies
RekeyAfterTime RekeyTimeout RejectAfterTime KeepaliveTimeout MaxHandshakeAttempts
```

Peer allowlist:

```text
PublicKey PresharedKey Endpoint AllowedIPs PersistentKeepalive AdvancedSecurity
```

Numeric widths/ranges follow tools 3.1. Booleans accept `on/off/0/1`.
HeaderProtectionKey requires all S1-S4 >= 12; H1-H4 ranges must not overlap.
CPS accepts `<b 0x...>`, `<r N>`, `<rc N>`, `<rd N>`, `<c>`, `<t>` with
total packet size <= 65507. Address requires IP/CIDR; AllowedIPs also accepts
individual IPs. DNS and Address are stored only, never applied.

At least one new 3.x field is required. Plain WireGuard or old AWG without
these fields is rejected rather than presented as confirmed 3.1.
Syntax acceptance does not prove server version, key agreement or reachability.
PreUp/PostUp/PreDown/PostDown, Table, SaveConfig, Include, external key paths,
unknown directives/sections and duplicate parameters fail. Repeated Address,
DNS or AllowedIPs directives must be combined into one comma-separated value.
The intentionally strict subset can reject a valid upstream quick-script
profile: remove unsupported hooks/options yourself, never execute that file.

## Storage And Trust Boundary

`/etc/podkopchik/awg/` is root-owned `0700`. Each generated 32-hex ID has
`ID.json` metadata and `ID.REVISION.conf`, all root-owned `0600`.
PrivateKey/PresharedKey/HeaderProtectionKey are only in `.conf`, not UCI,
metadata, public responses, command-line arguments, environment or logs.
Metadata includes ID, display name, timestamps, current revision and last
explicit validation result. Listing rechecks current file validity without
writing; explicit revalidation records the timestamp/result.

The rpcd executable plugin receives bounded JSON on stdin. The application
read ACL grants only `list`; write ACL grants import/replace/rename/validate/delete.
It has no arbitrary file-read/download/write method. Local direct execution
is also protected by root-only storage. Use LuCI over HTTPS: this does not
encrypt ordinary HTTP transport or the router flash/backups.

A maximum of 64 KiB per file is enforced in browser and backend. Uploaded
filenames are not sent to the server or used for storage. Changes serialize
through native flock, released by process exit. Config and metadata are written
to exclusive private files, flushed and renamed on the same filesystem;
metadata publication is the commit point. Validation or commit failure retains
the old config. A power interruption can leave private orphan revisions or
temporary writes, not a partial visible revision. Do not claim fsync-level
power-loss guarantees. Deleting a profile removes only its ID's revisions.

OpenWrt keep.d includes this directory for sysupgrade backups. Backups contain
private keys: keep them offline and encrypted. Normal uninstall preserves them;
explicit `--purge` removes them. Existing installer/update paths do not overlay
any profile because no profile files are shipped in the payload.

## Local Checks And Bundle

```sh
sh tests/awg_model_smoke.sh
node tests/awg_rpc_smoke.js
node tests/awg_ui_smoke.js
node tests/i18n_coverage_smoke.js
node tests/lmo_catalog_smoke.js
msgfmt -c po/ru/podkopchik.po -o /tmp/podkopchik-ru.mo
git diff --check
sh tools/build-awg-stage1.sh /absolute/path/podkopchik-awg-stage1.tar.gz
```

Native tests require ucode/fs; development Node runs only on the workstation.
For a custom local build, set `UCODE` for the RPC test, prepend the binary
directory to PATH for the shell test, and set `UCODE_MODULE_DIR`.
Fixtures are deterministic synthetic bytes, never operational private keys.

The bundle is an explicit file-overlay archive, **not an APK/IPK**. It includes
only the new manager, ACL/menu, keep.d and real LuCI LMO catalogs. It does not
contain the installer, routing helpers, user data or any automatic deployment.
Building a native APK requires an OpenWrt SDK/buildroot.

## Future Manual Installation (Approval Required)

Do not run this during Stage 1 development. On the approved AX6000 only,
first compare board/version, current status and configuration hashes. Copy the
archive over authenticated SSH and compare its SHA256 with the workstation.

Create a root-only backup of existing shared UI/ACL/catalog files before
extracting. On a first Stage 1 install the four new manager files should be
absent; if they already exist, stop and include them in a separate backup.
Do not overwrite an unrecorded earlier AWG manager.

```sh
umask 077
ubus call system board
podkopchikctl status
test ! -e /usr/libexec/rpcd/podkopchik.awg || exit 1
test ! -e /usr/libexec/podkopchik/awg.uc || exit 1
test ! -e /usr/libexec/podkopchik/awg_rpc.uc || exit 1
test ! -e /www/luci-static/resources/view/podkopchik/awg.js || exit 1
# Keep this archive at a safe persistent/off-router location.
tar -czf /root/podkopchik-before-awg-stage1.tar.gz \
  /usr/share/luci/menu.d/luci-app-podkopchik.json \
  /usr/share/rpcd/acl.d/luci-app-podkopchik.json \
  /usr/share/ucode/luci/i18n/podkopchik.ru.lmo \
  /usr/lib/lua/luci/i18n/podkopchik.ru.lmo
sha256sum /tmp/podkopchik-awg-stage1.tar.gz
tar -tzf /tmp/podkopchik-awg-stage1.tar.gz
tar -xzf /tmp/podkopchik-awg-stage1.tar.gz -C /
# Reload rpcd to discover the executable plugin, without restarting networking.
/etc/init.d/rpcd reload
ubus -v list podkopchik.awg
ubus call podkopchik.awg list '{}'
```

Do not continue if the shared-file backup fails; account for absent legacy
catalog paths before making your device-specific backup. `rpcd reload` behavior
must be verified on the target release; if the object is absent, stop and
request permission for an rpcd restart rather than restarting networking.
Clear only LuCI caches if necessary and hard-refresh the UI.
Do not run `podkopchikctl apply`, restart Xray or run `awg-quick`.

In LuCI: AmneziaWG -> Import .conf; add two files, test names/replacement/static
validation, cancel then confirm deletion of one. Check the other remains.
An invalid/oversized/unsafe file must not create or replace a record.
Do not inspect raw config files in diagnostic output.

```sh
ubus call podkopchik.awg list '{}'
find /etc/podkopchik/awg -maxdepth 1 -type f -exec ls -l {} \;
sysupgrade -l | grep '^/etc/podkopchik/awg/'
podkopchikctl status
pgrep -a xray
ip rule show
ip route show default
nft -s list table inet podkopchik
```

Compare with the pre-install snapshot; no AWG interfaces should exist.

## Rollback Of A First Stage 1 Install

Restore the shared files from the verified backup, remove only the new manager
files, then reload rpcd and refresh LuCI. Preserve `/etc/podkopchik/awg/`.
This does not change tunnels, Xray, UCI, routing or network services.

```sh
tar -xzf /root/podkopchik-before-awg-stage1.tar.gz -C /
rm -f /usr/libexec/rpcd/podkopchik.awg \
  /usr/libexec/podkopchik/awg.uc /usr/libexec/podkopchik/awg_rpc.uc \
  /www/luci-static/resources/view/podkopchik/awg.js \
  /lib/upgrade/keep.d/podkopchik-awg
/etc/init.d/rpcd reload
```

Before removing keep.d, retain an encrypted external backup or explicitly add
the storage path to `/etc/sysupgrade.conf` if profiles must survive sysupgrade.
Never use `uninstall.sh --purge` as a manager rollback.

## Next Stage

After separate approval: on-device import/ACL acceptance, then design isolated
AWG interface/table ownership and test a real peer handshake and HTTPS egress.
Mixed VLESS/AWG routing and failover are not part of this stage.

## Development Verification, 2026-10-25

- Native ucode parser/storage tests: 100 assertions passed on workstation builds
  of current ucode and commit `85922056` used by OpenWrt 25.12.6.
- Native RPC framing/size/error-redaction tests passed on both builds.
- LuCI import/rename/replace/validate/delete/render/ACL mocks passed; these are
  not browser or physical-router deployment acceptance.
- Existing installer/update/uninstall tests passed for opkg and apk, including
  AWG storage preservation and explicit purge; overlay owner/mode tests passed.
- Existing native VLESS parser smoke passed after removing a test-only
  assumption that JSON serialization has no spaces. The parser was unchanged.
- Four full generator tests require unavailable local UCI/jsonfilter modules
  and were skipped, not counted as successful generation tests.
- JS parse/smoke, JSON, shell syntax, gettext checks, i18n coverage, real LMO
  catalog smoke and whitespace checks passed.

A read-only SSH check of `xiaomi,redmi-router-ax6000-stock` confirmed running
Xray, main VLESS `ibn` UP, active routing and a FakeDNS reply in `198.19.x.x`.
Hashes of Podkopchik UCI, network/wireless/firewall/DHCP/SSH configuration and
active Xray config matched the saved pre-AWG baseline. nftables, policy routing
and default routes matched the baseline byte-for-byte.
The two previously unavailable VLESS backups remained unavailable; no link was
modified. No new manager was deployed, no services were restarted, no AWG
interfaces/tunnels were created, and SSH remained accessible.

## File Inventory

New files:

```text
root/usr/libexec/podkopchik/awg.uc
root/usr/libexec/podkopchik/awg_rpc.uc
root/usr/libexec/rpcd/podkopchik.awg
root/www/luci-static/resources/view/podkopchik/awg.js
root/lib/upgrade/keep.d/podkopchik-awg
tests/awg_model_smoke.uc
tests/awg_model_smoke.sh
tests/awg_rpc_smoke.js
tests/awg_ui_smoke.js
tests/awg_packaging_smoke.sh
tools/build-awg-stage1.sh
docs/AWG-STAGE1.md
```

Modified files:

```text
root/usr/share/rpcd/acl.d/luci-app-podkopchik.json
root/usr/share/luci/menu.d/luci-app-podkopchik.json
uninstall.sh
po/ru/podkopchik.po
i18n/ru/podkopchik.ru.lmo
tests/install_workflow_smoke.sh
tests/lmo_catalog_smoke.js
tests/vless_parser_smoke.sh
README.md
docs/SPEC.md
docs/ACCEPTANCE.md
docs/XRAY-AWG-RESEARCH.md
```

No existing VLESS/routing/Xray/FakeDNS/health/apply/init/installer implementation
was changed. Uninstall only gains removal of the two new manager registrations;
ordinary profile preservation and explicit purge follow its existing behavior.
