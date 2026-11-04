# Flint 2 Upgrade And AWG Readiness

Date: 2026-11-04, Europe/Moscow. Device scope: `ssh openwrt2`,
GL.iNet GL-MT6000, board `glinet,gl-mt6000`, LAN `192.168.8.1`.
The Xiaomi AX6000 was not contacted or changed in this operation.

## Firmware And Preservation

The owner separately authorized preparation, confidential backup transfer to
their Mac, and then sysupgrade plus application/AWG restoration.

- Before: OpenWrt 24.10.4, kernel 6.6.110, opkg, eMMC kernel/rootfs partitions.
- After: OpenWrt 25.12.6, kernel 6.12.112, APK.
- Official image:
  `openwrt-25.12.6-mediatek-filogic-glinet_gl-mt6000-squashfs-sysupgrade.bin`.
- SHA256:
  `a25a05977027deae000b10b025b75ed3e9c12a4b7d42ae57e8d5a8a019493658`.
- Official checksum signature verified with documented public key
  `b5043e70f9a75cde`, used in the private verification directory only.
  No new key was installed into the old system trust store.
- Device metadata and `sysupgrade -T -f` passed. No force/compatibility bypass.
- The authorized sysupgrade rebooted the device. Its SSH command ended with
  an ubus connection error during transition; subsequent direct inspection
  confirmed the new release/kernel, retained SSH host identity and working LAN.
  The flash command was not blindly retried.

Network/Wi-Fi/SSH settings were preserved. First-boot migration added
`network.globals.dhcp_default_duid` and updated odhcpd lease/PIO/hosts paths.
Those native migrations were retained, not overwritten with old settings.
Subsequent application/module installation preserved those post-migration
network, wireless, firewall, DHCP and dropbear files byte-for-byte.
The WAN gateway/address/interface are unchanged; no global VPN default route
was introduced.

## Application And Module

Podkopchik 0.1.0-beta was installed through its source installer from commit
`00be461297f2812d3d1ede8e37510489fbd0a3f0`, followed by the local installer
permission fix. The normal installer installed missing official dependencies.
The current official feed supplied Xray 26.10.21, not the older 26.3.27 baseline;
both generated and actual active configurations passed its native validation.

The source archive contained group-writable directory metadata. Initial tar
installation propagated those modes to payload parents. `install_payload_dir()`
now normalizes static directories to `0755`; repeat installation restored their
canonical permissions without changing configuration or private file modes.
The regression test covers source directories `0700`/`0775` and unrelated private
files/directories. No routing/generator/health code was changed for this fix.

AWG installation used the publisher-signed index at
`https://slava-shchipunov.github.io/awg-openwrt/25.12.6/mediatek/filogic/packages.adb`.
The publisher public key was compared between its GitHub Pages/GitHub locations
and the previously verified key hash. APK verification of the index passed.
Direct package-file verification alone returned UNTRUSTED, so that direct
installation path was not used. Native APK installed packages through the
authenticated index and its package hashes, with a per-command keys directory
and temporary repository argument. No permanent third-party feed/key or
signature bypass was added.

- `amneziawg-tools`: 3.1.20260812-r1.
- `kmod-amneziawg`: 6.12.112.3.1.20260906-r1.
- Exact required/running kernel ABI:
  `6.12.112~f0a7348f9cb959e1bf4d0447669b031e-r1`.
- Seven matching crypto/UDP-tunnel dependencies installed from official feeds.
- Module loaded without symbol/vermagic errors; an empty temporary interface
  was created/deleted without addresses/routes. No test interface remains.

## Observed Working State

The owner imported AWG and changed roles/settings while restoration was in
progress. These new settings were recognized and not reverted or replaced.

| Check | Result |
| --- | --- |
| AWG `germanyWARP` selected main, handshake and bound HTTPS | PASS, measured UP |
| Main Xray and health daemon | PASS, one main Xray |
| Active/generated Xray validation | PASS |
| FakeDNS local and LAN queries | PASS, fake 198.18/198.19 answers |
| Interface-bound Mac LAN YouTube HTTPS | PASS, HTTP 200, TLS verify 0 |
| Reserved/endpoint returns before TPROXY | PASS |
| DNS NAT redirects and current TCP/UDP interception rules | PASS, rules present |
| IPv6 interception | OFF, not tested/enabled |
| Real UDP/QUIC data and automatic failover | NOT VERIFIED in this operation |
| Backup VLESS `finWarp` and separate VLESS `8444` | DOWN, health timeouts; not advertised as working |
| LuCI / AWG RPC / Russian catalogs | PASS; anonymous HTTP 403 contains the normal login form, not a missing CGI |

Existing FakeDNS and the owner's UDP opt-in were retained. No forced role
switch, fabricated health result, full nft flush, or WAN/LAN/Wi-Fi/SSH rewrite
was used. Backup unavailability requires separate endpoint/server diagnosis;
the working AWG main must not be disabled to hide it.

## Recovery Material

Initial backup bundle on the owner's Mac:
`.router-backups/flint2/preupgrade-20261104/backup-bundle.tar.gz`.
SHA256: `37d7a014760877d05e798b609d65fa17baee8800dd3ee2668fd3a66a30d80d8d`.
It contains confidential settings, credentials and original boot-partition
data; it is not a full byte-for-byte dump of the entire eMMC. It is Git-ignored,
with directory `0700`/file `0600`, and must never be published or unpacked over `/`.

The exact preserved-settings archive is also saved on Mac. New recovery files
survived under `/root/podkopchik-recovery-20261104/`. A separate working config
archive including the newly imported AWG was saved there root-only as
`working-config-with-awg-20261104.tar.gz`; it was not exported to Mac.
The earlier Mac backup does not contain this newly imported AWG configuration.

No automatic rollback from a non-booting firmware was claimed. Physical
Ethernet/U-Boot recovery remains necessary if a future firmware cannot boot.
Do not restore old opkg databases/modules/feed files onto the APK system or
reapply forensic overlay/boot-partition dumps as an ordinary config restore.

The installer fix is applied locally and on Flint 2 but has not been pushed to
GitHub; publish/review it before relying on future main-channel reinstalls.

## Local Checks

- Installer payload-permissions regression: PASS.
- opkg/apk installer and Xray rollback mock matrix: PASS.
- 17 JavaScript smoke suites: PASS, including i18n/real LMO coverage.
- Syntax: 110 shell scripts/fixtures, 43 JavaScript files, 5 JSON files: PASS.
- `msgfmt -c` and `git diff --check`: PASS.

These mock/static checks do not substitute for the scoped live results above.

Sources: [official image/checksums](https://downloads.openwrt.org/releases/25.12.6/targets/mediatek/filogic/),
[OpenWrt public keys](https://openwrt.org/docs/guide-user/security/signatures),
[publisher feed documentation](https://github.com/Slava-Shchipunov/awg-openwrt/blob/master/docs/custom-feed.md),
[physical recovery](https://docs.gl-inet.com/router/en/4/faq/debrick/).
