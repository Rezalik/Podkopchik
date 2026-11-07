# Permanent Native Apply

This feature-branch implementation replaces the bounded canary controller for
ordinary household operation. It is selected explicitly with
`podkopchik.main.routing_engine=native`. The default remains `legacy`; installing
application sources or the ARM64 helper does not select Native routing.
`native-apply` remains the historical isolated test command, not the installer
or the activation command for this implementation.

## Transaction And Ownership

`podkopchikctl apply` stages the entire configured `lan_ifname`, not one client.
The coordinator snapshots UCI and immutable AWG profile revisions, inventories
live IPv4/IPv6 routes, addresses, policy rules, VPN addresses/AllowedIPs,
endpoints and issued pools, and checks ip-full, firewall4, offloading, space,
DNS readiness, nft syntax and any required Xray config. Validation errors do
not stop the current generation or change the saved routing intention.

After preflight it persists checksummed generation files, a root-only recovery
copy of the coordinator/CLI/helper launcher and a fixed trial deadline. A
separate procd supervisor owns activation and timeout rollback; it is not a
child of the SSH session. Generation pointers and the trial journal are
atomically replaced and synced before use. External lifecycle commands have
bounded execution, including OpenWrt installations without a `timeout` applet.

The cutover is a **guarded transaction**, not an assertion that Linux provides
one atomic syscall for DNS, RPDB and nftables. An owned prerouting transition
guard at priority -321 first blocks LAN forwarding but preserves router-local
management, DHCP and neighbour discovery. Quarantine and owned policy routes
are installed before a single nft batch replaces classification/DNAT/DNS
interception. Listeners are verified before forwarding is released. No global
default route, Wi-Fi, dnsmasq configuration or foreign nft table is replaced.

Owned resources include:

- `inet podkopchik_native`, `podkopchik_native_gate` and the transition guard;
- firewall4 permits and `pkc_native_boot`, identified by the runtime marker;
- only the coordinator's two firewall UCI includes;
- VLESS tables 43000..43031, priorities 12000..12031 and protocol 188, with
  a persistent exact ownership journal;
- existing independently owned AWG adapter tables/marks, managed by the AWG
  controller, without changing profile keys or connection roles.

Native status exposes readiness, phase, pending token, automatic selection,
protocol-specific unknown fallback and Xray necessity. LuCI Status provides
explicit confirm/rollback actions. There is no implicit browser confirmation.
AWG role/interception actions propagate a pending Native Apply to LuCI rather
than hiding its confirmation requirement behind a final-success notification.

```sh
podkopchikctl validate
podkopchikctl generate       # Native plan: /etc/podkopchik/native.generated.json
podkopchikctl apply          # returns pending token and fixed timeout
podkopchikctl native-status
# After checking LAN DNS, internet and WAN capture:
podkopchikctl native-confirm TOKEN
# Or request autonomous restoration before confirmation:
podkopchikctl native-abort TOKEN
```

The default confirmation window is 300 seconds, configurable within 60..900.
An expired, replaced or previous-boot token cannot confirm a generation.
`validate-active` checks the installed snapshot, not unapplied UCI edits.
Application updates retain the frozen active coordinator until a new Apply;
updates/old code rollbacks lacking Native support are refused while installed.

### Repair Policy

`native_recovery_policy=transactional` remains the default. The explicitly
selected `repair` policy requires a verified, armed independent emergency
capsule before Apply. Ordinary listener, DNS provider, site or transport
failures do not restore legacy: the coordinator retains Strict guards and
reports `phase=repair` or `recovery`. A corrected ordinary Apply can replace
the failed pending generation; failed validation does not cancel its journal.
The repair confirmation timer is not a connectivity test or a rollback trigger.

Until acceptance, a separate boot-bound 120-second management lease must be
renewed after external SSH and LuCI checks. The frozen procd emergency worker
does not acquire the Native coordinator lock. Lease expiry, an unconfirmed
reboot or an explicit critical-emergency request triggers recovery. After
explicit acceptance it no longer depends on an awake Mac: only prolonged
loss of local SSH/HTTP listeners triggers automatic emergency recovery.
Local listeners alone do not prove remote reachability; retain external
checks throughout controlled acceptance.
Selecting Native with missing/corrupt generation metadata never starts legacy.
A small shell-only startup guard denies LAN forwarding and client UDP/TCP DNS
before local-delivery exemptions, while retaining router management. It does
not depend on the Go helper or a readable Native pointer. Successful explicit
repair clears only this owned guard. Boot/transition guards also hold client
DNS until the protected listener is ready; a service-start race cannot silently
release it to the stock ISP upstream.

