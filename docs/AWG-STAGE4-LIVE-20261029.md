# AWG Stage 4: AX6000 Deployment And Live Verification

Date: 2026-10-29, Europe/Moscow. Only `ssh openwrt`, Xiaomi Redmi Router AX6000
stock layout was used. GL-MT6000 was not accessed. No firmware/kernel/AWG/Xray
or system package was installed/updated. No reboot; WAN/LAN/Wi-Fi/SSH settings
and both system main routing tables are unchanged. GitHub was not updated.

## Installed Build

- Podkopchik0.1.0-beta, public overlay revision **r6**, not an APK installation.
- Archive: `podkopchik-awg-stage4-20261029-r6.tar.gz`.
- SHA256: `ab69f3e8a8830eb2a7a5170b6f2a9b4c1c942958ab5f84871f854c37d7f4574c`.
- OpenWrt25.12.6, kernel6.12.112, `xiaomi,redmi-router-ax6000-stock`,
  aarch64_cortex-a53, APK package manager.
- Xray26.3.27; AWG tools3.1.20260812-r1;
  kmod-amneziawg6.12.112.3.1.20260906-r1, module already loaded.
- Initial overlay free space44448KiB. The preflight ABI/version/space gates passed.

Git was dirty with the preceding Stage4 development changes before deployment;
these were retained, not reset or committed automatically. Subsequent fixes are
in the same working tree. No private configuration was added to Git.

## Results

PASS means the described scope was actually observed, not inferred from mocks.
Fault injection changed only temporary health probe destinations/settings; the
real AWG interface and physical WAN were never deliberately shut down.

| Test | Result | Evidence / Scope |
| --- | --- | --- |
| SSH/model/board/kernel/architecture | PASS | Rechecked directly on AX6000. |
| Versions, loaded AWG module, space, dependencies | PASS | Project preflight passed; no package mutation. |
| Overlay SHA256/paths/types | PASS | Checked on Mac and router; installer `--check`. |
| Native nft syntax | PASS | `nft -c -f` accepted all four UDP/IPv6 combinations; live table unchanged during dry runs. |
| Staged and final Xray syntax | PASS | Actual26.3.27 `run -test`: Configuration OK. |
| Independent watchdog | PASS | procd-owned process survives SSH exit; killed self-test worker respawned with its original deadline. |
| Actual automatic snapshot restore | PASS | Canonical snapshot restored UCI byte-for-byte, selection/config/code and removed only owned audit table. |
| r6 guarded installation | PASS | Dedicated procd deployment worker exited0; committed only after verification. |
| Main AWG HTTPS | PASS | Real pinned/device-bound health plus LAN HTTPS. |
| TCP/FakeDNS from LAN | PASS | Interface-bound Mac curl to fresh YouTube fake IP: HTTP200/TLS0; router log `transparent -> AWG`. |
| Backup VLESS HTTPS | PASS on repeat | Isolated probe and real LAN data HTTPS200; transient failures recorded below. |
| UDP through AWG | PASS | STUN3478 response, about122ms; LAN and AWG counters increment, plaintext WAN counters0. |
| UDP through VLESS | PASS on repeat | STUN3478 response, about426ms; actual `ibn` target, plaintext WAN counters0. |
| DNS UDP and TCP | PASS | LAN `dig @192.168.1.1 x.com` both transports return fake198.18/198.19. |
| Automatic AWG to VLESS | PASS | Failure counts1 and2 keep AWG, count3 selects `ibn`; no manual role/active-state edit. |
| Data after automatic failover | PASS | LAN HTTPS200 and UDP/STUN through the selected backup; plaintext WAN counters0. |
| Automatic return | PASS | First successful AWG check remains down/backup; second reaches UP, returns to main72s after switch. |
| Flap protection | PASS within test | No switch on first/second failed probe; restore threshold2 and minimum60s cooldown respected. Exact cooldown hold is also mock-tested. |
| All-down automatic rules | PASS | Both probes fail, actual selection and both test targets become `blocked`. |
| All-down data / WAN observation | PASS, scoped | HTTPS000/SSL error and UDP timeout while selection remains blocked; LAN TCP5 packets/597 bytes and UDP1 packet/48 bytes; WAN TCP/UDP counters0, AWG test counters0. |
| Management during all-down | PASS | SSH stayed usable, default route unchanged; independent restore returned normal operation. |
| Fail-closed on physical simultaneous tunnel removal | SKIPPED | No actual interface/WAN shutdown. Health failure injection and real blocked LAN packets were tested instead. |
| DNS WAN packet capture during all-down | SKIPPED | No tcpdump/pcap. DNS/FakeDNS functional tests and resolver routing are covered, but no exhaustive DNS leak capture is claimed. |
| QUIC/HTTP3 | SKIPPED | Neither available router nor Mac curl supports HTTP3; no new packages/browser changes. STUN is not a substitute for QUIC. |
| IPv6 capability gate | PASS | Enable request rejected; UCI/active config/nft hash unchanged. AWG lacks the required IPv6 profile capability; VLESS IPv6 probe also failed. |
| Real IPv6 HTTPS/UDP through VPN | SKIPPED | Current AWG profile has no supported IPv6 address/AllowedIPs combination. No configuration/server parameters were invented. |
| ICMPv6/NDP LAN | PASS, limited | Two gateway IPv6 ping replies, no loss; existing LAN IPv6 and network files unchanged. RA packets were not captured. |
| IPv6 interception syntax | PASS | Native nft dry-run only, not live IPv6 tunnel enforcement. |
| Xray core restart / health replacement | PASS | Repeated core-only restarts; health worker recreated, current health refreshes. |
| Full service stop/start | SKIPPED | Avoided the existing intentional cleanup/direct interval on the working home network. Core-only restart preserves interception. |
| Reboot | SKIPPED | Not necessary and not performed; isolated reboot acceptance remains pending. |
| Configuration/key preservation | PASS | Exact UCI comparison after restoration, unchanged AWG `.conf` files; VLESS outbound unchanged; network/wireless/firewall/dhcp/dropbear hashes unchanged. |
| Temporary state cleanup | PASS | Temporary routing sections, test nft table and procd guard/deploy services removed. No test interface was created. Private backups/logs intentionally retained. |

