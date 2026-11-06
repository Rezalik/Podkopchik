# AX6000 wired canary and recovery review

This is a local qualification for Redmi AX6000 **stock**, OpenWrt 25.12.6,
Linux 6.12.112. It is not an installer or permission to change a router.
Do not use LuCI update-install to deploy the review archive. No part of the
standard installer enables this trial.

## Addresses and admission

- Synthetic IPv4: **172.31.253.0/24** (254 usable leases). Explicitly approve this
  exact RFC1918 prefix in the generated policy as `private_pool` and in the
  inventory review; no other private pool is enabled implicitly. Actual LAN and
  remote private upstream destinations remain ineligible for protected DNAT.
- Canary link: **172.31.252.0/30** (`172.31.252.1` on the bridge, one trusted
  test client at `.2`). Never assign an address from the synthetic pool to a
  link or advertise the pool. No canary IPv6 in the first physical pilot:
  existing AWG profiles have no verified IPv6 source. Deny all IPv6 forwarding
  from the test link; do not modify IPv6 on the home LAN.
- The saved A1 inventory checked 46 routes, 18 policy rules, connected LAN/WAN
  and AWG addresses, endpoint/exclusion networks and the entire legacy FakeDNS
  `198.18.0.0/15`. Both proposed ranges are clear in that snapshot. Review full
  tunnel AWG `AllowedIPs` and default routes separately from specific reachable
  prefixes: `/0` is a transport selector, not evidence of a host collision.
  Recheck every non-default prefix, all policy tables, peer and upstream routes,
  management networks, exclusions, and issued-pool history before activation.
  A snapshot cannot rule out a hidden or subsequently added VPN network.

A protected DNS answer is released only after the classifier commits its nft
mapping. Exhaustion returns `SERVFAIL` for a new lease, not a real address;
existing live leases can refresh. A released/expired lease is not recycled in
that ledger. Do not reset the ledger or reissue a retired pool just to gain
capacity. Watch allocation count during the pilot; a busy LAN may exhaust a
/24, so this is not a recommendation for general deployment.

For a live binding, prerouting checks the published tuple before DNAT, then
classifies the translated packet and uses the selected policy table. Conntrack
pins that tuple to its first transport. Expired/unknown addresses are denied;
an old connection cannot cross to another transport after failover. No new
policy rule or default route is planned for the first AWG-only trial: only
already verified, Podkopchik-owned AWG policy tables may be used. If those
cannot be reused without modification, stop and review a separate plan.

## Autonomous recovery

Review archive: `ax6000-recovery.sh`, `ax6000-recovery-data.uc`,
`pkc-ax6000-recovery.init`, `trial-state.uc`, `native_pool.uc`. A private
root-owned, mode 0700 `/etc/podkopchik-ax6000-trial` holds `spec.json`,
`config.sha256`, `SHA256SUMS`, the trial journal and a two-generation log.
`spec.json` binds the epoch, both pool generations, original lan4 admin state,
and exact owned AWG source addresses. `config.sha256` binds `network`,
`firewall`, `dhcp`, `wireless` and `podkopchik`. Generate these from a fresh
inventory; a local snapshot draft cannot authorize changes. Keep the full
private router backup on the Mac, not another copy of Xray and user profiles on
the router. This rollback works by *not writing* existing configs and by
leaving existing DNS, Xray, Podkopchik, netifd, policy rules, and AWG untouched.
It cannot reconstruct independently edited household files or recover a
damaged root filesystem. Do not combine the pilot with other administrative work.

For an authorized trial, the separate procd service first establishes prior-boot
quarantine, then monitors the monotonic deadline, journal and scoped canary
health. An activation error must explicitly abort the journal; a killed owner
or a lost SSH session needs no further contact and reaches the same rollback
by the deadline. Keep the first wired trial timed; never confirm it. On
reboot the boot ID invalidates an unfinished trial. The worker first installs
independent output/forward/postrouting quarantine for both pools, including
original conntrack destination checks and owned AWG source guards. It then
quiesces only the detached port, stops only epoch-named canary services, removes
only tagged canary fw4 rules and owned native tables, and returns lan4 to
`br-lan` with its original admin state. It never runs `fw4 reload`, restarts
shared daemons, changes UCI, or changes the system default route. If ownership
or the pre-trial hashes no longer match, leave quarantine in place, log, and
retry rather than overwriting unrelated state. A failed guard install is a
critical stop; do not open or leave a test client connected.

## Physical sequence (separate approval required)

