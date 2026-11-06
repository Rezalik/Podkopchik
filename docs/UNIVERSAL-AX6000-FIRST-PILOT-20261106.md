# First scoped AX6000 pilot: stopped before test traffic

Base: `fba3b8f` on `feature/universal-routing-engine`. The router's home LAN
was not switched. No package was installed or updated in this phase.

## Physical preflight and rollback

- Independent SSH and LuCI via the Mac and wired `media` on lan2 passed.
- Live inventory and `nft -c` admitted the separate IPv4 pool, transit,
  nft hook priorities, exact mark and separate policy table. Offload was absent.
- Temporary `tcpdump`/`libpcap` files from the signed OpenWrt repository were
  prepared in an isolated VM and verified after transfer to `/tmp`. No package
  was installed on the router. The non-promiscuous physical WAN and AWG control
  captures contained 15 and 35 packets respectively, with zero kernel drops.
- A 25-second independent procd deadline with a **down, unaddressed** veth
  removed the actual trial table, tagged firewall4 handles, exact policy rule,
  both routes, veth, namespace and watchdog. A new SSH connection through
  `media` observed the already-restored journal and checked kernel state.

## Stopped launch

The active runner was armed with a 125-second watchdog. It stopped on
`cannot open DNS policy` before starting the classifier or raising the client
endpoint, so **no protected, direct, DNS, TCP, UDP or QUIC pilot traffic was
sent**. Both capture filters saw zero matching packets during the failed start.
That zero is not a leak result: there was no test traffic or active positive
control in that window. HTTPS controls before launch only validate capture and
existing transport availability.

The transferred file was mode 0600 but owned by macOS UID 501, GID 20. Its
SHA256 was correct; ordinary `tar` had preserved host metadata. The classifier
correctly rejected it because its policy must be owned by the running user
(root), mode 0600, and a regular file with one hardlink. Do not loosen that
check. The corrected `tools/pack-ax6000-scoped-pilot.sh` emits root-owned tar
entries, and the arm script initializes only the private ledger before any
kernel changes. OpenWrt VM reproduced the original failure and initialized
the ledger with the corrected bundle without starting a listener. This fix
was not redeployed to the Xiaomi in this phase.

After the stopped launch the watchdog completed rollback. All 17 household
baseline sections matched, including packages, UCI/Xray hashes, nft rules,
IPv4/IPv6 routes and policy rules, PIDs, AWG links and boot ID. Test services,
interfaces, routes, rules and temporary files were removed. Home DNS, WAN
HTTPS, SSH, LuCI and existing AWG controls are distinct from acceptance of the
new native forwarding path. Real native TCP/UDP/QUIC, direct fallback, DNS
isolation under load and no cleartext protected traffic on WAN remain untested.