This is not a blanket proof of absence of all possible WAN leaks. Counter
observations cover specified LAN test destinations/protocols, with a positive
unproxied UDP control demonstrating that the WAN counter can increment.
Direct/unmatched rules, endpoint bypass and disabled protocols remain outside
proxy protection. QUIC and full IPv6 support are not declared complete.

## Failover Evidence

In Moscow time, primary-down selection switched to VLESS at22:34:13; after
restoring the original AWG probe parameters, selection returned to AWG at22:35:25.
The interval was72s. Existing roles stayed `kaz=main`, `novos=backup1` throughout.
Manual invocations of `podkopchikctl health` accelerated real probe cycles; the
normal procd health daemon also ran. No synthetic UP results or direct edits
to `state.groups.active_proxy` were used.

During the repeat all-down test, both test targets were confirmed blocked
before and after the client requests, with more than160s remaining on the
independent timer. An earlier measurement after timer expiry returned HTTP200
because the watchdog had already restored normal routing. That out-of-window
measurement was discarded, not called a leak or a successful fail-closed test.

## Errors Found And Fixed

1. **nft family syntax:** native dry-run rejected IPv4 `meta nfproto ipv4` with
   family-less port-only TPROXY. IPv4-only rules now use `tproxy ip to :12345`;
   dual-family mode keeps `tproxy to :12345`. All four batches then passed.
2. **procd asynchronous deletion:** health deletion may still report running
   until its process exits. The installer/recovery now waits before Apply,
   preventing core_restart from skipping recreation of the health worker.
3. **Broken pipe diagnostic:** installer status checking now consumes output
   into a private file before grep instead of closing the producer's pipe early.
4. **SSH-dependent rollback:** a shell trap was insufficient. Deployment uses
   separately supervised procd guard/worker, monotonic deadline, OS flock and
   explicit post-verification commit. Installation refuses a missing/mismatched
   guard or a deadline less than30s away.
5. **Unsafe test snapshot repack (operator/tooling regression):** one test
   snapshot was rebuilt from a mode700 private staging directory using `tar .`.
   Actual restoration changed root/system-parent modes to700 and temporarily
   made ubus unavailable. SSH and Xray remained available. Only explicitly
   verified affected parent directory modes were restored to their original
   public-system values; `/tmp`1777 and private app data permissions retained.
   Network configurations/routes and keys were unchanged. The unsafe repack is
   quarantined as `DO-NOT-RESTORE-UNSAFE-PARENT-METADATA.tar.gz` under its private
   phaseb directory. Good original snapshots were not removed.
   The backup helper now adds health state as an explicit canonical file path,
   never by repacking staging. Guard and installer rollback reject root/system
   parent entries and links. A regression test rejects the bad archive model.
   Subsequent **real canonical restores** verified exact UCI, intact ubus,
   Xray/health and system permissions. The final r6 includes these safeguards.
6. **Transient VLESS failures:** initial UDP/HTTPS and current+original isolated
   checkers timed out; the outbound matched its saved predecessor exactly.
   The endpoint TCP port remained reachable. Later fresh real checks and both
   LAN protocols passed; only then was failover attempted. The transient cause
   was not established and is not represented as a source-code fix.

Mac had an active `utun8` VPN. Unbound curl results were excluded from LAN proof.
All accepted LAN HTTP tests used `--interface en0`; the workstation-only STUN
client uses Darwin `IP_BOUND_IF`, with actual LAN packet counters confirming it.
No local VPN configuration or private keys on Mac were inspected or changed.

## Backups And Recovery