The capsule is `/etc/podkopchik-native-emergency` (root-only), with a checksummed
baseline Xray config, nft snapshot and small frozen AWG adapter code. It verifies
the existing Xray binary rather than duplicating it on flash. Recovery preserves
AWG profiles/roles/default route and allocation history, removes only Native
resources, and runs **protected legacy recovery**, not the original implicit
Direct fallback. Unknown transparent traffic uses the baseline AWG or fails
closed; non-intercepted forwarding is denied except reviewed address grants.
The retired Native pool is blocked before TPROXY; both pools retain output,
forward and postrouting quarantine. Failed recovery retains a forwarding guard
and retries. It neither changes Wi-Fi/network UCI nor reboots the router.

```sh
# Operator-controlled preparation; not an unattended installation recipe.
podkopchikctl native-emergency prepare ADMITTED_PRIVATE_POOL
podkopchikctl native-emergency arm 120
podkopchikctl native-emergency status
# Renew using the emergency token, after checking management independently:
podkopchikctl native-emergency heartbeat EMERGENCY_TOKEN
# Confirm Native separately, then explicitly accept the emergency lease:
podkopchikctl native-confirm APPLY_TOKEN
podkopchikctl native-emergency accept EMERGENCY_TOKEN
# Critical emergency only:
podkopchikctl native-emergency request
```

## Protected DNS Upstream

Permanent Native requires the schema-3 DNS component. Client queries use
DNS-over-TLS with certificate/SNI verification over a selected AWG or VLESS
transport, never the ISP/system resolver. The default numeric endpoints are
`1.1.1.1:853@one.one.one.one` and `9.9.9.9:853@dns.quad9.net`, with their IPv6
counterparts when the transport supports IPv6. Optional UCI `list native_dns_tls`
entries use `numeric-address:port@certificate-name` (bracket IPv6 addresses).
Unverified certificates, missing interfaces, changed ifindex and all-down
return SERVFAIL; no real protected address is released and no WAN DNS fallback
exists. Failed providers/transports are bounded and retried without restarting
the DNS worker. Each query connection is closed, not retained in an unbounded
UDP cache. Upstream socket state is private and updated on health selection.

AWG DNS sockets bind both interface and mark. VLESS DNS uses a dedicated
loopback TCP SOCKS inbound per adapter, then verified end-to-end TLS. AWG-only
does not start Xray for DNS. A single-stack deployment returns NODATA for the
unsupported DNS address family; cached unsupported traffic remains denied by
the kernel policy rather than using IPv6 WAN.

Transport endpoint bootstrap is separate: root-only pinned HTTPS DNS queries
to numeric Cloudflare endpoints resolve configured VPN hosts and explicit
Direct exclusions. It cannot forward arbitrary LAN DNS. Numeric dial addresses
are frozen in the generation for AWG and VLESS, including VLESS health probes;
Reality SNI/security and stored profiles remain unchanged. Bootstrap therefore
does not require the not-yet-started transport. Endpoint changes require a new
admitted Apply. Local DHCP/DNS services are not replaced.

