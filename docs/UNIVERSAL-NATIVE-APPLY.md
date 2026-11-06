# Scoped Native Apply on OpenWrt 25.12.6

Base: `afa1a4c`, `feature/universal-routing-engine`. This is an actual
activation transaction for one isolated virtual client, not a household
LAN migration. `podkopchikctl apply` still uses the working legacy path.

## Transaction and recovery

- Compile the existing UCI intent and inventory with `native-preview`.
  Admit only an owned, unattached, down `pkc-*` veth, `172.31.252.1/30`,
  client `172.31.252.2`, one IPv4 synthetic pool, and AWG adapters. The
  scope denies unmarked forwards, IPv6, and access to router listeners
  other than managed UDP/TCP DNS. This strict canary does not offer
  normal direct service to the test client or support VLESS.
- Require the matching Core guard and its early boot, late Core and
  netifd `ifup` hooks. No guard daemon runs. The hotplug handler repairs
  already-registered quarantine only; it does not enable FakeDNS.
- Arm a private journal and procd watchdog before installing the checked
  nftables batch. The watchdog opens the link and starts DNS. A DNS
  reply requires a committed lease; reverse traffic must still match a
  live lease and the ingress adapter pinned in conntrack. Routing uses
  the existing AWG adapter tables and never starts Xray for this client.
- `native-trial verify` never cancels the fixed deadline. Faults or
  expiration take the isolated link down before removing the owned nft
  rules and stopping the classifier. Caller-provisioned veth/namespace
  ownership stays with the caller. The working DNS, Xray, AWG, default
  route and UCI are not replaced by this transaction.
- Quarantine remains after rollback. The one-time allocation window
  `.32`–`.63` is claimed persistently before DNS can answer and cannot
  be reused by clearing `/tmp`. Never delete the claim or release the
  registered pools to retry. A later pilot needs a reviewed unused
  window and current inventory.

## Reproduce on the isolated workstation VM

Prepare the existing offline VM payload with
`sh tools/prepare-native-dns-vm.sh`. Run the fixture through
`setup-native-dns-guest.sh` inside the NIC-free OpenWrt guest. For boot
acceptance use a fresh EFI disk from `tools/run-native-reboot-vm.sh` and
run `sh /mnt/lab/native-apply-vm-test.sh reboot` in the guest after
preparing its signed lab dependencies. Mount the lab payload again
after the automatic reboot, then run the same script with `post-reboot`.
This uses actual procd, firewall4, netifd, dnsmasq and boot hooks; the
isolated peer is an Ethernet stand-in, not a physical AWG endpoint.

## Results

| Check | Result |
| --- | --- |
| Scoped DNS UDP/TCP, synthetic DNAT and transport selection | PASS in OpenWrt VM. HTTP reached the stand-in; cached real and unknown synthetic destinations did not. |
| Timeout, watchdog `SIGKILL`, lost firewall4 rule | PASS in VM. Temporary routing and procd resources were removed, old nft tables matched the baseline, and the claimed window was not reusable. |
| Real EFI reboot | PASS in VM with netifd `ifup` repair. Both pools regained their blackhole rules; temporary tables and journal were absent, prior UCI hashes matched and dnsmasq answered. The earlier run without the ifup repair retained its nft table but lost the RPDB rules. |
| Guard physical-WAN verification and real mixed traffic | SKIPPED for this build. The VM egress regression exercised a virtual WAN only. |
| Main LAN Native Apply, permanent confirmation and full restore | FAIL as a release gate: not implemented by the bounded controller. |
| Current Xiaomi household baseline | PASS from the workstation: SSH, local DNS, WAN HTTPS and HTTPS over all three running AWG. Legacy routing, Xray and FakeDNS remain enabled. No changes on the router. |

## Physical release gates

The review archive is not an installer. The current AX6000 uses the
legacy runtime and lacks the installed Core guard. Do not arm Native
Apply on it by bypassing the preflight. First qualify the Core guard
installation separately with an independent rollback and a physical
WAN capture, then qualify one client with real AWG and no Xray in its
path. Save a fresh private full backup on the workstation and verify
the router-local recovery payload before either change.

Full migration still needs a household Apply/confirm/restore transaction,
including DNS cutover, direct-policy behavior, autonomous recovery of the
previous config, and boot persistence. Verify mixed transports, failover,
real UDP and QUIC, cached addresses, physical WAN isolation and prolonged
load before treating a build as production-ready. None of those physical
checks is implied by the scoped VM tests.
