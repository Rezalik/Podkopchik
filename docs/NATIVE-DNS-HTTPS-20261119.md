# Native DNS Recovery: 2026-11-19

## Incident

The owner reported loss of internet on all devices behind the Xiaomi AX6000.
Read-only checks found WAN up, three AWG HTTPS health probes up, ordinary
router Direct HTTPS working, and LAN DNS returning SERVFAIL. Native was in
protected recovery after a recent router boot. Its current generation was an
older generation, not the latest confirmed synthetic-session correction.
The confirmed files and persistent DNS ledger passed validation.

At the initial controlled measurement, DoT queries to both Cloudflare and
Quad9 failed through the two automatic-group AWG paths, while bound HTTPS
worked. The third AWG answered DoT. A separately validated temporary manual
override selected that working AWG; a normal confirmed Apply restored LAN
UDP/TCP DNS, protected YouTube HTTPS and ordinary example.com HTTPS.

Later, the old DoT-only helper also answered through the original two paths.
This does not prove a permanent port block, an upstream outage, or its exact
relationship to the recovery rules. Do not claim the transient failure is
fully explained. Do not count the later positive DoT result as a physical
test of the new HTTPS fallback.

## Repair

The DNS helper now retries the standard Cloudflare/Quad9 DoT endpoints over
authenticated HTTPS if their DoT attempt fails. The retry:

- stays on the same protected AWG interface/index/mark or selected VLESS
  SOCKS transport, with no system resolver, proxy environment or WAN fallback;
- pins the same provider IP, port 443, the documented TLS hostname and
  `/dns-query`, using a DNS wire-format POST;
- verifies TLS certificates, DNS question/ID/rcode, HTTP status and media
  type, rejects redirects, and bounds headers, reply size and attempt time;
- closes each HTTPS connection and retains separate short failure backoff;
- is enabled only for the known default-provider IP/name pairs on port 853.
  Custom DoT providers, names and ports are not silently replaced.

The capability response adds `protected_dns_https=true` without changing
capability schema 3 or the private transport-state schema. No new router
runtime, package, DNS provider, UCI setting or subscription is required.
Provider references: [Cloudflare encrypted DNS](https://developers.cloudflare.com/1.1.1.1/encryption/dns-over-https/)
and [Quad9 service endpoints](https://docs.quad9.net/services/).

The coordinator also keeps the latest confirmed generation when protected
recovery is needed; it no longer prefers an obsolete `previous` generation.
A periodic health selection in recovery no longer erases the failure
diagnostic. These changes do not bypass confirmation or change Direct/
protected policy, transport roles, AWG profiles or DNS lease history.

## Verification

- Complete Go suite with race detector on Mac: PASS.
- Pinned Go 1.26.10, two identical ARM64 helper builds: PASS.
- Actual ARM64 OpenWrt protected-DNS suite: eight top-level tests PASS;
  two environment-gated network fixtures SKIPPED in that unit invocation.
- Separate no-NIC VM network fixture: PASS with DoT blocked, HTTPS succeeding
  through the real bound/marked virtual tunnel, zero DNS packets on virtual
  WAN, stale interface identity and all-down refused. Twenty queries kept
  process FD at 6 before and after.
- TLS, redirects, oversized/malformed/wrong-question replies, cancellation,
  private state, proxy-environment isolation and custom-provider scope: PASS.
- Confirmed-generation recovery and retained recovery error regression: PASS.

VM paths use virtual links, not AmneziaWG encryption. A full physical router
reboot, long-duration availability, video stability and transport failure
while all encrypted providers are unavailable are not established here.
If both encrypted protocols fail, DNS still fails closed.

## Xiaomi Deployment

Installed additively the twice-built helper with SHA256
`d8047651e0dedd719330ae1e8501c3d556a53541622959b66ab0454c8acb8c0a`,
updated its launcher and applied only the two coordinator corrections to
the router's existing code version. A full unrelated source bundle was not
installed. The prior code, saved UCI and runtime metadata are privately
backed up on the owner's Mac; no client query history was exported.

A first software trial still included the temporary override and was not
accepted as a return-to-primary test. It was explicitly aborted and the
last confirmed working generation returned. The final trial verified that
the override was absent, then passed LAN DNS UDP/TCP and complete HTTP 200/
verified-TLS loads of YouTube and example.com on the original primary AWG.
Generation `cbd2fc84d234f497ac5a35b1010a719a` is confirmed, active, with no
pending transaction or coordinator error. Active validation and synthetic
quarantine passed.

The final saved Podkopchik settings semantically match the incident's
original settings. Transport roles, AWG profile bytes, network/Wi-Fi/DHCP/
SSH/firewall files, global default routes, RPDB, AWG ifindices and boot
identity were preserved across installation. Only normal Native workers
were replaced by Apply. No emergency capsule was initialized and the
physical router was not rebooted.

At final measurement DNS had 11 FD, RSS 13,808 KiB and the router had
326,180 KiB available RAM. This is a post-install sample, not a long-duration
leak assessment. The new and old helpers both passed the subsequent physical
per-provider controls on the original two AWGs, after the initial DoT
timeouts had ceased. The blocked-DoT fallback itself is qualified by the VM
test, not falsely claimed as a physical forced-failure test.

The final workstation smoke pass was 56 PASS, 23 SKIPPED, 0 FAIL.
The changes remain on the feature branch; no GitHub push or public release
was performed as part of this repair.
