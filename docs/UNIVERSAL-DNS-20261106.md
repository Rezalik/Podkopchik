# Universal Routing: Transactional DNS Laboratory

2026-11-06. Base: `feature/universal-routing-engine` at `939f55a`.
The only test target this session is a disposable VM on the Mac. Neither
`openwrt` nor `openwrt2` is contacted. No automatic install, UCI changes, router
service actions, or production defaults are introduced by this branch.

## What Changed

Stock dnsmasq-full populates nft sets as a side effect of processing DNS. It
can still deliver an answer when updating a set fails. Gating the reply on a
successful *real-IP* set update would fix that failure but would still leave
shared CDN addresses, out-of-date client caches, and ambiguity across policies.
This preview instead distinguishes protected DNS answers from ordinary public
addresses in the data plane. See the [previous failure reproduction](UNIVERSAL-ROUTING-20261105.md).

1. The standalone helper resolves one IN A/AAAA query via a configured upstream.
   It follows the answer's CNAME chain, does not publish unrelated records, and
   uses the minimum relevant TTL, capped at 300 seconds. An alias crossing two
   different protected groups, a DNS rebind to a local/forbidden address, or an
   ambiguous response fails closed.
2. For each protected address the helper durably reserves an ID, then creates
   its policy-set membership and its synthetic-to-real DNAT entry in a single
   nft batch. It answers only after kernel acknowledgement. A failed or timed
   out transaction returns SERVFAIL, not the real address. Repeated queries can
   share upstream/cache results, but even a cached answer needs an acknowledged
   transaction. Direct DNS remains independent.
