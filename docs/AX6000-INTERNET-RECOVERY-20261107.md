# AX6000 Internet Recovery, 2026-11-07

Device confirmed through `ssh openwrt`: Xiaomi Redmi Router AX6000 stock layout,
OpenWrt 25.12.6, kernel 6.12.112. `openwrt2` was not contacted.
The installed router remains on the legacy Xray/FakeDNS architecture; the
permanent Native candidate was not installed or activated.

## Findings And Recovery

- WAN DHCP/default route were present. Direct HTTPS worked, all three AWG
  checks reported UP, and HTTPS to a real YouTube address through the existing
  primary AWG returned 200.
- The main Xray had 893 FD against a 16384 limit, approximately 67 MiB RSS and
  no observed EMFILE/OOM error. FD exhaustion was not demonstrated in this
  incident. Its process age was much shorter than router uptime; the available
  log ring did not establish what caused that earlier replacement.
- LAN logs contained old synthetic destinations going to the default Direct
  outbound. A fresh FakeDNS mapping worked through the main TPROXY path, while
  a controlled older-address TLS probe selected Direct and timed out. A separate
  loopback-only SOCKS probe with the same installed binary recovered TLS SNI and
  returned 200. This points to volatile FakeDNS/runtime state, but does not prove
  the precise internal Xray failure mechanism or ownership of the old mapping.
- Validation and `xray run -test` passed. Generated and active config summaries
  retained the same inbound settings, outbound tags and 92 routing rules.
- One ordinary installed-version `podkopchikctl apply` completed successfully
  through its existing protected restart/rollback path. No application update,
  core replacement, AWG role change or new routing architecture was used.
- After Apply, both fresh-address and older-address HTTPS controls returned
  200 through the main Xray and the primary AWG. The UCI file compared byte-for-
  byte with the pre-change snapshot. One main Xray remained, with 539 FD at the
  immediate check and 806 at a later light-load check; these short samples do
  not establish long-term FD stability.

The private pre-change snapshot is on the router at
`/tmp/pkc-internet-recovery-20261107-110236`, directory mode 700, containing UCI,
active generated config, the owned nft table and SHA256SUMS. It is temporary
incident evidence, not an autonomous installation rollback kit.

All temporary diagnostic nft tables were removed. Packet capture used verified
OpenWrt tcpdump/libpcap files under private `/tmp`, without package installation.
The isolated probe Xray was stopped; no probe listeners or processes were left
active. Home LAN/Wi-Fi, AWG profiles, system default route and firmware were not
changed, and there was no reboot.

## Evidence Boundary

| Check | Result |
| --- | --- |
| Existing WAN, ordinary Direct HTTPS and real HTTPS through primary AWG | PASS |
| Installed config validation and protected Apply | PASS |
| Main TPROXY HTTPS, fresh and older fake-IP after Apply | PASS, controlled router-origin loopback probes |
| UCI retention, one main Xray, cleanup of diagnostic tables | PASS |
| Real household YouTube/Instagram/Telegram usability | PENDING user confirmation |
| Absence of legacy synthetic WAN leakage | NOT established; no production guard was installed in this incident |
| Long-term stability / definitive internal Xray root cause | NOT established |

The Mac's default route to synthetic destinations was through `utun8`; its
initial failed curl was not a household LAN acceptance test. Key authentication
to `media` was unavailable, so no real-client PASS is claimed from that host.
Legacy clients can still retain obsolete synthetic addresses without usable
domain information; Direct log entries alone do not prove physical WAN leakage.

## Continued Native Preflight

Read-only resource sample after recovery:

- `/overlay` free: 21472 KiB.
- `/tmp` free: 246504 KiB.
- `MemAvailable`: 311736 KiB.

The helper installer minimum of 19588 KiB is below the measured flash, but the
1884 KiB difference is not a completed backup/snapshot budget or permission to
delete files. Re-evaluate the complete physical installation/recovery budget.

An additional physical DNS gate was exposed: the stock resolver on
`127.0.0.1:53` returned NXDOMAIN for `www.youtube.com`, while DNS-over-HTTPS via
the existing AWG returned real A records and real HTTPS worked. The current
Native coordinator uses stock DNS as its upstream. Therefore a working protected
DNS upstream must be prepared and tested before household Native activation;
the successful VM fixtures used a controlled upstream and do not qualify this
ISP-specific condition. Do not silently switch the household to the candidate
with a censored upstream or claim that Strict forwarding fixes DNS poisoning.

Next physical switch remains gated on household recovery confirmation, protected
DNS upstream acceptance, full resource/backup preflight and autonomous rollback.
