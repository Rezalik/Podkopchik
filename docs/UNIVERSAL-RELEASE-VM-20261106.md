# Universal Routing: Release Qualification on the Offline VM

Base: `db0f427`, branch `feature/universal-routing-engine`. Neither `openwrt`
nor `openwrt2` is accessed. Only the Mac workspace and disposable OpenWrt VM
are used. The packet-path design is unchanged. The new work covers lifecycle,
trial state, offload admission and an ARM64 package for review.

## Lifecycle and Rollback Boundaries

The [OpenWrt procd](https://openwrt.org/docs/guide-developer/procd-init-scripts)
fixture owns DNS helper, stock dnsmasq, and synthetic Xray client/server
processes. In the lab it installs the independent pool guard before bringing
up WAN, then prepares policy routes, firewall4, the classifier and stock DNS.
Only then does it install the separate LAN DNS redirect and start managed DNS.
A stop or crash does not release the DNS or fake-pool guard. New protected
replies still require the atomic nft transaction; stale addresses cannot be
reassigned.

An independent procd watchdog consumes a root-only trial journal. The journal
uses `flock`, an atomic replacement, a monotonic deadline and the boot ID.
`armed` must become `verified` before `confirm`; expiration or an unconfirmed
reboot moves the trial to `rollback`, which cannot be confirmed. The VM's
watchdog verifies its snapshot and tests the old dnsmasq on loopback before
restoring the old firewall4 rules and releasing managed DNS. The fake-address
guard is not released. The watchdog's code and snapshot are separate from the
managed DNS process. The fixture proves timeout and restoration without a
management session executing the rollback; it is not a live-router installer.

### Offload Policy

Reject software and hardware offloading rather than attempting to coexist.
[Linux flowtable forwarding](https://kernel.org/doc/html/latest/networking/nf_flowtable.html)
can bypass the classic hooks used by the classification/egress guard. The
read-only preflight rejects either enabled UCI option and any live nft
flowtable, including a manual table. It does not change firewall settings or
flush conntrack. Admission requires verifying the actual device and draining
pre-existing accelerated flows under a separate approved change. VM coverage
does not establish anything about the MediaTek hardware accelerator.

## Reproduction

Prepare the fixture from [the DNS laboratory](UNIVERSAL-DNS-20261106.md). Use
the official [OpenWrt ARM64 EFI image](https://downloads.openwrt.org/releases/25.12.6/targets/armsr/armv8/)
`openwrt-25.12.6-armsr-armv8-generic-ext4-combined-efi.img.gz` as
`.build/universal-dns-vm/openwrt-efi.img.gz`, then run:

```sh
sh tools/run-native-reboot-vm.sh
```

The runner checks the official image SHA256 and creates a private writable
guest disk. It refuses to overwrite a prior disk. There is no virtual NIC,
and the only host share is the read-only synthetic payload. In the guest:

```sh
mkdir -p /mnt/lab
mount -t 9p -o trans=virtio,version=9p2000.L,ro pkclab /mnt/lab
sh /mnt/lab/install-native-vm-boot.sh
```

After the first suite succeeds the **guest** reboots. Its installed S98
fixture automatically runs again. Read the guest's root-only `first.log` and
`second.log` under `/etc/pkc-native-vm-state`; `reboot-pass` marks success.
Power off the guest to end the run. No command in this section is for Xiaomi.

Build the unsigned review archive on the Mac with the pinned Go toolchain:

```sh
sh tools/build-native-ax6000-review.sh
cd .build/native-ax6000-review
sha256sum -c podkopchik-native-ax6000-25.12.6-REVIEW.tar.gz.sha256
```

The archive uses fixed file order, ownership, timestamps, and gzip metadata.
It targets Linux ARM64; it contains no kernel module or OpenWrt package
scripts. Validate the archive against an independently communicated digest
before using its internal manifest. A digest alone is not a signature.

## Acceptance Results

| Scenario | Result | Evidence and limits |
| --- | --- | --- |
| Reboot and early quarantine | PASS | Full suite passed on both sides of an actual EFI guest reboot; automatic S98 startup, prior-boot trial confirmation refused, persisted synthetic IDs not reused. The pool guard was installed before test WAN, with zero synthetic packets and two positive-control DNS queries on each boot. |
| Lifecycle in the guest | PASS | Stock dnsmasq, managed DNS and local Xray/VLESS are supervised by procd. Managed DNS stop/start and SIGKILL recovery use the persistent ledger; stopping Xray does not stop native forwarding. |
| Classification and concurrency | PASS | IPv4/IPv6 DNS UDP/TCP, TTL, cache, CNAME and 8 simultaneous VM clients during repeated selection changes. A real failed nft batch leaves no partial entries; a missing classification set produces empty SERVFAIL. |
| Policy and link failure | PASS | Same-policy reapply, veth backup/all-down/recovery, loss of a policy rule, test WAN link down/up and dual-stack route restoration. Direct HTTP survives transport failure; native forwarding and local VLESS remain independent. |
| Flow offload admission | PASS | Both firewall UCI flags and a real software flowtable were rejected; no settings were changed. |
| Fail-closed packet capture | PASS | On each boot, virtual WAN saw 0 protected and 0 plaintext DNS packets during managed operation, with 40 direct and 6 VLESS endpoint packets as controls. Primary/backup links saw 102/16 protected packets. |
| Independent timeout rollback | PASS | The watchdog restored stock DNS and retained quarantine without a console rollback command. After rollback on each boot: 0 synthetic and 8 direct packets on virtual WAN. |
| ARM64 reproducibility | PASS | Separate Go caches produced identical ARM64 helper/test executables and review archives. The helper matches the guest artifact; all archive member hashes match the manifest. |
| Active flow offload and hardware hotplug | SKIPPED | Running with offload enabled is unsupported. MediaTek PPE and WAN netifd/DHCP events were not exercised. |
| Physical WAN and live transports | SKIPPED | Packet captures were on virtual Ethernet. Real AWG 3.1, REALITY, mixed native/Xray deployment, boot and long load on Xiaomi remain untested. |
| Production promotion | FAIL (gate not met) | A general LAN DNS integration and a device activation/rollback controller are still required; the tested watchdog and boot fixture are VM-only. |

Host smoke: 51 PASS, five OpenWrt/Xray-only cases skipped on Mac and passed
in the VM. Go race tests (10 repetitions) and `go vet`, shell/ucode/JS/JSON,
gettext, i18n coverage, and `git diff --check` passed. The guest's Xray
fixture uses 26.3.27 and synthetic VLESS, not the current device core.
The helper's SHA256 is
`be95cd5a4146e9f3c545dff715f98edacba083ddbd00170b53cba3815eccee33`.

## Two-Phase Device Procedure (Not Yet Authorized)

The review archive has a binary, manifest, read-only AX6000 preflight, procd
registration and trial-state helpers, and policy sources. It has no APK
postinst, UCI defaults, or auto-enable or activation script. It must not be
extracted into `/`. The signed OpenWrt VM packages are not part of the archive
and must not be installed on the physical router. The repository `main` stays
unchanged. There is no default installation path for the preview.

1. **Preflight.** After explicit approval, inventory board, firmware/ABI,
   free overlay and RAM, current firewall4 includes/offload, actual
   IPv4/IPv6 routes, endpoint bypass, DHCP, and the healthy legacy DNS path.
   In a private staging directory verify the archive and all payload hashes.
   Run `sh preflight-ax6000.sh` only then; it does not change routing. Ensure
   new pools are disjoint from local/WAN routes and all previously issued
   FakeDNS addresses. Verify local admin access and a separate recovery path.
2. **Backup.** Make an encrypted or root-only full configuration backup
   (`sysupgrade -b` is backup only) plus the previous Podkopchik binaries,
   configs, AWG profiles, dnsmasq/firewall4 configuration, owned nft and
   IPv4/IPv6 policy state. Copy it securely to Mac and verify both digests.
   Keep a locally usable recovery copy. Never include keys or profile contents
   in reports, Git, or the review package. Do not rewind issued-pool ledgers.
3. **Trial.** Stage a separate persistent watchdog and previous resolver before
   changing any client DNS. Verify the watchdog can restore the old matching
   routing and DNS with the management session disconnected. Arm a bounded
   journal, keep the quarantine, and activate only a scoped canary. On error or
   lost health, restore the previous verified DNS and routing; do not simply
   release the guard or send protected queries direct. Never overwrite legacy
   service files or flush the full firewall/conntrack to perform rollback.
4. **Commit.** After the physical checklist and a load observation period,
   verify the trial and confirm explicitly before the deadline. Until then a
   reboot or timeout must not be interpreted as acceptance. Monitor from a
   separate client and keep the previous rollback state available.

Production activation, persistence, backup/restore wiring and interruption
points with existing Stage 4 configuration are not yet exercised. The preview
DNS helper covers A/AAAA, suppresses HTTPS/SVCB hints and is not a full general
LAN resolver: DHCP/local naming, non-address RR types and DNSSEC must be
accounted for before handing it household DNS. Clients using DoH/DoT, literal
IPs, or old real-IP cache entries may bypass the managed DNS classifier. No
claim of encrypted-DNS interception is made. These are gates, not reasons to
try the archive on the family router.

## Required Physical Checks

- Actual Xiaomi LAN/WAN IPv4/IPv6, client DHCP, DNS UDP/TCP and management
  before/after a canary; verify the prior Xray and dnsmasq recovery path.
- Actual AWG 3.1 profiles, endpoint bypass, mixed VLESS/REALITY, one/all-path
  failure and recovery under normal use; WAN/netifd hotplug and route rebuild.
- Confirm offload stays excluded, including MediaTek PPE configuration. Any
  proposed offload support requires separate hardware validation.
- Capture physical WAN for unknown/stale fake-IP and protected flows, including
  IPv6. Verify rollback after process loss and reboot while unconfirmed;
  ensure DNS and ordinary direct traffic recover without SSH.
- Long-load validation with CPU, RAM, flash, FD, conntrack and DNS latency.