Provider references: [Cloudflare DoT](https://developers.cloudflare.com/1.1.1.1/encryption/dns-over-tls/)
and [Quad9 services](https://docs.quad9.net/services/).

## Classification And Transports

Strict unknown traffic uses a healthy protocol/family-compatible protected
Main/Backup transport, or drops. It never silently becomes direct. DNS lookup
is not claimed as proof of the domain of a cached real-IP connection. Explicit
whole-address/CIDR and whole-device direct grants retain their documented
scope, including other names sharing a CDN IP, and require acknowledgement.

Domain groups, named proxy groups, CIDR rules and full-proxy/direct LAN rules
are compiled from UCI. Protected DNS results are synthetic only after the
DNAT map and policy-set transaction succeeds. AWG uses kernel DNAT, marking,
RPDB and masquerade; neither its packets nor its DNS pass through Xray.
Xray runs only when a selected VLESS path requires it. VLESS adapters currently
carry TCP only. Unsupported UDP/IPv6 has no WAN fallback; unknown UDP can use
another healthy compatible AWG. Existing conntrack transport pins cannot
silently migrate established tuples to a different adapter.

Strict **domain-only Direct** rules cannot safely authorize old real-IP/CDN
connections. Permanent preflight rejects them rather than silently treating
them as exact direct matches. Use reviewed IP/device grants, or explicitly
choose Compatible without strict migration restriction. Manual host exclusions
resolve to reviewed whole-address grants, not SNI-based domain proofs.
Conflicting/overlapping domain policies are rejected before cutover.

The existing health daemon publishes selection only after the Core accepts
its atomic switch. Freshness, failure/restore thresholds, cooldown, manual
override and fixed-group isolation remain enforced. All-down blocks protected
traffic while explicit direct grants remain usable. Adapter restoration is
retried without restarting an already valid AWG interface.

## DNS State And Reboot

Persistent state lives in `/etc/podkopchik/native-state`, mode 700, regular
private files mode 600. Allocation watermarks are synced **before** nft commit;
checksummed binding records are synced **before** DNS replies. Ambiguous writes
burn allocations or return SERVFAIL, never issue an unclassified real address.

The journal records question name, logical target, real/synthetic address,
boot UUID and monotonic expiry. Same-boot restarts replay only unexpired
bindings whose current policy still matches. Reboot does not replay mappings
from another boot: a fresh upstream answer must revalidate the identity. A
freshly revalidated identity may retain its synthetic address; that address is
never reassigned to a different identity. Changing pool tuples cannot reset
or overlap an issued namespace. Deleting the allocator is not a recovery step.

DNS TTL is bounded at 300 seconds with 30 seconds of lease grace. Expired
maps/sets stop authorizing new or existing synthetic tuples; long-lived
connections without DNS refresh may need reconnection. This is conservative
expiry, not transparent session migration. Late replies and unknown/retired
addresses remain blocked. Live TCP across a repeated Apply is preserved while
its binding and transport pin are still valid.

The WAL is capped at 4 MiB, compacted from 3 MiB to at most 2 MiB live history;
history also has an 8192-identity bound. There are at most eight nonoverlapping
pool namespaces. A /24 has 254 allocation positions and is for limited tests,
not an unlimited home workload. Explicit admitted RFC1918 /16..24 pools are
supported. Exhaustion returns SERVFAIL; it does not recycle an address into
another domain. Pool rotation requires inventory and keeps old pools in
quarantine. Long-term capacity and flash wear still need physical observation.

The existing early guard init at S18 precedes firewall4/netifd. The owned fw4
table-pre include starts with LAN forwarding closed. Native startup restores
owned adapters/RPDB, restores valid DNS state, starts needed transport listeners,
verifies readiness, starts health/failover, then releases forwarding. A firewall4
reload reinstates the boot guard; the supervisor checks and restores only its
permits before release, without a firewall restart. Flow offloading is not
supported: configured/live offload rejects Apply and a later live flowtable
keeps the guard closed. Hardware PPE coexistence is not claimed.

## Recovery Contract

Native-to-Native failure/timeout/reboot restores the last confirmed generation,
including its immutable coordinator and DNS policy. Quarantine and allocation
high-water marks are **never rolled backwards** with application snapshots.
An explicit routing disable (`podkopchikctl cleanup`) releases interception and
owned RPDB/includes, but retains issued-pool quarantine and survives boot.
Returning to legacy requires this explicit disable first, then selecting
legacy and applying. A service stop is not a routing-disable request: it keeps
forwarding closed and retains LAN DNS interception to the stopped listener.
It does not silently release client DNS to the ISP. Explicit routing disable
is a separate operation and restores ordinary stock DNS.
Use the candidate's Native-aware uninstaller, not an older downloaded script.
It refuses removal of an active Native controller until `podkopchikctl cleanup`
has explicitly disabled routing. Normal uninstall preserves its OFF intention
and configuration; `--purge` is the separately destructive configuration removal.

The **first** migration has no confirmed Native generation. Automatically
restoring legacy's implicit direct fallback would violate Strict. In that
case recovery starts a protected DoT real-answer worker under the validated kernel policy:
cached real addresses use a protected transport or drop; exact synthetic DNS
classification remains unavailable until a successful new Apply. Status shows
`phase=recovery`, not ready/accepted. A persistent classifier startup failure
uses the same protected recovery. This is deliberately not an unrestricted
legacy restoration. The separately armed repair-policy emergency capsule is
the final management-recovery path described above; never enable implicit
direct fallback merely to clear an error.

## Build And Controlled Installation

Build only on the workstation with the pinned Go 1.26.10 toolchain:

```sh
sh tools/check-native-local.sh
sh tools/prepare-native-dns-vm.sh
sh tools/build-native-candidate.sh
```

The candidate contains application sources, a real LuCI LMO, a deterministic
ARM64 helper and its fixed-hash launcher, SHA256SUMS and exact target metadata.
The helper is stored once at `/etc/podkopchik/native-bin/SHA256`; old active
versions are not overwritten. Frozen coordinators copy only the tiny launcher.
Build twice and compare both archive and binary hashes before deployment.

Physical deployment remains a separate controlled operation. Do not run the
following preparation steps until the VM release gates and fresh Xiaomi
preflight pass, backups are on the Mac, and autonomous local recovery is ready:

1. Verify the transferred archive SHA256, safe paths, UID/GID and manifest.
2. Extract under `/tmp`, never over the installed files. Budget at least 64 MiB
   free tmpfs before copying/unpacking the candidate; preflight requires 48 MiB
   still free after staging, and 96 MiB available RAM.
3. Run `sh install-native-dns.sh --preflight`; it changes no routing or UCI.
   It requires actual board `xiaomi,redmi-router-ax6000-stock`, OpenWrt 25.12.6
   and aarch64. Required flash is the new helper rounded to 4 KiB **plus**
   13.5 MiB (8 MiB untouched reserve, 4 MiB WAL, 1.5 MiB code/snapshots).
   Existing immutable binaries are checksum-verified, not counted twice.
   Ordinary Native `validate` separately reports the measured generation/code
   budget plus 12 MiB for the bounded WAL and untouched reserve. Additional
   immutable helper versions require their own flash space; an update stops
   when keeping its rollback version cannot fit.
4. Run the helper's `--install`, then the verified local `install.sh`. A normal
   release `update-install` also invokes the component preflight/install when
   present. Configurations are preserved. No new pool is chosen automatically.
5. Admit nonoverlapping native pool(s), review direct grants, select Native,
   and use ordinary Apply with an independent fixed deadline.
6. Confirm only after real LAN DNS/HTTPS, all AWGs, WAN capture, management and
   application checks succeed. In transactional mode, an unconfirmed failure
   restores the confirmed generation. In explicitly armed repair mode, ordinary
   faults stay on guarded Native for in-place correction; emergency legacy
   restoration is reserved for management loss or an unsafe critical failure.

Back up UCI, Podkopchik code, active Xray binary/selector, AWG revisions,
firewall/DNS settings and Native state privately before physical deployment.
Keep the full archive on the Mac and only verified autonomous recovery files
on flash. Do not delete user data or old allocator state to make space.
The component preflight does not replace a measured budget for the backup and
the currently installed Xray version.

## Acceptance Boundary

`tools/native-permanent-vm-test.sh` exercises ordinary full-LAN Apply in a
NIC-free OpenWrt 25.12.6 VM. The permanent boot fixture uses a writable ext4 disk
and actual kernel reboots; its early guard is checked before its simulated WAN
is created. It invokes the production init dispatch and procd services.
AWG L3/RPDB interfaces in that VM are **Ethernet stand-ins**, not proof of a
real AmneziaWG handshake. TCP/TLS/UDP/QUIC, nft, RPDB, conntrack, Xray/Reality
and virtual WAN captures are real guest networking.

Physical Xiaomi acceptance still must cover actual AWG keys/handshakes, WAN
encapsulation/capture, applications, netifd hotplug, hardware behaviour,
recovery from abrupt power loss and many-hour resource/flash observations.
DoH/DoT/ECH and literal IPs do not provide domain identity. Strict unknown
fallback protects them unless an explicit whole-IP/device grant applies;
Compatible cannot offer that guarantee. No result on the VM alone authorizes
automatic household activation.

See [the release acceptance record](UNIVERSAL-PERMANENT-ACCEPTANCE-20261107.md)
for the measured results, candidate checksums and remaining physical gates.

The subsequent [household Native RC deployment](UNIVERSAL-NATIVE-HOUSEHOLD-20261107.md)
records actual full-LAN activation, application checks, physical AWG failover,
MSS correction and the remaining UDP/QUIC and long-duration limitations.
