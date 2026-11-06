# Universal Routing: Mixed Transport Canary

This is a locally qualified preview, not an installer or a LuCI update. The
production Podkopchik lifecycle, UCI, default routes and Xray binary are not
changed. The approved physical read-only baseline is Redmi AX6000 stock,
OpenWrt 25.12.6, Linux 6.12.112, with 21,488 KiB available on `/overlay`.

## DNS and Packet Path

Gating a real A/AAAA reply on an nft acknowledgement is useful, but does not
identify a domain on subsequent IP packets. If direct, AWG and VLESS policies
share a CDN address, even a per-client real-IP set is ambiguous: one client
may use all three names concurrently. TTL and SERVFAIL cannot retract an IP
already cached by a client. A real-IP implementation would have to over-route
all traffic for that IP, drop conflicts, or accept a possible direct fallback.
It is not an equivalent replacement for selective domain routing.

The resolver keeps dnsmasq as the upstream. Direct A/AAAA remain real; ordinary
LAN labels and filtered PTR work without publishing a route. A protected
A/AAAA uses a synthetic address keyed by policy and real destination. A CNAME
chain contributes its minimum TTL; conflicting protected policies are refused.
Only after the kernel acknowledges **both** timed set membership and DNAT in
one batch does the resolver return the protected address. Failures, including
cache-hit refresh failures, return empty SERVFAIL. HTTPS/SVCB hints remain
suppressed. Other RR types, DNSSEC rewriting and full household LAN DNS are
not part of this canary.

For native AWG the nft classifier sets the adapter mark on the original
destination, then kernel DNAT restores the real IP. The IP rule selects the
AWG table; a terminal unreachable route and independent egress guard prevent
WAN fallback. TCP, UDP and QUIC use this same packet path, without Xray.
Kernel leases expire after DNS TTL plus grace. The helper releases expired
in-memory bindings, but never recycles an issued address in a generation.
The persistent high-water mark survives process death, reboot and rollback.
A full pool returns SERVFAIL; automatic rotation and endurance are not qualified.