1. Identify the lan4 jack and confirm it has no link and is still a member of
   `br-lan`. Keep it unplugged. Keep a wired management client on lan2/lan3 or
   an independent known-working home Wi-Fi path. Confirm fresh SSH and LuCI
   access through that path and record the home's DNS, route/rule and service
   baselines, including the `br-lan` MAC address. In A1, lan2/lan3/lan4 shared
   that MAC; both Wi-Fi links were up. No pending UCI changes, firewall reloads,
   or interface edits.
2. Refresh address admission and resource budgets. Verify the full Mac backup,
   hash the private recovery manifest and all installed candidate files, reject
   pre-existing candidate bridge/tables/services and offloading. Under separate
   authorization, stage the watchdog and its private data on persistent storage;
   place the recovery helpers under `/usr/libexec/podkopchik-ax6000`, install the
   init file as `/etc/init.d/pkc-ax6000-recovery` with mode 0755, and confirm
   startup/respawn before detaching a port. A `/tmp` copy alone is not
   a reboot-capable rollback. Do not arm an unverified watchdog.
3. Arm a short timed journal with the independent watchdog running. Install
   scoped fail-closed and DNS gates before opening the test link; arm failures
   must leave the cable unplugged. Temporarily put lan4 down, detach **only**
   lan4, and enslave it to `br-pkc-test` (alias `pkc-ax6000-<epoch>`). Give the
   test bridge a distinct locally administered MAC not present in inventory;
   verify `br-lan` keeps its original MAC or abort before connecting. Configure
   just the canary /30, its local UDP/TCP DNS and dedicated DHCP,
   and exact, tagged input/forward allowances; no shared UCI, VLAN, DHCP or Wi-Fi
   changes. Use distinct procd service names `pkc-ax6000-{dns,dhcp,xray}-<epoch>`;
   the first AWG-only pilot does not start candidate Xray. Verify the live gate,
   uplink and independent home management path before marking the trial active
   or raising lan4. If netifd/DSA does not leave the port isolated, abort.
4. Connect one trusted device. Verify source-segment restrictions and that only
   test DNS is affected. Test known and unknown/old synthetic addresses, DNS
   UDP/TCP, HTTPS, UDP/QUIC, AWG selection and fail-closed. Capture on the actual
   WAN for both LAN-originated and router-originated traffic; use direct
   positive controls. Check IPv6 cannot bypass, and measure RSS, FD and conntrack.
   Leave the household resolver, Xray and rules unchanged. Client DoH/DoT and
   cached real addresses cannot supply a trustworthy domain classification;
   never allow unclassified forwarding on this test segment.
5. Unplug the canary client before manual rollback (and use only a trusted
   device in case watchdog expiry reattaches the jack to the home network).
   Abort the journal or let it expire. Verify lan4 and the home's route/rule
   baselines, both quarantine prefixes, home DNS and fresh SSH/LuCI. Inspect
   the private recovery log for `restored`; quarantine is intentionally not
   removed. Do not expand the trial to the main LAN without separate approval.

Actual DSA port isolation, physical WAN capture, boot ordering with the Xiaomi
firewall, and real mixed VLESS/AWG acceptance are physical gates. The OpenWrt
VM has a matching logical topology, not an AX6000 DSA switch or the private
household configuration. No physical VLESS result is inferred from the VM.

## Reproduce locally

Use the pinned Go toolchain and cached inputs from the
[OpenWrt VM report](UNIVERSAL-RELEASE-VM-20261106.md). Use the offline
`tools/prepare-native-dns-vm.sh` and `tools/run-native-reboot-vm.sh` harnesses.
The AX6000 recovery fixture uses real nft, procd, dnsmasq and Xray in an
isolated namespace. Compare household PID, UCI hash, route and policy-rule
baselines after deadline, fault, watchdog respawn and reboot recovery.

```sh
sh tools/build-native-ax6000-review.sh "$PWD/.build/native-ax6000-pilot"
sh tools/native-space-budget.sh \
  "$PWD/.build/native-ax6000-pilot/podkopchik-native-ax6000-25.12.6-REVIEW.tar.gz"
```

The budget uses each file rounded up to 4 KiB plus 2 MiB candidate state,
1 MiB recovery (including two 16 KiB log generations), and a separate 4 MiB
safety reserve. The archive and extracted files can coexist in `/tmp`; leave
12 MiB free there for staging and verify available memory independently.
These are conservative staging bounds, not a prediction of UBIFS metadata
or the RSS of a live Xiaomi. The current flash and RAM need a fresh check
before a pilot. Never delete user data to fit the review.
