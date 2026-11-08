# AX6000 scoped retry: native HTTPS passed, full acceptance stopped

Base: `9102664`, `feature/universal-routing-engine`. The retry was limited to
one temporary veth client and one existing AWG interface. No home LAN was
switched, no package was installed, and no shared service was restarted.

## Corrected archive

The actual pilot archive SHA256 was
`89ee757a9080e0f846d6604f4a95d6b7182c937079ac0d0b69a99f103da77cd1`.
The capture-tool archive SHA256 was
`9a3b40e64be5acb10315b2c3aefa2948aee953ecd45d934056372871f2154cbd`.
Both were checked again after transfer. Host USTAR checks allowed only the
expected flat, unique regular files, no path prefix, links or additional
headers, UID/GID 0, mode 0600 for data/scripts and 0700 for executables.
The physical arm helper checks private metadata and initializes the ledger
before making interfaces, nftables rules or policy routes.

In the NIC-free OpenWrt VM the same archive started the classifier and a
private local upstream. The classifier answered UDP DNS and a redirected
external TCP DNS query with the same synthetic A and published the expected
DNAT mapping. This was a live listener test, not only ledger initialization.

## Physical results

| Check | Result |
| --- | --- |
| Management, scope, watchdog | PASS. Mac and wired `media` reached Xiaomi. Fresh inventory admitted the isolated addresses, hooks and routing identifiers. The watchdog was armed with a 125-second deadline. |
| Protected DNS and route | PASS. UDP and TCP worked, including redirect of a TCP query addressed to the external DNS control. Acknowledged DNS bindings and the marked route selected the existing AWG. |
| Native HTTPS | PASS. Protected HTTPS returned 200. The AWG capture saw 15 outbound and 13 inbound TCP packets for the protected test endpoint. The scope did not pass through the household Xray inbound; no pilot Xray was started. |
| Separate UDP test | FAIL for round trip. One NTP request was visible on the AWG interface, with zero matching replies. The timeout does not locate the failure or establish that other UDP services are broken. The runner aborted immediately. |
| QUIC, virtual direct, withdrawn-route fail-closed, revoked/old synthetic and late replies | SKIPPED after the UDP timeout. The earlier physical direct control checked the capture path, not the virtual client's direct policy. |
| Physical WAN | FAIL for the combined synthetic-pool criterion. Zero packets used the new `172.31.253.0/24` pool. Two outgoing ICMP Echo Requests targeted the existing `198.18.0.0/15` FakeDNS pool, with the WAN IPv4 source. The retry had not reached its legacy-address probe. The source before NAT was not established. |

Within the observed physical capture window there were 16 outgoing packets
to the selected AWG outer endpoint, zero clear protected HTTPS/NTP packets,
zero packets with the AWG inner source on WAN and zero outgoing requests to
the bypass DNS control. Both captures had zero kernel drops. This is evidence
for the completed probes, not a full late-packet or loss-of-route acceptance.
Separate preflight captures saw 15 WAN and 30 AWG control packets.

## Rollback and steady state

A new SSH through `media` saw the already-restored journal and independently
verified the namespace, veth, pilot table, firewall4 handles, exact route and
policy rule slots, and all trial services were gone. All 17 home baseline
sections matched (UCI/Xray hashes, nftables, IPv4/IPv6 routes and policies,
packages, service PIDs, AWG links and boot ID). Temporary tools, files and
pcaps were removed after the aggregate evidence was recorded. Home DNS, WAN
HTTPS, all three existing AWG HTTPS probes, and SSH/LuCI via both management
paths passed. No repeat activation was performed.

Post-rollback: CPU 2.2% across all cores in a two-second sample, 298,004 KiB
MemAvailable, Xray RSS 57,356 KiB and 2,888 FD, and conntrack 5,230/31,232.
The runner never reached the active-pilot resource sample. Before any new
pilot, investigate the legacy-pool WAN traffic without altering the home
baseline, and use a verified UDP response endpoint and a deterministic late
reply test. Native HTTPS success is not clearance for household rollout.