Protected initial application snapshot on AX6000:
`/root/podkopchik-stage4-live-20261029-01/snapshot.tar.gz`.
Its SHA256 is `e884f3ed5be19718fa77c88481d8d8e85ea2f67c5907af21432c4d36c35ab51e`.

Initial disaster archive (all UCI plus app snapshot and nft/policy diagnostics)
is also saved on the owner's Mac in
`.router-backups/awg-stage4/live-20261029/full-backup.tar.gz`.
SHA256: `6f391ab6b4cb30bd24508f86ec92738b31b98ce25bcd6ac535e26a36fc451930`.
The transfer required and received a separate explicit authorization for secrets.
Directory700/archive600, Git-ignored. Never publish/extract it into Git.

Pre-r6 canonical snapshot remains on the router:
`/root/podkopchik-stage4-final-20261029-01/snapshot.tar.gz`.
SHA256: `8dd7958f34710d9241dd2b13a71b68726a2af63ccdd84af604bd122d7fde46d5`.
Backups contain credentials. They restore the configuration at snapshot time,
not later edits. Do not manually unpack a private staging archive over `/`.

For an explicitly approved future recovery, create a **new** root700 guard
directory; copy the chosen canonical snapshot/hash, latest guard/lock helper
there as `snapshot.tar.gz`, `snapshot.sha256`, `watchdog.sh`, `guard-lock.uc`,
and write `kind=restore`. Run `watchdog.sh arm DIR 60`, then
`watchdog.sh request DIR`. procd performs the restore independently of SSH.
Verify SSH, active config, both routes, DNS, health and directory modes before
removing the completed guard service. Do not re-use a committed guard directory.
Normal `awg-rollback.sh` is for historical pre-Stage2/3 downgrade, not this task.
Cross-version full rollback to the original application was not deliberately
forced; controlled canonical snapshot restoration was actually exercised.

## Local Regression Checks

- Shell smoke runner: **24 PASS, 7 SKIPPED, 0 FAIL**. Two skipped AWG suites
  were subsequently run with native ucode: storage100 assertions and
  model/lifecycle/management802 assertions passed. Five other skipped suites
  need native OpenWrt UCI/jsonfilter; they are not counted as passed.
- All17 JavaScript smoke suites passed, including LuCI rendering, mixed
  generator/RPC behavior and i18n/real LMO catalog coverage.
- Expanded syntax checks passed for109 shell scripts/fixtures,43 JavaScript
  files and5 JSON files.
- `msgfmt -c`, documentation links/fences and `git diff --check` passed.
- Snapshot regression rejects root/parent metadata and links; packaging and
  installer recovery tests passed. Workstation STUN client compiled with
  `-Wall -Wextra -Werror`; it is not installed on the router.

See [Stage 4 changed files](AWG-STAGE4.md#changed-files) for the complete list.

## Final Configuration And Checks

Final r6 installation completed with rc0; independent install recovery was
committed after verification. The working app is retained, with:

- `kaz`: main, AWG interface running, fresh measured UP.
- `novos`/`ibn`: backup1, fresh measured UP.
- UDP interception0, IPv6 interception0.
- Existing FakeDNS enabled/hijack enabled, DNS1053 and TCP12345 active.
- Original main routes, endpoint bypass, private policy guards and SSH intact.
- One main Xray between health cycles; a live short health probe is not a leak.
- No active stage4 test services, nft audit table or temporary UCI test sections.

Read-only verification:

```sh
ssh openwrt
ubus call system board
podkopchikctl status
podkopchikctl validate-active
uci -q get podkopchik.main.udp_interception
uci -q get podkopchik.main.ipv6_interception
pgrep -a xray
ip -N -4 rule show
ip -N -6 rule show
ip -4 route show table main
ip -6 route show table main
nft list table inet podkopchik
nslookup -port=1053 x.com 127.0.0.1
ls -ld / /tmp /etc /usr /usr/share /tmp/podkopchik /etc/podkopchik/awg
```

`validate`/`generate` and Xray test also passed, but regenerate temporary output:

```sh
podkopchikctl validate
podkopchikctl generate
xray run -test -config /etc/podkopchik/config.generated.json
```

Remaining gates: real QUIC/HTTP3, an IPv6-capable AWG peer and IPv6 failure/leak
capture, exhaustive DNS/WAN pcap, controlled full stop/start/reboot and native
signed APK build. Existing sessions reconnect on failover; Xray FakeDNS memory
is not persistent across core restarts. The observed intermittent VLESS outage
is a remaining operational risk, despite successful repeat tests and final UP.

Sources for the diagnostic implementation:
[OpenWrt procd instance parsing](https://github.com/openwrt/procd/blob/master/service/instance.c),
[STUN RFC8489](https://www.rfc-editor.org/rfc/rfc8489.html).

GitHub main is unchanged. Using normal main-channel Update before these source
changes are published can replace this locally deployed build with older code.
