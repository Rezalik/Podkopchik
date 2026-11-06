# AX6000 local pilot qualification, 2026-11-06

Base: `51608e2`, `feature/universal-routing-engine`. No connection or write to
either physical router in this phase. The public review archive contains no
router snapshot, keys or configuration. The procedure is in the
[wired pilot and recovery review](UNIVERSAL-AX6000-PILOT.md).

## A1 snapshot and resource budget

The saved A1 inventories and the Mac's full private backup passed their SHA256
manifests. The inventory covered 46 routes, 18 policy rules, LAN/WAN/AWG,
endpoint/exclusion networks and all three AWG `AllowedIPs`. The latter are
full-tunnel selectors, not additional specific networks. Both `172.31.253.0/24`
and the encompassing `/24` of the proposed `172.31.252.0/30` transit passed
offline admission. The proposed pool does not overlap `198.18.0.0/15`.
Refresh the inventory, including routes only known to VPN peers, before use.

| Item | Bytes or measured value |
| --- | ---: |
| ARM64 archive | 2,328,107 bytes |
| Unpacked payload (20 files) | 5,900,478 bytes |
| Payload, each file rounded up to 4 KiB | 5,947,392 bytes |
| Archive and unpacked files concurrently in `/tmp`, 4 KiB model | 8,278,016 bytes |
| Candidate policy/state allowance | 2,097,152 bytes |
| Recovery allowance, included in flash total | 1,048,576 bytes |
| Of recovery: five helper files / private draft manifest and digests | 16,421 / 809 bytes |
| Of recovery: bounded two-generation log reservation | 33,024 bytes |
| Separate free-flash safety margin | 4,194,304 bytes |
| Total flash requirement including allowances and margin | 13,287,424 bytes |
| A1 free `/overlay` / free `/tmp` | 22,003,712 / 253,235,200 bytes |
| A1 flash headroom above model | 8,716,288 bytes |
| A1 MemAvailable / MemTotal | 336,035,840 / 507,629,568 bytes |
| Mac-only full backup, not counted in router budget | 11,098,785 bytes |

The preflight has separate 13 MiB flash and 12 MiB `/tmp` floors. Recovery
helpers are already counted in the payload row; the recovery allowance covers
private manifests, journal plus atomic-write scratch, logs and reserve, not a
second copy of Xray. The DNS watermark is capped at 512 bytes and leases are
runtime data. UBIFS copy-up/metadata and actual RAM cannot be measured from a
saved snapshot. Treat this as a budget, not a fresh free-space guarantee.

Under the 180-second ARM64 VM run, the classifier handled 2,127 successful
concurrent UDP/TCP DNS queries during six route switches. It used 4,204 to
9,140 KiB RSS and 11 to 16 sampled FD; the classifier returned to 11 FD at the
end. The namespace had 60 to 1,526 sampled conntrack entries. Resting recovery
workers used roughly 1.2 MiB RSS. These exclude the live device's Xray,
AWG, kernel network memory and any added test DHCP process. Recheck all
resource measurements on hardware; three minutes are not a longevity claim.

## Acceptance evidence

| Check | Result |
| --- | --- |
| Explicit RFC1918 approval, collisions, exhausted /24 | PASS. All 254 offsets allocated; a new protected lookup returned SERVFAIL without a real address. Live binding refresh succeeded. |
| DNS, DNAT, fwmark and transport | PASS in OpenWrt ARM64 VM. UDP/TCP DNS, IPv4/IPv6, TCP, UDP, actual QUIC; protected IP rules and ordinary direct controls. |
| Reapply, failover, stale leases | PASS in VM. Same-transport tuple survived reapply; an existing conntrack flow did not cross to another transport. Expired or old leases did not reopen and addresses were not reused after reboot. |
| Independent transports | PASS in VM with stock Xray/VLESS and synthetic native tunnel links. Xray stopped without breaking native forwarding; VLESS TCP fallback rejected unsupported UDP. |
| Owner loss, classifier fault, recovery restart | PASS in VM. A killed owner expired; a missing classifier triggered abort; rejected scoped nft restore retained quarantine and procd restarted the killed watchdog. The legacy DNS/Xray PIDs and UCI hashes, routes and rules matched. |
| Watchdog boot and WAN capture | PASS in VM. Actual reboot invalidated the prior boot journal. Exact AX6000 recovery guard blocked both old and new pools, including an already DNATed destination. No synthetic packet at virtual WAN; direct LAN and router TCP/UDP controls arrived. |
| Native routing capture before and after rollback | PASS in VM. First pass saw 0 protected and 0 plaintext-DNS packets vs 64 direct controls; native rollback saw 0 synthetic vs 8 direct controls. |
| Host checks | PASS: 51 smoke scripts, Go race suite ten repetitions and `go vet`, shell/JS syntax, i18n and `git diff --check`. Five host checks that need OpenWrt or a Linux Xray executable passed in the VM. |
| Reproducible ARM64 review | PASS. Two builds matched byte-for-byte; outer archive and inner manifests verified. |
| Physical switch, real WAN, real profile tests | SKIPPED. DSA isolation, netifd races, true early boot ordering, hardware offload and real AWG/VLESS, physical WAN capture and endurance must be qualified separately. |

SHA256 for the review archive:

```text
20b7db41c31f076c3edc7133b5459bf039f7edd3b9ab7527cbad8b6718418219
```

The autonomous kit is a rollback of a scoped **runtime-only** pilot. It does
not rewrite household UCI or reinstall shared daemons. Missing ownership or
independent household drift is a stop condition, not permission to restore
over external changes. The pilot is not self-installing: first confirm the
fresh read-only preflight and isolated rollback, then test one wired client
with an independent home management path. Do not enable the main LAN.
