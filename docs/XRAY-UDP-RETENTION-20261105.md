# AX6000 UDP Reply-Socket Retention: Diagnosis And Candidate

**Historical candidate, withdrawn before deployment.** The follow-up task
requires preserving full-cone, so the cone-disabling init change below is no
longer present. See [the bounded reply-cache fix and live isolated evidence](XRAY-UDP-CACHE-FIX-20261105.md).

Date: 2026-11-05, Europe/Moscow. Only Xiaomi Redmi AX6000 via `ssh openwrt`.
Router work was read-only: no Apply, restart, configuration/interface change,
package installation, core upgrade, sysctl change or access to `openwrt2`.
The repository candidate is **not deployed**. The earlier nofile increase is
capacity headroom, not the solution to UDP retention.

## Confirmed Observations

Main Xray26.3.27/OpenWrt, PID24190, nofile16384/16384. Installed generator,
AWG network helper, nft application and init hashes matched the local files
before this candidate. The active configuration has no VLESS outbound:

- `transparent`: dokodemo-door, TCP+UDP, followRedirect, TPROXY, sniffing/FakeDNS.
- `dns-in`: dokodemo-door TCP+UDP, 0.0.0.0:1053; `dns-out`: DNS protocol.
- Three AWG outbounds: marked/interface-bound freedom; direct freedom fallback.
- FakeDNS plus a real TCP resolver, not thousands of UDP resolver sockets.
- Policy contains outbound statistics only; no explicit session timeout.
- UDP interception ON, IPv6 interception OFF. DNS53 returns to the NAT DNS chain
  before the existing TCP/UDP TPROXY rules. No rule or setting was changed.
- Neither spelling of the cone environment variable was set in the main process.

Between 01:01:15 and 06:32:29 MSK, with the same PID/start time, FD1823->10556,
UDP1116->9796, TCP617->616, RSS63016->82172KiB and conntrack5607->6212.
During this diagnosis the process fluctuated around10.5-10.7k FD, below14000;
it must not be assumed to grow linearly or to remain safely below the limit.

One inode-matched sample had9905 UDP sockets:9874 foreign-public IPv4 bindings,
11 FakeDNS bindings, one foreign-private binding and19 wildcard bindings.
All kernel UDP remote tuples were zero and queues empty at that instant.
These are unconnected UDP sockets using sendto/WriteTo, not proof of no traffic.
There were9901 distinct local bindings, with at most3 copies of any binding.
Local port6881 accounted for1123 sockets,51413 for432,49001 for141 and443 for14.
This is consistent with high destination churn; it does not identify a client
application or prove that any particular P2P application is responsible.

A separate conntrack correlation found9706 Xray IPv4 local bindings absent
from all current UDP endpoint tuples, versus170 with a match. This is an
aggregate comparison, not packet capture or proof that every unmatched socket
is idle. Original client addresses, keys and domain lists were not emitted.

A fixed-PID cohort was read again without changing traffic:

| Elapsed seconds | All FD | UDP | Original inode+binding pairs retained |
| --- | --- | --- | --- |
| 0 | 10641 | 9894 | 9892 distinct inodes |
| 130 | 10596 | 9899 | 9870 |
| 259 | 10737 | 9936 | 9868 |
| 388 | 10692 | 9924 | 9868 |

Repeated procfs reads are non-atomic. Counts may differ slightly and an inode
cohort gives a minimum observed lifetime, not a creation timestamp or last
packet time. Retained logs had no matching EMFILE/UDP/close-error messages;
log rotation means this is not an assertion about the entire process lifetime.
The final06:54:01MSK read found10762FD on the same PID24190, no cone environment
setting, and the original installed init/generator/nft hashes. The14000 warning
threshold was not reached. None of the candidate was installed.

### Evening Read-Only Recheck

After the operator resumed work, a new read-only sample at20:44:13MSK found
main PID3371, nofile16384/16384,11847FD (72.3% of the limit),11116UDP and606TCP.
RSS was71536KiB and conntrack4625/31232. TCP states were87ESTABLISHED,
253CLOSE_WAIT,263SYN_SENT and3LISTEN; other matched TCP states were zero.
The non-atomic FD classification left39other and2unread descriptors.

