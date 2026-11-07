# Permanent Native Apply Acceptance, 2026-11-07

Base: `8c59dc7`, branch `feature/universal-routing-engine`. This change implements
ordinary permanent whole-LAN Apply, not another canary/preview activation path.
Neither Xiaomi nor `openwrt2` was contacted or changed during this acceptance.
This is a release candidate, not a claim of long-term physical-router stability.

## Environment And Evidence

ARM64 QEMU, OpenWrt 25.12.6, kernel 6.12.112, no host/network NIC. Test namespaces
contain a full LAN, router, two independently marked L3 transports and a captured
virtual WAN. AWG interfaces are Ethernet stand-ins with real RPDB protocol 186;
there is no real AWG cryptographic handshake in this VM. Mixed tests use real
Xray 26.3.27 and a local VLESS/Reality server, not a mocked proxy response.

Repeatable entry points:

```sh
sh tools/check-native-local.sh
sh tools/prepare-native-dns-vm.sh
sh tools/run-native-reboot-vm.sh reboot-lab-permanent-acceptance
# In the console, mount the printed read-only payload, then:
sh /mnt/lab/setup-native-dns-guest.sh
# Permanent reboot fixture:
mkdir -m700 -p /etc/pkc-native-vm-state
touch /etc/pkc-native-vm-state/permanent-only
sh /mnt/lab/install-native-vm-boot.sh
```

`tools/native-permanent-vm-boot.sh` drives the confirmed and pending reboot
phases. After its PASS marker, the `extended` marker under
`/etc/pkc-permanent-vm` selects production-service and durable-journal recovery
tests; restart the VM fixture init service, not any physical router service.
Run the `PKC_VM_PERMANENT=1 PKC_VM_ONLY_MIXED=1` fixture separately for mixed
Reality/VLESS acceptance. These flags are VM test controls, not product modes.

## Results

| Gate | Result | Evidence / scope |
| --- | --- | --- |
| Whole-LAN ordinary Apply and confirmation | PASS | Procd activation, explicit nonce, kernel forwarding released only after readiness |
| Domain/CIDR/client rules and Strict cached shared CDN IP | PASS | Protected/unknown use marked transport; reviewed IP/client Direct grants work with documented whole-address scope |
| DNS UDP/TCP, CNAME, TTL, concurrent clients, nft failure | PASS | Linux Go suite and namespace network tests; SERVFAIL without protected real-IP reply |
| TCP/TLS, UDP echo and QUIC, IPv4/IPv6 | PASS | Actual guest sockets, DNAT, conntrack, RPDB and interface captures |
| AWG-native independence | PASS, L3 scope | No Xray process in AWG-only; not a physical AWG handshake claim |
| Health failover / hysteresis / all-down / primary return | PASS | Actual health daemon and Core selection; two L3 adapters |
| Mixed VLESS and TCP-only UDP restriction | PASS | Real Reality endpoint; transport listeners verified before selection |
| nft activation failure and confirmation timeout | PASS | One-shot actual nft failure; previous confirmed generation restored; fixed 60-second trial expired without SSH |
| Repeated Apply and established TCP | PASS | Stable transport pin and valid live binding retained |
| Confirmed and unconfirmed actual VM reboots | PASS | Production init dispatch, early guard, stale token rejection and no previous-boot mapping replay |
| Explicit OFF persistence | PASS | Production boot dispatch keeps stock DNS, no Native interception, issued-pool quarantine retained |
| Production stop/start/restart | PASS | Exact production init dispatch; stopped routing stays closed and stock DNS remains available |
| Corrupt DNS WAL and subsequent actual OFF reboot | PASS | Classifier failure restores protected stock DNS; fresh Apply exits recovery; actual reboot retains OFF and quarantine |
| Software/hardware offload | PASS for refusal | Configured offload/live flowtable rejected; hardware coexistence unsupported |
| Physical Xiaomi, real AWG, actual WAN and apps | SKIPPED | Requires fresh inventory, backup, local autonomous rollback and controlled installation |
| Multi-hour load / flash wear / abrupt power loss | SKIPPED | No long-term stability claim |

Workstation regression: 55 smoke tests PASS, six OpenWrt/UCI-dependent tests
SKIPPED on macOS and executed successfully in the OpenWrt regression fixture.
Go race tests PASS. Shell/JS syntax, JSON, gettext validation, i18n coverage,
real LuCI LMO catalog and diff whitespace checks PASS.

The writable VM completed three actual reboot transitions: confirmed startup,
rollback of an unconfirmed generation from the previous boot, and persistent
explicit OFF. Both `/etc/pkc-permanent-vm/PASS` and `EXTENDED-PASS` were observed.
No critical local acceptance failure remains open. Physical release qualification
is still separate; this record does not authorize automatic household cutover.