For a selected VLESS policy, the same DNAT is followed by TCP TPROXY to the
dedicated Xray inbound. Only successful TPROXY sets the delivery mark and local
policy route. Failed delivery or unsupported UDP is dropped. Stock Xray's
[transparent listener](https://xtls.github.io/en/document/level-2/tproxy) receives
the post-DNAT destination in the VM; each inbound has one VLESS outbound and
the default outbound is blackhole. There is no Xray DNS, AWG outbound or direct
outbound in that process. This requires no patch to the Xray core. Native AWG
remains usable if the VLESS process is stopped. Switching an automatic policy
preserves the lease; existing TCP sessions may reconnect.

## Pool and Migration Boundaries

- Xiaomi's installed Xray occupies all of `198.18.0.0/15`. Never take a subnet
  from it. The VM alone uses `100.127.253.0/24` and `2001:2::/48`; no physical
  candidate has been selected. In particular CGNAT space can be in use by the
  ISP or a VPN. Snapshot both families of interface addresses, all route tables,
  destination-based policy rules, endpoint addresses/exclusions, and all
  previously issued pools. Validate planned and current inventory and ensure
  no local consumer needs the range before activation. Dynamic WAN/VPN changes
  must invalidate admission, not silently introduce a conflict.
- The independent quarantine covers both old and native pools and does not
  rely on the classifier or Xray. Do not release it when restoring DNS. An
  issued pool stays reserved until all references and stale clients are retired.
  Preserve local legacy FakeDNS delivery and its replies on the explicitly
  listed old LAN only. That exception never permits old fake addresses to WAN.
- The strict canary forward guard permits only marked packets on the expected
  AWG interface; VLESS is delivered locally. Unclassified traffic from that
  segment does **not** go direct, including cached real IPs, hard-coded IPs and
  an alternate DNS endpoint. This deliberately denies ordinary direct internet
  on the canary, not on the household LAN. Outside that scope an unknown real
  address cannot be identified as belonging to a protected domain. DoH/DoT and
  literal IPs cannot be classified by intercepted DNS; do not advertise a
  general encrypted-DNS block or claim domain policy for those clients. The
  actual upstream transport used by dnsmasq is a separate privacy check; the
  VM uses a local synthetic upstream and does not test ISP DNS traffic.
- Use a dedicated, verified test LAN interface, not the running household
  `br-lan`. An accept in one base chain does not bypass later legacy TPROXY
  hooks. Recheck existing DNS redirect/TPROXY interface matches, marks, local
  tables/priorities, port ownership and offload before binding a canary. Keep
  the management path independent. No production change to existing AWG
  profiles, dnsmasq, firewall4 or Xray is required merely to stage files.

## Deployment and Recovery Gates

Follow the [VM reproduction and two-phase sequence](UNIVERSAL-RELEASE-VM-20261106.md).
The current archive does not enable services or install a production watchdog.
It must not be extracted into `/` or applied via LuCI. A physical trial still
needs a dedicated canary interface, an approved live inventory, a reviewed
ownership controller and a locally persistent recovery bundle that restores
the matching legacy DNS and policy before releasing the canary. Keep both
quarantines armed across an unconfirmed reboot. Do not rely on SSH or a
Mac-side timer for recovery. Do not overwrite the existing Xray or restore an
older synthetic high-water mark.

Budget the compressed archive and its unpacked copy in `/tmp`, not on flash;
do not unpack a second copy onto `/overlay`. Count the exact deployed payload,
configuration and rollback bundle on the actual device before writing it.
Budget at least 4 MiB free overlay margin after writing both bundles. The full
private backup belongs on the Mac, never in the repository or an issue. The
legacy application stays installed; only the minimum verified recovery state
needed by the independent watchdog should occupy additional router flash.

### Reproduce

On the workstation with Go 1.26.10 and the OpenWrt lab dependencies:

```sh
GO=/absolute/path/to/go1.26.10/bin/go sh tools/prepare-native-dns-vm.sh
sh tools/run-native-reboot-vm.sh
```

Follow the serial guest instructions in the release qualification report.
The runner has no virtual NIC. `prepare-native-dns-vm.sh` builds an unmodified
Xray v26.3.27 from pinned upstream source. QUIC uses a test-only Go dependency
and ephemeral certificates; neither the test binary nor Xray is in the review
archive. The native helper runs without a compiler on OpenWrt.

### Results

| Check | Result | Evidence |
| --- | --- | --- |
| Pool inventory | PASS | The legacy /15, existing LAN/VPN routes and retired pools reject overlaps. The different laboratory range passed both planned and live namespace inventory. |
| Managed DNS | PASS | UDP/TCP, IPv4/IPv6, dnsmasq local names and PTR, CNAME, TTL, concurrent clients and alternate plaintext DNS. Real nft failure gives empty SERVFAIL; partial insert is absent. |
| Native and mixed traffic | PASS | Real QUIC TLS/stream plus UDP and TCP in both families over kernel routing; unmodified Xray VLESS TCP on the same real CDN address. Native survives Xray stop; new TCP flows switch AWG to VLESS and back without changing the DNS lease. |
| Strict migration boundary | PASS | Dedicated canary capture saw 0 direct client packets and 6 router-to-VLESS endpoint packets. A known old fake-IP kept working on the legacy LAN, was denied on the canary, and worked after rollback. A focused VM test confirmed direct TCP to the private VLESS listener port was dropped. |
| Reboot and rollback | PASS | Full mixed suite before/after actual VM reboot, persisted ledger, firewall4 reapply, DNS SIGKILL/recovery and independent timeout rollback. On each boot the virtual WAN capture had 0 protected packets and 56 direct control packets; after rollback 0 synthetic and 8 direct. |
| Hardware acceptance | SKIPPED | No changes or active tests on Xiaomi. AWG data links are veth stand-ins; real AWG encryption/REALITY, WAN hotplug, MediaTek PPE and physical WAN capture remain separate. |
| Production promotion | FAIL (gate not met) | No physical pool or canary segment has been selected. Actual device rollback, full household DNS, pool rotation and prolonged resource use have not passed. |

Host smoke: 51 PASS; five host skips for OpenWrt/Xray dependencies passed in
the guest. Ten Go race-enabled runs, `go vet`, shell syntax, generated JSON,
the ucode planner smoke and `git diff --check` passed. The isolated VM used
firewall4 rendering and nft reapply; the physical firewall service and an
autonomous rollback against household state have not been exercised.

### Backup And Space

The requested backup was streamed over an authenticated SSH connection to the
verified Xiaomi, without writing an archive or changing services on the router.
It covers `/etc` (including active configuration, network/DHCP/firewall, AWG
profiles, Xray configuration, and SSH material) and the installed application
files and current Xray binary. This is a configuration and application backup,
not a raw NAND dump. It is ignored by Git, with directory mode `0700` and files
`0600`. SHA256, gzip integrity, tar parsing and required members passed. An
exact copy of this configuration was not applied on the device or imported
into the test guest. Use a fresh verified snapshot before an authorized trial.

After authorization, repeat the read-only capture on the Mac:

```sh
sh tools/backup-native-ax6000.sh --capture-xiaomi
```

- Full archive on Mac: 11,098,785 bytes compressed; 31,398,912 bytes as tar.
  The uncompressed transfer file is removed after validation. Neither copy
  is stored on the router.
- The measured legacy network, DHCP, firewall, Podkopchik and active Xray
  configs total 24,904 bytes. The reference trial/preflight/watchdog helpers
  total 4,795 bytes. These are size references, not a tested physical bundle.
- ARM64 review archive: about 2.2 MiB compressed and 5.6 MiB of unpacked
  files. It does not include a new Xray binary or the full private backup.
- Reserve up to 6 MiB for the native payload, 2 MiB for candidate configuration
  and atomic state writes, 1 MiB for a measured local recovery bundle, and
  4 MiB for overlay margin (13 MiB total). Keep at least 12 MiB in `/tmp` for
  archive plus unpacked files and scratch. Reject larger bundles or insufficient
  free space; measure again immediately before the real trial. Do not retain a
  second complete install or Xray binary on flash for this canary.