Router boot time was11:47:10MSK, with main process age about8h57m at the sample.
This is a new process/boot, not a continuous extension of the morning PID24190
series; do not infer a same-process FD delta across that boundary. No reboot
or restart was performed by this read-only check, and its cause was not audited.

The core remained26.3.27; active configuration still had AWG freedom outbounds,
no VLESS, UDP interception ON, IPv6 OFF, and FakeDNS/hijack ON. Both cone
environment variables remained absent. Installed init/generator/nft hashes
were unchanged, so the candidate had not been deployed. The14000 threshold
was not reached. Main environment, core-only restart/recovery regressions,
real-core synthetic config syntax and `git diff --check` passed again locally.

## Mechanism And Confidence

The version-pinned upstream sources explain the observed socket shape:

1. [core/xray.go](https://github.com/XTLS/Xray-core/blob/v26.3.27/core/xray.go)
   enables cone mode unless `xray.cone.disabled` is exactly `true`.
2. [UDP worker](https://github.com/XTLS/Xray-core/blob/v26.3.27/app/proxyman/inbound/worker.go)
   keys cone associations by source only; non-cone includes original destination.
   The worker checks once per minute and closes associations inactive for more
   than120s. New traffic refreshes activity for the whole association.
3. [dokodemo PacketWriter](https://github.com/XTLS/Xray-core/blob/v26.3.27/proxy/dokodemo/dokodemo.go)
   keeps one FakeUDP reply socket per distinct response destination in its map.
   Entries close on a send error or when the entire writer closes, not through
   independent per-entry expiry. A busy source can therefore retain old peers.
4. [FakeUDP](https://github.com/XTLS/Xray-core/blob/v26.3.27/proxy/dokodemo/fakeudp_linux.go)
   binds an unconnected IP_TRANSPARENT socket to the remote endpoint address/port,
   matching the many foreign local bindings and zero remote tuples observed.

This is the strongest explanation, supported by the socket bindings, retention
cohort, source code and active cone defaults. It is **not yet an isolated A/B
kernel reproduction**, so do not call it a fully proven upstream leak or
declare that every retained FD belongs to this mechanism.

It is not a socket created for every DNS request: the dominant bindings are
neither DNS1053 nor remote53. AWG outer encryption is in the kernel; the
Xray-owned sockets are transparent reply state before/around that path.
Generic UDP interception also puts otherwise-direct traffic through Xray.
Thus unrelated UDP churn can exhaust the shared DNS/TCP process.

Xray's [default policy](https://github.com/XTLS/Xray-core/blob/v26.3.27/features/policy/policy.go)
has connIdle300s; [freedom](https://github.com/XTLS/Xray-core/blob/v26.3.27/proxy/freedom/freedom.go)
refreshes its activity timer on traffic. Decreasing global connIdle would also
affect TCP and cannot expire old destinations inside an active cone writer.
There is no per-PacketWriter-entry idle-timeout setting in this version's
JSON schema. No invented `udpIdleTimeout` or global timeout change is added.

## Minimal Candidate

Only `xray_instance()` in the init script changes runtime behavior:

```sh
procd_set_param env "xray.cone.disabled=true" "XRAY_CONE_DISABLED=true"
```

Both spellings are explicit because Xray's
[environment lookup](https://github.com/XTLS/Xray-core/blob/v26.3.27/common/platform/platform.go)
prefers the canonical dotted spelling to the uppercase alias. procd passes
these as child environment entries, not shell exports. Health probes and
parent environment are unchanged; the existing FD limit is not increased.

On Xray26.3.27 this separates transparent UDP associations by source AND original
destination, so traffic to a new destination no longer keeps an unrelated
destination's association alive. It is a targeted mitigation of cone retention,
not a hard per-process socket budget or a generic Xray memory-leak fix.
No generator/JSON, nft/TPROXY/DNS, FakeDNS, AWG role, default route, failover,
UCI or installer behavior changes. Supported TCP and UDP interception stay on
exactly as configured; UDP443 is not blocked.

Trade-offs: applications relying on endpoint-independent/full-cone UDP behavior
may behave differently. Active high-cardinality traffic can still use many
FDs; unsolicited reply peers can still exercise writer caching. A complete
per-peer expiry/budget would require an upstream core change, not a fake UCI
option. Future Xray upgrades must recheck this flag and retention behavior.

## Local Checks And Live Gates

Regression tests cover both variable spellings on main creation/core restart/
startup recovery, no environment/limit leakage into health-only startup, and
unchanged command/config path and nofile16384. Existing native ucode generator,
mixed failover, FakeDNS/nft and safe-Apply mocks exercise unchanged behavior.

The official macOS ARM64 Xray26.3.27 release archive used for a local syntax
check matched GitHub's published SHA256:
`2e93a67e8aa1936ecefb307e120830fcbd4c643ab9b1c46a2d0838d5f8409eaf`.
Only its core executable was extracted locally; no geodata was installed.
`run -test` with both environment entries accepted synthetic mixed AWG/VLESS,
FakeDNS and TPROXY JSON. This is config syntax, not Linux TPROXY traffic or
proof that post-deployment UDP retention is fixed.

Final local results:32 shell smoke suites PASS,17 JavaScript smoke suites PASS,
zero failures. Four legacy shell generator checks were SKIP because this host
lacks native OpenWrt UCI/jsonfilter; the mixed generator ran with native ucode
and its test-only UCI adapter instead. Shell syntax60 files, JS parse31 files,
JSON3 files, msgfmt, i18n/LMO smokes, documentation links/fences and
`git diff --check` PASS. A mutation check removed only the new main environment
line from a temporary init copy and confirmed the new regression smoke fails.

```sh
sh tests/xray_udp_session_smoke.sh
XRAY_TEST_BIN=/absolute/path/to/xray sh tests/xray_udp_session_smoke.sh
sh tests/xray_instance_restart_smoke.sh
sh tests/startup_safety_smoke.sh
sh tests/safe_apply_smoke.sh
```

## Future Deployment And Rollback

No installation or restart is authorized by this preparation task.

1. Obtain separate permission for one guarded Apply/new main process. Capture
   current PID/start/FD/RSS and fresh checksums of UCI, active JSON, AWG profiles,
   owned nft state and default routes. Keep secrets only in private backups.
2. Back up the exact installed `/etc/init.d/podkopchik`, including its current
   16384 limit; do not use an older historical backup with removed VLESS roles.
   Preserve a fresh canonical working checkpoint and independent rollback as
   described in [r7 recovery](AWG-STAGE4-R7-LIVE-20261104.md#future-recovery).
3. Overlay only the reviewed init script, verify its hash/`sh -n`, then perform
   one protected Apply through the existing guard/watchdog mechanism. Do not
   change UDP settings, rules, DNS, AWG roles or routing-enabled intention.
4. Verify a new main PID and both environment entries from its `/proc/PID/environ`
   using an exact whitelist, nofile16384, unchanged JSON/nft/roles/default route,
   DNS/FakeDNS and real LAN TCP/UDP traffic. Keep health probes out of counts.
5. Repeat the same FD/inode/RSS measurement under the old workload for at least
   the previous5.5h window and through an idle period. No linear accumulation,
   real retirement of inactive destinations, no EMFILE and intact application/
   failover behavior are required. Config validation alone is not acceptance.
6. If behavior regresses, restore the saved init atomically and syntax-check it,
   then perform the guarded restart/Apply using the saved working checkpoint.
   A JSON-only restore does not remove procd environment changes. Recheck the
   previous routes/roles/FakeDNS and process limits. Old retention may return.

If FD approaches14000, report urgent capacity risk immediately. Do not silently
raise the limit, periodically restart the core, disable UDP or change routing
as an emergency workaround without explicit authorization.