The procd contract was checked against the guest's `/lib/functions/procd.sh`
and [upstream instance parsing](https://github.com/openwrt/procd/blob/master/service/instance.c).
The final coordinator sends decimal strings in the respawn array. Actual ubus
readback must show threshold 3600, timeout 1 and unlimited retry 0; both integer
arrays and object-form mistakes are rejected by the VM assertions. Interrupted
processes must not produce an unthrottled restart loop.

The broad namespace regression captured zero protected packets and zero
plaintext upstream DNS packets on its virtual WAN, alongside 72 positive
Direct controls, 59 endpoint controls, 151 primary and 24 backup packets.
Its autonomous recovery capture recorded zero synthetic packets and eight
positive Direct controls. These are virtual packet-capture results, not
physical Xiaomi WAN evidence.

## Resource And Installation Contract

Extended-fixture classifier samples: 11 FD, 6360..6392 KiB RSS, namespace conntrack 8.
This is a small test workload, not a household CPU/FD capacity prediction.
VM validation measured 116 KiB snapshot and 6697 KiB coordinator budget; the
fixture deliberately embeds the full helper in recovery copies. The production
package uses one immutable helper and tiny launchers, so its measured budget
must be obtained again with `podkopchikctl validate` on the actual installation.

The component installer reserves 8 MiB untouched flash, 4 MiB bounded WAL and
1.5 MiB code/snapshot allowance, in addition to the rounded new helper size.
Native validation separately measures the actual source/snapshot requirement.
Both require at least 48 MiB free tmpfs and 96 MiB available RAM. Previously
reported 21 MiB flash is not a fresh measurement or permission to delete data.
With the production launcher, the current coordinator estimate is 931 KiB
before the measured UCI/AWG snapshot. A 116 KiB fixture-sized snapshot gives
13335 KiB required free flash after installing the 5764 KiB helper; the helper
installer's initial 19588 KiB gate is slightly more conservative. Larger real
profiles/backups and retained helper versions must be added, not assumed away.
Budget at least 64 MiB tmpfs before archive staging so that 48 MiB remains after
copying and unpacking. No claim is made that Xiaomi's present flash fits until
fresh physical preflight measures its private configuration and recovery set.

Build with `tools/build-native-candidate.sh` twice, compare the complete archives
and run `tools/verify-native-candidate.js`. Final artifact hashes are recorded
after these checks below. The archive contains no user UCI, AWG profiles,
private backup or production VLESS links. Public deterministic test keys in
source fixtures are laboratory data, not deployment credentials.

Two independent final full archives compare byte-for-byte:

- `.build/native-final-a/podkopchik-native-ax6000-candidate.tar.gz`
- `.build/native-final-b/podkopchik-native-ax6000-candidate.tar.gz`
- Archive: 2,539,082 bytes; 84 manifest files; 6,634,838 unpacked file bytes.
- Archive SHA256: `5beeed44449a80902aa2f67eae23c26e726cdadb6f5a9aa6c7f7cf0ae45ec72a`.
- ARM64 helper: 5,898,366 bytes; SHA256
  `5e37df750d38589f8380787f4bc0ada32529953715bebb2a9038a428f1c403cf`.

The verifier checked manifest coverage, every SHA256, ELF64/AArch64, bounded
sizes, root UID/GID, relative archive paths and absence of links/special files.
The final archive's helper preflight/install was exercised under an isolated
VM staging root; repeated installation verified and reused the immutable helper.
This is not a claim that its physical-board gate was bypassed or tested on Xiaomi.

## Physical Procedure And Rollback

1. Recheck Xiaomi identity, all pools/addresses/routes, offloading, space, AWGs,
   DNS, management paths and actual package/source versions, read-only first.
2. Save the full private backup on the Mac; keep only the measured minimum local
   recovery set. Verify SHA256 and autonomous recovery before household cutover.
3. Verify/extract the candidate in private `/tmp`; run component `--preflight`,
   then its `--install` and the local application installer. Do not run a main
   branch updater over this feature candidate.
4. Admit adequately sized nonoverlapping pool(s), review Direct grants, select
   Native, then ordinary `podkopchikctl apply`. Preserve the fixed supervisor
   deadline; do not auto-confirm from an installer or SSH script.
5. Verify real clients, DNS, every assigned AWG, WAN capture, cached/unknown
   addresses, IPv6, applications and management. Confirm via LuCI Status or
   `podkopchikctl native-confirm TOKEN` only after those checks pass.
6. On failure use `podkopchikctl native-abort TOKEN` or let the timer expire.
   Native-to-Native restores the last confirmed code/configuration. First
   migration instead enters protected stock-DNS recovery, not legacy's implicit
   Direct fallback. Exact domain policy then requires a successful fresh Apply.
7. An operator-authorized return to legacy requires explicit Native cleanup
   first, then a private source/config backup restoration. Preserve allocator
   history and synthetic quarantine; never reset them to recycle addresses.

Strict domain-only Direct cannot establish exact shared-IP identity and is
rejected. DoH/DoT/ECH/literal-IP unknown traffic uses protected fallback or drops.
Explicit Direct IP/device grants intentionally authorize their whole scope.
TTL expiry may end synthetic connections without refreshed DNS; /24 is a finite
test pool, and long-term namespace capacity still requires physical observation.
