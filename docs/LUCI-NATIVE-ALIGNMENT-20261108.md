# LuCI / Native Alignment: Xiaomi Deployment

Installed with explicit operator approval on 2026-11-08, only on Xiaomi Redmi
AX6000 stock / OpenWrt 25.12.6 via `ssh openwrt`. No main update, package install,
Xray update, reboot or access to `openwrt2` was performed.

## Installed Scope

Nineteen static files: LuCI views/shared routing helper, both Russian LMO
locations, `podkopchikctl`, `generate.uc` and `native_runtime.uc`. There is no
UCI payload. The backend differences are selective defaults and read-only status
metadata; packet/health/recovery implementations were not changed.

Native status uses its frozen coordinator. A normal Native Apply was therefore
required to expose the new active/saved policy and DNS metadata. Generation
`d78ee589ed22533507f5c8d10b7d76e0` was confirmed at epoch `1794131442`; no pending
confirmation remained. Compatible/selective routing and migration restriction
off were retained, with 81 domain names, seven IP rules and zero LAN rules.

## Results

| Check | Result |
| --- | --- |
| 25 JS smoke tests, JS/shell syntax, gettext/real LMO, diff checks | PASS |
| Exact archive static install/restore, no-NIC OpenWrt VM | PASS; emergency verification is a fixture in this static-file test |
| Real independent emergency capsule verification and running watcher | PASS; no destructive recovery was triggered |
| Archive SHA256 and backup SHA256 on Xiaomi and Mac | PASS |
| Native candidate validation, active validation and confirmed Apply | PASS |
| Client DNS UDP/TCP and protected YouTube/Instagram/X HTTPS | PASS; all three HTTPS controls returned 200 |
| Client Direct TCP and HTTPS through each of three AWG | PASS |
| Two previously qualified Roblox UDP controls | PASS; four matched binding replies per control |
| UCI, AWG profiles/roles, default route, IPv4/IPv6 policy rules, boot | PASS; identical to baseline |
| dnsmasq, SSH, emergency and observer PIDs | PASS; unchanged |
| Interactive LuCI browser inspection | SKIPPED; Chrome stopped at the untrusted HTTPS certificate, not bypassed |
| New physical QUIC, fault injection and reboot acceptance | SKIPPED; not part of this UI update |
| Long-duration stability | IN PROGRESS; not established by restarting DNS |

Only Native DNS/health/watch changed through ordinary Apply. Only rpcd/uhttpd
were restarted afterward for the web catalog. Wi-Fi, network, firewall4,
dnsmasq and AWG were not restarted. Xray remains absent in AWG-only.

First post-Apply sample: DNS PID 5764, 11 FD, two owned UDP sockets, RSS
12,960 KiB; system CPU 7.7%, available RAM 299,324 KiB, conntrack 251/31,232.
The existing observer/emergency PIDs remain 5066/4047. Record the intentional
19891 -> 5764 DNS transition separately from the earlier 32577 -> 19891 policy
correction. Do not reset or extend the original 48-hour observation window.

## Artifacts And Space

Payload SHA256:
`fb16ebbbd06d16a5315a0f1e20ade434acf4d40d48f1d35654a11c7397761414`.
It is 101,701 bytes compressed and 354,748 file bytes unpacked. Before-files
backup: 92,573 bytes, SHA256
`8aa5a33799deb7329b0365735f2cde59f37f1354c0cd543cd8b133b319f3995e`.
Both archives are private files under `/root` and are retained for offline
static-file recovery. They contain application files and a UCI checksum, not
user configuration contents or keys. Private evidence and the verified backup
are in the Git-ignored `.router-backups/luci-alignment-20261108/` on the Mac.

Before Apply, the built-in budget required 13,391 KiB flash with 17,524 KiB
available, including its DNS journal and safety reserves. More than 16 MiB
remained after installation and retaining both small recovery archives. No
user files were deleted to make room.

## Static-File Recovery

Historical procedure: later on 2026-11-08 the operator explicitly requested
removal of the emergency mechanism and router backups. The two `/root` archives
below were deleted during that [cleanup](AX6000-CLEANUP-20261108.md); they are
not available on the current router. Verified copies remain on the Mac. Do not
run this historical procedure expecting those files to exist on Xiaomi.

Run only to undo the UI/source update, not as routine maintenance:

```sh
umask 077
work=$(mktemp -d /tmp/pkc-luci-update.XXXXXX)
printf '%s  %s\n' fb16ebbbd06d16a5315a0f1e20ade434acf4d40d48f1d35654a11c7397761414 /root/pkc-luci-alignment-payload-20261108.tar.gz | sha256sum -c
printf '%s  %s\n' 8aa5a33799deb7329b0365735f2cde59f37f1354c0cd543cd8b133b319f3995e /root/pkc-luci-alignment-before-20261108.tar.gz | sha256sum -c
tar -xzf /root/pkc-luci-alignment-payload-20261108.tar.gz -C "$work"
tar -xzf /root/pkc-luci-alignment-before-20261108.tar.gz -C "$work"
sh "$work/install.sh" restore "$work"
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
```

This does not change the active immutable Native generation or restore an old
DNS allocator. For actual critical routing/management failure, use the verified
independent emergency procedure documented in
[the household deployment report](UNIVERSAL-NATIVE-HOUSEHOLD-20261107.md).
Never rewind issued synthetic allocation history from an old backup.
