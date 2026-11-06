# AX6000 standalone FakeDNS WAN Guard trial

This is the engineering fixture for the legacy guard transaction, not a
standalone product or an approved production deployment. The production
guard belongs to Podkopchik startup, Apply and rollback.

This procedure is for Xiaomi AX6000 stock, OpenWrt 25.12.6 and kernel
6.12.112, with no existing FakeDNS guard installation. It does not install
the Universal Routing Engine, change UCI, or restart DNS, Xray or AWG.
Never arm it without confirmed physical access. Do not run Apply or another
installer concurrently.

## Read-only baseline

The November 7, 2026 Moscow-time baseline had both recurring LAN ICMP Echo
Request flows (clients ending in .244 and .248) to `198.19.28.7`; the
conntrack original sources were in `br-lan` and both reply destinations
matched the WAN IPv4 after masquerade. Per-client route lookups selected
`wan`. This is live conntrack and route evidence, not a new wire capture.
The prior physical capture identified the leak class independently.

The exact two-pool nft batch passed live `nft -c`. The pools did not overlap
current interface addresses, routes, policy selectors, AWG peer destinations
or recorded bypass addresses. All three active AWG peers allowed default
prefixes; neither software/hardware offload nor a live nft flowtable was
detected. Guard files, ledger, nft table and RPDB priority 10992 were absent.
Home WAN and all three AWG returned HTTPS 200. LAN DNS answered over UDP and
TCP; the current Xray returned a synthetic address. Mac reached SSH and LuCI
(HTTP 403 with `x-luci-login-required: yes`, the login response).

Baseline resource sample: 21,476 KiB free overlay, 247,280 KiB free /tmp,
287,864 KiB MemAvailable; Xray 60,244 KiB RSS, 3,513 FD; conntrack
5,754 / 31,232. A separate two-second CPU sample was 1.6% busy. These are
pre-install observations.

## Guard-only trial

1. Recheck hashes of UCI and Xray, nftables, routes, policy rules, peer
   endpoints/AllowedIPs, service PIDs and boot ID. Confirm physical access.
   Do not reuse a staging directory or arm if any installed target exists.
2. Stage a flat root-owned archive at `/tmp/pkc-fake-guard.<16 hex>` (mode
   0700). It contains the trial runner, `trial-state.uc`, the three
   guard/helper files, the boot script, the sysupgrade keep-file and the
   SHA256 manifest. Build it with `tools/pack-ax6000-fakedns-guard-trial.sh`
   and an absolute output archive path. The runner verifies member modes,
   owners and checksums.
3. Before arming, stage the known tcpdump and libpcap binaries in a separate
   private temp directory. Verify their hashes. Do not install packages.
   Observe egress on the actual `wan` with `tcpdump -p -nn -Q out`.
   Filter on both pools and explicit direct/AWG control traffic. Obtain
   nonzero direct controls and no kernel capture drops; optionally correlate
   ICMP ID and address with the LAN interface and conntrack. Keep raw capture
   private and delete it after producing aggregate evidence.
4. Run `sh ./ax6000-fakedns-guard-trial.sh arm "$PWD"` from the staging
   directory. The 150-second monotonic deadline is recorded before procd
   starts the worker. Only that worker installs the files and registers
   both pools. It refuses unexpected ledger/routing ownership. There is
   no persistent startup link yet. `state.txt` must say `active`.
5. Capture attempts to reach each pool directly with ICMP, TCP and UDP.
   Keep the existing LAN/Xray TPROXY intact; do not remove either RPDB rule
   to force a leak. Require zero raw synthetic WAN packets and successful
   positive controls. Check ordinary WAN HTTPS, HTTPS through all three
   AWG, the existing LAN FakeDNS/Xray HTTPS path, DNS UDP/TCP, SSH and LuCI.
   Before `fw4 reload`, check the rendered firewall with `nft -c`.
   Repeat the captures and health checks after reload. Compare household
   hashes/PIDs; ignore only documented guard state and dynamic counters.
6. If any critical check fails, capture is inconclusive, or time runs out,
   do not call `accept`. Explicitly request rollback with
   `sh ./ax6000-fakedns-guard-trial.sh abort "$PWD"` when SSH is available;
   the timeout path otherwise runs autonomously. Confirm the nft table,
   priority-10992 entries, ledger and staged installation files are gone.
   The rollback never calls Podkopchik cleanup or flushes firewall4.
7. Only after all checks pass, call
   `sh ./ax6000-fakedns-guard-trial.sh accept "$PWD"`. The watchdog enables
   the boot link and commits the journal before its deadline. Verify state
   `confirmed` and guard ownership. The disposable staging directory can
   then be removed. A reboot is not part of this test.

The two persistent IPv4 rules are destination blackholes after the Xray
local-delivery rule. nftables checks output/forward and postrouting before
and after source translation. DNAT cannot hide a legacy destination; only
a properly DNATed native flow over an actual AWG device can pass. A
synthetic source used in a legitimate Xray LAN response is not a WAN leak.

## Independent UDP control

`media` at the home LAN address can prove local UDP round trips only. It can
serve as an AWG peer-side test endpoint only if it is independently reachable
behind that tunnel and the two directions can be confirmed in AWG capture;
do not open WAN port forwarding or alter the network for this test.

On a controlled host beyond the selected AWG, build
`native/dns/cmd/pilot-probe` for that host's OS/architecture (Go is not
needed on Xiaomi). Restrict the temporary UDP listener to the intended
source and run `pilot-probe udp-serve SERVER_IPV4:PORT 300`. First verify it
from an independent client. On Xiaomi, use the temporary ARM64 probe:
`pilot-probe udp-echo SERVER_IPV4:PORT AWG_INTERFACE`. Verify the policy
route with `ip -4 route get SERVER_IPV4 oif AWG_INTERFACE`; capture both
directions on that AWG interface and correlate the matching conntrack
tuple. Require four nonce-verified responses on one socket. No listener,
forwarding change or kernel module is needed on Xiaomi. A timeout without
an independently working endpoint is inconclusive.

## VM acceptance

Use `tools/prepare-native-dns-vm.sh` and the NIC-free VM, then run
`/mnt/lab/setup-native-dns-guest.sh`. The standalone deployment test
checks first-install refusal on foreign state, guard activation, real
`fw4 reload`, procd respawn after SIGKILL, timed rollback, restoration of
the original nft/RPDB state, and explicit confirmation of the boot link.
The separate packet fixture exercises known Xray/FakeDNS, direct traffic,
DNAT fallback, and both pools on the virtual WAN.

The exact 37,888-byte trial archive passed the VM deployment and rollback
test. Xiaomi stayed at its original state: no guard files, no priority-10992
rules, no firewall reload and no new capture. Physical access was not
available for this run. Real AWG UDP remains pending a verified peer-side
echo endpoint.