3. The planner classifies on the synthetic destination before DNAT. The existing
   per-AWG mark and policy route select the transport. Selection-only changes
   preserve DNS leases and DNAT maps. A separate egress gate checks the original
   conntrack tuple even after translation, and accepts only a matching mark and
   expected tunnel interface. An unknown or expired synthetic address is blocked.
   nft hook/NAT semantics: [nftables manual](https://netfilter.org/projects/nftables/manpage.html).

The durable ledger stores only a configuration hash and two high-water marks,
not DNS history or keys. The ledger and policy files must be owner-only regular
files (0600), with the ledger in an owner-only directory (0700). The ledger
must not be rewound on rollback. Lease time in the
kernel includes a 30-second grace beyond DNS TTL. An expired mapping is not
reassigned: stale traffic stops rather than being delivered to another server.
A pool has at most 65,536 allocations per family per generation; exhaustion
returns SERVFAIL. Rotation, disk endurance and real traffic load remain release
gates. The current preview intentionally favors correctness over flash writes
or DNS transaction throughput.

The managed LAN plan rewrites plaintext UDP/TCP 53 to concrete IPv4/IPv6
listener sockets before route selection. Stock dnsmasq is left running and
serves as the helper's upstream on loopback. A client cannot query the private
listener port directly, reach stock port 53, or forward port 53 to the WAN
while the guard is active. When the helper is stopped, managed plaintext DNS
is unavailable until recovery; direct HTTP to a known address still works.
The firewall4 forwarding fragment is appended after existing forwarding rules
and only accepts packets matching the LAN interface, native mark and tunnel.

## Reproduce the Offline VM

The host uses the existing UTM 4.7.5 QEMU library via a small local launcher,
not a system install. The guest uses [official ARM64 OpenWrt 25.12.6](https://downloads.openwrt.org/releases/25.12.6/targets/armsr/armv8/),
Linux 6.12.112 and nftables 1.1.6, no virtual NIC and a read-only 9p share with
only synthetic fixtures and build outputs. Guest dependencies are installed
from signed OpenWrt indexes for the exact guest kernel ABI. No DNS or routing
commands are sent outside the guest.

The original results below used a patched v26.3.27 Xray fixture. The current
runner uses unmodified upstream Xray; see the
[mixed transport canary](UNIVERSAL-MIXED-CANARY-20261106.md). Use Go 1.26.10:

```sh
GO=/absolute/path/to/go1.26.10/bin/go sh tools/prepare-native-dns-vm.sh
sh tools/run-native-dns-vm.sh
```

After the serial prompt, in the guest only:

```sh
mkdir -p /mnt/lab
mount -t 9p -o trans=virtio,version=9p2000.L,ro pkclab /mnt/lab
sh /mnt/lab/setup-native-dns-guest.sh
poweroff -f
```

The last command powers off the VM and discards its RAM-only installs, routes,
leases and captures. It is not a command to run on Xiaomi. The helper and test
binary can also be built with `tools/build-native-dns.sh`; the outputs and
SHA256 manifest live under `.build/native-dns`, outside Git. No Go compiler or
runtime package is needed on the guest to run the cross-built executables.

## Test Results

| Scenario | Result | Evidence |
| --- | --- | --- |
| UDP/TCP queries, cache, CNAME, TTL, rebinds, truncated UDP and TCP retry | PASS | DNS protocol tests on Mac loopback and OpenWrt; 24 concurrent clients and 10 race-enabled Mac runs |
| Actual DNS reply after nft commit | PASS | OpenWrt UDP/TCP with `nft` 1.1.6, both address families, eight concurrent clients |
| Managed LAN DNS, alternate resolver and private listener | PASS | Port 53 over IPv4 and IPv6, UDP and TCP; a direct query to the private listener is blocked |
| Listener stop and redirect loss | PASS | Stock dnsmasq and alternate resolvers did not receive a client fallback; direct HTTP stayed up |
| Actual firewall4 rules and reapply | PASS | Marked tunnel traffic was blocked without the include, passed with it, and retained leases on reapply. An explicit LAN reject still won. |
| Explicit DNS rollback | PASS | Stock dnsmasq returned DNS again; old native IPv4/IPv6 synthetic addresses still dropped |
| nft failure and direct DNS | PASS | Missing group set produced empty SERVFAIL for a cached query and a two-address reply; ordinary direct DNS kept working |
| Kernel transaction rollback | PASS | Duplicate `create element` rejected with EEXIST and the first map entry in the batch was absent |
| TTL expiry and guard after table loss | PASS | Actual map timeout and no address reuse; unknown pools, stale addresses and an established DNAT flow were blocked |
| Native forwarding and failover | PASS | IPv4/IPv6 TCP/UDP, primary and backup veth adapters, missing policy rule, all-down and recovery |
| Separate VLESS and endpoint bypass | PASS | Local Xray 26.3.27 client/server returned HTTP 200 while native selection was all-down |
| Virtual-WAN egress | PASS | Final run: 0 protected, 0 plaintext DNS, 32 direct, 6 endpoint, 86 primary and 16 backup packets |
| Xray 26.10.31 in the initial VM | FAIL | ARM64 runtime unwind fault in the two-vCPU TCG run; final fixture uses Xray 26.3.27 and single-thread TCG |
| Hardware AWG 3.1, physical WAN, REALITY, mixed adapter and rollout | SKIPPED | Not exercised; neither router was contacted |

Local smoke suites: 51 PASS; the five skipped on the host for missing native
OpenWrt tooling also passed in the guest. `go vet`, shell syntax, `git diff --check` and independent
byte-for-byte rebuild checks passed. The ARM64 helper SHA256 is
`be95cd5a4146e9f3c545dff715f98edacba083ddbd00170b53cba3815eccee33`.

## Deployment and Recovery Gates

There is no production installer or selectable native mode in this preview.
Before an approved real-device canary, finish the persistent procd lifecycle,
firewall4 service and include ownership, offload preflight, and the runtime
controller that switches or rolls back generations. The VM exercises firewall4
render and nft reapply, not restart or stop of the system firewall service.
The native pool must not overlap any LAN, WAN, local route, tunnel endpoint,
exclusion or *previously issued* FakeDNS pool. Do not reuse the current Xray
pool or assume that RFC6598/ULA space is unused. Validate the actual routes,
stage an independent guard and an independent recovery timer before changing
LAN DNS, and validate the existing Xray configuration before any rollback.
Keep the old pool ledger and guard active while stale answers or conntrack
translations may still exist. Restore the previous DNS and matching last-known
working transport/runtime before removing new owned classification state.
The fixture's explicit rollback removes only three owned DNS chains and the
scoped fw4 include; it keeps the address quarantine. On a live system, existing
DNS conntrack entries can retain translation temporarily, so verify both new
and reused client connections without flushing unrelated conntrack state.

This experiment protects traffic using answers from its managed listener. It
does not claim control over literal-IP connections, old real-address caches,
DoH/DoT or other resolvers. Protected and direct DNS are A/AAAA only in the
fixture; the helper suppresses HTTPS/SVCB hints, refuses other record types,
and does not preserve DNSSEC signatures on rewritten answers. Serving full LAN
DNS requires a separate, tested integration that preserves DHCP and local DNS.
Other firewalls, manual flushes, flow offload and ownership violations are not
covered by the sandbox result. Hardware WAN capture, live AWG 3.1, REALITY,
mixed policy-driven AWG/VLESS failover and long-load acceptance must not be
inferred from the VM.
