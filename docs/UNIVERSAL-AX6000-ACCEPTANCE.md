# AX6000 Controlled Trial

Scope: local development from `38d35bc`, with OpenWrt 25.12.6 in a NIC-free
VM and the earlier read-only AX6000 baseline. This is not an installer. Do
not extract the review archive into `/`, run it via LuCI, or apply this plan
to the household router without authorization. No new Xiaomi snapshot,
profile, package, reboot or configuration change is required for this stage.

## Select And Reserve A Pool

1. Capture both families of addresses (including inactive/alternate networks
   from configuration), all kernel route tables and policy rules. Include
   LAN prefixes, WAN on-link networks and gateways, delegated IPv6 prefixes,
   VPN AllowedIPs/networks even when a tunnel is down, resolved endpoint
   addresses, upstream resolvers, static exclusions and any provider-shared
   address space that can be reached through a default route. Union the
   active, saved and previously issued FakeDNS pools. The old AX6000
   `198.18.0.0/15` is unavailable in its entirety. Do not infer freedom from
   an empty routing table or from a currently disconnected WAN.
2. Keep the resulting JSON privately on the Mac. `inventory.addresses` is
   `ip -j addr show`; `inventory.routes` and `inventory.rules` concatenate
   `ip -4/-6 -j route show table all` and `ip -4/-6 -j rule show`, respectively.
   `inventory.issued`, `.endpoints` and `.exclusions` are explicit CIDR/address
   lists. Use exclusions for configured but unobserved networks, routed
   prefixes, multipath resources not expanded in the snapshot, and unknown
   or provider-reserved ranges. Verify source completeness externally: the
   tool cannot discover unadvertised ISP or VPN routes. Exclude the whole
   RFC6598 block if its use cannot be established. For a newly generated
   IPv6 ULA, use an operator-approved prefix with a pseudorandom Global ID
   per [RFC 4193](https://www.rfc-editor.org/info/rfc4193/).
3. Supply an ordered `candidates` list of approved CIDRs and `required`
   lease counts by family (`{"4":16384,"6":16384}` is an example capacity
   requirement, not a deployment default). `pool-review.uc` selects the
   first disjoint candidate with enough usable offsets in each requested
   family. Public and link-local ranges are ineligible. The software allows
   only the narrow benchmark, Shared Address Space and local IPv6 blocks
   supported by the DNS helper; use benchmark prefixes only in the lab.
   [RFC 6598](https://www.rfc-editor.org/info/rfc6598/) reserves shared IPv4
   space for provider use: this is not an automatic production choice.

```sh
ucode -L /absolute/path/to/review /absolute/path/to/review/pool-review.uc /private/path/inventory.json
```

4. Choose enough offsets for **cumulative** distinct policy/destination
   bindings, not simultaneous clients. Allocations are not recycled in an
   epoch. A full pool returns SERVFAIL; no unqualified automatic rotation.
   Re-run from current inventory before arming and after staging. A topology,
   prefix, endpoint, offload or policy change invalidates admission; abort
   and re-review, never reassign issued addresses. No physical CIDR has been
   selected in this report.

## Flow Safety

The independent gate binds the first classified original-direction packet
to a transport ID in `ct mark & 0xff000000`. It preserves the lower 24 bits.
This is a separate field from the packet fwmark used by `ip rule`. The
classifier and pin run before DNAT; the forward guard checks transport ID,
packet mark and output device after DNAT, including when the classifier is
missing. A different transport on an existing tuple drops, including UDP
that cannot move to TCP-only VLESS. New connections use the new selection;
applications may need to reconnect (UDP may need a new source port). Same
selection keeps its NAT tuple; an expired or deleted lease blocks even a
previously established flow. Do not flush unrelated conntrack state. See
[nftables conntrack and hook semantics](https://netfilter.org/projects/nftables/manpage.html).

One pre-fix virtual WAN capture contained a zero-payload TCP RST with the
source address of the old tunnel after failover. A forwarded-packet rule
does not cover locally generated replies. The independent gate now blocks
packets with a native tunnel source at OUTPUT and POSTROUTING unless the
egress owns that source or is loopback. Supply and verify exact assigned
addresses for each AWG family, including addresses selected by masquerade.
Require no conflict with addresses on WAN, LAN, or unrelated services; a
tunnel address change invalidates the plan. Keep the source guard on rollback.

Before a physical trial verify that no other writer uses this `ct mark` byte
on the canary, none of the packet marks/tables/priorities/listeners collide,
and the existing fw4 and legacy TPROXY hooks exclude the new interface. Do
not start if ownership is unknown or offloading is active. An nft accept
does not override a later base chain. Keep quarantine for issued pools,
including `198.18.0.0/15`, during activation, failure and rollback.

## Phase A: Prepare, Do Not Change Household Traffic

1. Verify board, firmware, exact port/bridge membership, DHCP/DNS and a wired
   management path independent of the proposed test interface. First choice
   is an already unassigned wired port or an approved tagged VLAN to one
   test client. Do not reassign a port used by LAN/WAN, the management session,
   uplink, AP or mesh. Keep existing `br-lan` and its firewall/DNS untouched.
   If isolation cannot be demonstrated from the board inventory, stop. A
   temporary test SSID is a second choice only after an approved Wi-Fi
   maintenance window, since a radio reload can affect other SSIDs.
2. Plan a separate bridge, addressing, DHCP scope and firewall zone for the
   test client. No forwarding into household/management networks and no
   ordinary WAN forward; only scoped marked transport forwarding. Allow
   only necessary DHCP, DNS and vetted IPv6 neighbor/router discovery on
   that zone; no SSH or LuCI exposure. Do not advertise IPv6/default routes
   to the test client until its isolation and policy routes are ready.
3. Refresh the private Mac backup using `backup-native-ax6000.sh` only in an
   authorized maintenance window. Verify digest and readable required
   members, including the existing AWG profiles, DNS and firewall settings.
   Hash the local recovery kit separately. The existing backup stays on Mac;
   no keys or backup archives in Git. The legacy Xray and dnsmasq stay
   installed; do not free space by deleting user files.
4. Reserve overlay and `/tmp` independently. Check the package manifest,
   candidate config and actual recovery file sizes before staging. Keep only
   the previous values for touched objects, validated rollback recipe,
   protected pool ledger, watchdog and journal on flash. Never overwrite an
   earlier backup or roll the allocation watermark backwards.
5. Require a boot-persistent watchdog separate from the application and SSH.
   Arm it before the first activation, with a local health/timeout and
   explicit abort trigger. Rehearse process loss and reject an invalid
   firewall transaction without removing the guard. Restore the matching
   previous DNS and policy before releasing the scoped interception. Keep the
   independent pool quarantine, and retain a safe blocked canary if recovery
   cannot be validated. Check management from the unaffected LAN. No automatic
   reboot on Xiaomi. A reboot of an unconfirmed trial must not confirm it.

The VM watchdog rehearses those transaction properties, not device-specific
recovery. A physical recovery kit with verified UCI object ownership, boot
order, device-specific restore recipes and a usable local recovery path must
be reviewed before staging. The VM fixture is not a script to run on Xiaomi.

## Phase B: One Test Client Only

Keep the test port or tagged VLAN inactive during staging. Recheck the
inventory, validate nft transactions and any dedicated Xray config, then
install the independent quarantine and arm local recovery before connecting
the client. Stage the canary-specific rules and DNS listener without changing
the stock resolver. Verify the listener, routes and recovery service locally;
only then open the test port and issue DHCP. Do not use the canary to manage
the trial. On an abort, keep the gate closed until the previous matching
configuration has been restored and verified from the unaffected network.

| Test | Required evidence |
| --- | --- |
| Isolation and legacy control | Household DHCP, DNS, Wi-Fi, Xray/FakeDNS, management and existing VPNs are unchanged; one wired test client only. |
| Real AWG 3.1 | Handshake and nonzero encrypted transport traffic; verify TCP, UDP and QUIC for each configured family. Verify no Xray instance in the AWG-only test namespace/path (do not stop household Xray). |
| DNS and policy | UDP/TCP DNS, A/AAAA, domain/IP/LAN precedence, cached real addresses and alternative plaintext DNS. Test direct DNS/path controls outside the canary. DoH/DoT classification is not guaranteed. |
| Mixed routing | Test real AWG/VLESS on the same canary and switch primary/backup. No valid VLESS profile means SKIPPED, not PASS. Old flows do not migrate their NAT tuple; new TCP may use VLESS; UDP drops on TCP-only fallback. |
| Fail-closed and captures | Capture on actual physical WAN, including VLAN/PPPoE if present, with endpoint and household direct positive controls. No unencapsulated protected packets; old/unknown fake destinations and sources never hit WAN, even on classifier or policy-route loss. |
| Recovery | Repeat Apply, stop or kill only canary services, inject a scoped firewall failure, disconnect test management, and show autonomous restoration with guard intact. Never restart household DNS/firewall for a probe. |
| Resources | Baseline and peak RAM/CPU, FD, conntrack, disk and DNS latency. Observe real load across reconnects and longer than the VM soak before a wider rollout. |

Abort on any leak, loss of management, unexpected household change, failed
health check, unverified backup, resource limit or unknown ownership. Never
confirm from the same failing control session. Confirm the scoped canary only
after the matrix passes. Household migration requires separate user approval
after that, and is not authorized by this report.

## Results

| Check | Result | Evidence |
| --- | --- | --- |
| Pool selection | PASS | Deterministic offline selection, rejection of insufficient capacity, public/link-local CIDRs, malformed input, WAN gateways, policy destinations, VPN routes, exclusions and retired pools. Live VM address/route/rule inventory admitted only the fixture's disjoint pools. |
| DNS and mixed path | PASS | UDP/TCP DNS, dual-stack kernel DNAT and marks, native TCP/UDP/QUIC, unmodified Xray TCP and a TCP-only fallback that drops UDP. AWG links in the VM are veth stand-ins. |
| Established flows and TTL | PASS | An open TCP flow survives unchanged Apply; the mismatched transport rule drops packets after selection changes, while new TCP succeeds. An expired IPv6 lease cannot use an existing NAT tuple. |
| Pre-fix WAN capture | FAIL | One RST from a tunnel source after failover, with zero payload. The new independent local-output guard addresses that path; the WAN counter is now an explicit hard gate. |
| Corrected WAN capture | PASS | Both IPv4/IPv6 local tunnel-source probes hit the output drop counters. Both full runs: 0 protected/synthetic/inner-source WAN packets, with 64 direct and 43/44 endpoint control packets. After each rollback: 0 synthetic and 8 direct. |
| Reboot | PASS | The persistent VM rebooted and automatically repeated the functional suite. Prior-boot confirmation was refused, previously issued synthetic addresses stayed quarantined, and the allocation ledger was not reset. |
| Recovery fault injection | PASS | procd restarted the killed watchdog; a validly hashed but invalid nft recipe was rejected without releasing DNS interception. With a valid recipe the independent worker restored DNS and kept quarantine. A separate trial killed the actual owner and recovered on timeout with no management connection. This simulates process loss, not a physical SSH failure. |
| Concurrent load | PASS | 2,227 protected queries in 180 seconds while changing selections. Sampled helper FD 11 to 13 to 11; RSS 4,208 to 9,012 KiB; CPU +1,392 ticks; conntrack sampled peak 1,415 and ended at 979. VM measurements only, not sustained household traffic. |
| Physical trials | SKIPPED | Real AWG 3.1, available VLESS profile, hardware/offload, physical WAN capture and long household load are not tested. No remote commands were run in this stage. |
| Installation admission | FAIL | Requires current private topology and mark inventory, a disjoint approved pool, an isolated physical port and a verified Xiaomi recovery kit. No assumption of physical readiness or permission. |

51 host smoke tests passed, with five dependency skips tested in the guest.
Ten Go race runs, `go vet`, shell syntax, ucode smoke, offline pool CLI,
checksums and `git diff --check` passed. No router configuration was changed.

## Reproduce Locally

Prepare and boot as in the [isolated VM instructions](UNIVERSAL-RELEASE-VM-20261106.md).
The first boot runs a 180-second soak with concurrent IPv4/IPv6 TCP/UDP DNS
and six backup/restore cycles. The second boot repeats the functional checks
and tests stale addresses and the persistent journal. After both boots, run
`sh /mnt/lab/native-vm-detached-test.sh` **in the isolated guest only**. It
terminates the process that armed the trial and verifies that procd's independent
timeout still restores the fixture without releasing quarantine. The detached
test deliberately starts with absent owned DNS chains to check idempotence.

## Space Accounting

On the Mac, measure the exact candidate files without unpacking them:

```sh
sh tools/native-space-budget.sh /absolute/path/to/REVIEW.tar.gz
```

The measurement reports archive bytes, unpacked file bytes, a 4 KiB rounding
model, and archive-plus-unpacked staging cost. Overlay planning adds 2 MiB
for candidate config/state and atomic writes, 1 MiB for a bounded recovery
kit, and 4 MiB free margin. Reserve 12 MiB in `/tmp` independently. These are
admission budgets, not exact UBIFS allocation or RAM consumption. Calculate
actual flash delta and measure the physical recovery files separately before
staging. The previous read-only value was 21,488 KiB available on overlay;
do not assume that it still holds. The full private Mac backup is 11,098,785
bytes compressed and is not part of the router budget.
The five legacy reference config files total 24,904 bytes. The six measured
VM recovery files (watchdog, journal code and state, fw4 and DNS release
recipes, digest list) total 8,048 bytes. This is not a physical recovery
bundle: it does not include a device-specific boot service, production
snapshots, ownership data or the persistent pool guard. Use the 1 MiB reserve
as a ceiling to verify, not as a claim about files on Xiaomi.
