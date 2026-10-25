# Xray updates and AmneziaWG 3.1 investigation

Initial investigation date: 2026-10-25. No router was contacted or modified
for that initial implementation. For the subsequent AX6000-only target decision
and opkg/apk preparation, see [25.12 migration](OPENWRT-25.12-MIGRATION.md).

## Existing runtime

`podkopchikctl`, the procd init script and `health_check.sh` each discover Xray
independently through PATH. All three must use the same selector before an
alternative binary can be activated. Podkopchik updates currently update the
application only. Xray is supplied as `xray-core`, using opkg on 24.10 and apk
on 25.12 through the shared package adapter.

The generator creates a dokodemo-door transparent inbound, VLESS outbounds,
optional FakeDNS, and domain/IP/source rules. nftables intercepts LAN TCP in
prerouting/mangle with mark `0x100000`, table/priority `10991`. Health checks
use temporary Xray SOCKS listeners; state thresholds and ordered failover
are centralized in `generate.uc`. Apply/failover serialize through
`config-apply.lock`; health probes serialize through `health-check.lock`.

## AWG compatibility gate (historical)

Update 2026-10-25: AX6000 stock layout was subsequently upgraded, with explicit
operator approval, to OpenWrt 25.12.6/kernel 6.12.112. Matching AWG 3.1 module
and tools were installed and local module/temporary-interface checks passed.
Handshake and AWG HTTPS are still unverified. Stage 1 now implements
[configuration management only](AWG-STAGE1.md); the older-kernel findings below
remain historical and do not establish compatibility for GL-MT6000.

The requested combination is **not confirmed** for either target:

| Device | OpenWrt | Kernel | Architecture | AWG 3.1 verdict |
| --- | --- | --- | --- | --- |
| GL-MT6000 | 24.10.4 | 6.6.110 | aarch64_cortex-a53 | No verified matching 3.1 package/runtime |
| Redmi AX6000 | 24.10.1 | 6.6.86 | aarch64_cortex-a53 | No verified matching 3.1 package/runtime |

Primary evidence:

- [Amnezia protocol documentation](https://docs.amnezia.org/documentation/amnezia-wg/)
  distinguishes protocol 3.1 from earlier versions.
- [OpenWrt package maintainer release 24.10.4](https://github.com/Slava-Shchipunov/awg-openwrt/releases/tag/v24.10.4)
  explicitly identifies its packages as AWG **2.0**.
- [Maintainer version matrix](https://github.com/Slava-Shchipunov/awg-openwrt#readme)
  lists older packages for 24.10.1 and AWG 3.1 for **24.10.8**.
- [Upstream kernel implementation](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module),
  [userspace implementation](https://github.com/amnezia-vpn/amneziawg-go), and
  [configuration tools](https://github.com/amnezia-vpn/amneziawg-tools) exist;
  source availability does not verify an OpenWrt binary or kernel ABI.

The architecture string alone cannot establish kernel-module compatibility.
Do not install 24.10.8 kmods into these two systems, use `--force-depends`,
remove 3.1 configuration parameters, or substitute WireGuard/AWG 2.0.
At that earlier checkpoint no AWG upload or secret storage was implemented.
The subsequent Stage 1 manager adds protected storage only; no AWG package
installer, tunnel, network check or failover is introduced.

To unblock: provide or build using the exact OpenWrt SDK/kernel configuration
an audited AWG 3.1 module and matching tools for each kernel ABI, or verify a
3.1 userspace runtime with TUN on each device. Builds belong off-router.
Verify all 3.1 parameters (including HeaderProtectionKey) against the pinned
implementation, then test handshake AND HTTPS egress with a disposable peer.

## Proposed AWG routing after the gate

Keep Xray as the routing engine. An AWG connection would own an interface,
an isolated mark/table and a protected root-only config. Xray freedom outbounds
can use socket interface/mark selection; verify these options with the exact
installed Xray build before adopting them. Populate only the AWG-owned table,
keep endpoint transport reachable through the physical route, and prevent
fallback to WAN on tunnel failure. Never run imported `PreUp/PostUp` commands
or `awg-quick` automatic global-route/DNS changes.

Domain groups, IP rules and presets would continue selecting outbound tags;
FakeDNS resolves the original domain before Xray chooses that outbound. This
does not require sing-box or LAN UDP TPROXY. IPv6, DNS for freedom outbounds,
return-path filtering, tunnel endpoint loops and table ownership require router
tests. The existing health thresholds must remain the only failover authority.

Upload handling needs a fixed root-only destination, size limit, structured
allowlist parser for the pinned 3.1 format, secret-free diagnostics and complete
delete/update cleanup. A generic WireGuard INI parser cannot prove 3.1 support.

## Xray update design

Use a Podkopchik-owned binary location and selector shared by init, validation,
probes and CLI. Never manually overwrite `/usr/bin/xray` owned by opkg.
OpenWrt package updates target `xray-core` through the native manager. Preserve a technical
copy of the previous executable for runtime rollback; package dependencies and
package metadata are not downgraded by binary rollback.

Official updates use only
[XTLS releases](https://github.com/XTLS/Xray-core/releases), a matching asset and
SHA256 integrity data, stage only the executable, and validate existing configs
before activation. The upstream
[asset mapping](https://github.com/XTLS/Xray-core/blob/main/.github/build/friendly-filenames.json)
maps Linux arm64 to `Xray-linux-arm64-v8a.zip`; its
[build workflow](https://github.com/XTLS/Xray-core/blob/main/.github/workflows/release.yml)
builds static Linux executables and publishes checksums. Checksums from the same
publisher detect corruption, not compromise of that publisher.

Serialize updates with apply and health. For a running service, restart only
the Xray procd instance so existing nft/FakeDNS rules remain intact; verify its
executable, listeners, nft/policy state and a real primary egress probe.
Rollback the selector/binary on failed validation, startup or verification.
An unconfigured service can validate a candidate but cannot pass the full runtime
update gate until routing and a main proxy are configured.
