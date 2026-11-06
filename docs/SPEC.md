# Podkopchik 0.1.0-beta Specification

## Overview

Podkopchik is an OpenWrt 24.10+ LuCI application for routing selected LAN traffic through Xray VLESS proxy links.

The application provides:
- LuCI web UI
- UCI configuration
- Xray config generation
- nftables/TPROXY transparent routing
- DNS handling through dnsmasq
- simple proxy roles with internal proxy-group failover
- GitHub-based installation and updates

Package name: `luci-app-podkopchik`  
Service name: `podkopchik`  
UCI config: `/etc/config/podkopchik`  
Generated Xray config: `/etc/podkopchik/config.json`  
Runtime state: `/tmp/podkopchik/state.json`

Release version: `0.1.0-beta`

Native APK metadata uses `0.1.0_beta-r1` (APK prerelease syntax); IPK metadata
keeps `0.1.0-beta-r1`. Displayed application/UCI version remains unchanged.

Target platform:
- OpenWrt 24.10+
- LuCI from the corresponding OpenWrt 24.10 or 25.12 release
- firewall4 / nftables
- ip-full for fwmark policy routing
- opkg on OpenWrt 24.10; apk on OpenWrt 25.12
- no Python, Node.js, npm, Docker, or heavy runtime dependencies on the router

Primary target device:
- Xiaomi Redmi Router AX6000
- current OpenWrt 24.10.1; migration target OpenWrt 25.12.6, stock layout

Service behavior:
- The `podkopchik` service is enabled and started after installation.
- Traffic interception is controlled separately by `podkopchik.main.routing_enabled`.
- A fresh install leaves interception inactive until the user configures at least one valid proxy and routing rule, then clicks Apply or runs `podkopchikctl apply`.

## Goals

Podkopchik `0.1.0-beta` must allow a user to:

1. Add multiple named VLESS links.
2. Use VLESS TCP/REALITY and VLESS XHTTP/REALITY.
3. Choose one main proxy and 1-3 backup proxies in the simple Proxy Links UI.
4. Let Podkopchik maintain the internal automatic proxy group.
5. Automatically fail over to backups when the primary is unavailable.
6. Automatically return to the primary when it becomes available again.
7. Keep advanced proxy-group backend compatibility.
8. Route traffic by domain groups.
9. Route traffic by destination IP/CIDR.
10. Route traffic by LAN source IP.
11. Keep DNS based on OpenWrt dnsmasq.
12. Optionally redirect LAN DNS UDP/TCP 53 requests to the router.
13. Generate and validate Xray config.
14. Manage only Podkopchik-owned nftables rules.
15. Install from GitHub.
16. Update Podkopchik from LuCI.
17. Preserve user configuration during updates.
18. Bypass configured proxy endpoint destinations before transparent proxy interception.
19. Let users add manual direct exclusions for host/IP/CIDR destinations without port matching.
20. Add rule presets for popular services as a quick way to create ordinary editable routing rules.

## Non-goals for 0.1.0-beta

Do not implement these in `0.1.0-beta`:

- subscription URLs
- geosite database
- geoip database
- traffic statistics
- QR-code import/export
- AdGuard Home integration
- smartdns integration
- mosdns integration
- dnscrypt-proxy integration
- automatic Xray core updates
- OpenWrt firmware updates
- FakeDNS enabled by default
- support for every proxy protocol
- Docker-based installation
- Python/Node.js runtime on the router

## Architecture

Podkopchik uses this flow:

```text
LuCI JavaScript UI
        ↓
UCI config /etc/config/podkopchik
        ↓
podkopchikctl / ucode / shell scripts
        ↓
Generated Xray config /etc/podkopchik/config.json
        ↓
Xray
        ↓
nftables / TPROXY
        ↓
LAN traffic routing
```

Components

Required components:

* LuCI JavaScript views
* UCI config file
* rpcd ACL file
* menu.d registration file
* /etc/init.d/podkopchik
* podkopchikctl
* VLESS parser
* Xray config generator
* nftables apply script
* nftables cleanup script
* health check script
* update check/install commands
* uninstall script
* README
* documentation

LuCI pages

Podkopchik must provide these LuCI pages:

1. Status
2. Proxy Links
3. Presets
4. Domain Groups
5. IP Rules
6. LAN Devices
7. DNS
8. Updates
9. Logs
10. Advanced

Pages that change active routing inputs must not stop at a UCI save. Save & Apply on Proxy Links, Domain Groups, IP Rules, Exclusions, LAN Devices, DNS, and active Advanced settings, plus Add preset on Presets, must invoke the Podkopchik runtime apply path, or cleanup when the service is disabled, so the active Xray config and Podkopchik-owned nftables state match the saved settings.

Generate/apply must tolerate preserved legacy UCI config after reinstall or update. Enabled `domain_rule`, `ip_rule`, and `lan_device` full-proxy targets are checked before Xray config generation. Valid targets are left untouched. If a stale non-empty target no longer matches an enabled proxy/group and the internal `auto_proxy_group` is valid, Podkopchik repairs only that target to `auto_proxy_group` and logs the migration. If no safe automatic target is available, apply fails with a clear error naming the broken target and UCI section.

Proxy links

A proxy link represents one named VLESS URI.

Fields:

* enabled
* name
* uri
* tag
* role: main proxy, backup proxy, or disabled
* backup priority when role is backup proxy
* detected transport
* detected security
* optional note

Required support:

* VLESS TCP/REALITY
* VLESS XHTTP/REALITY

The parser must extract at least:

* UUID
* host
* port
* type/network
* security
* sni/serverName
* publicKey
* shortId
* fingerprint
* flow if present
* path if present
* host/header if present

The parser must reject obviously invalid links.

Proxy groups

A proxy group is a logical routing target.

Routing rules should usually point to groups instead of raw proxies.

Required group modes:

strict_primary

Fields:

* primary proxy
* 1-3 backup proxies
* auto_return enabled/disabled
* manual override proxy optional

Behavior:

* Use primary while healthy.
* If primary is unhealthy, switch to the first healthy backup.
* If backup1 is unhealthy, try backup2, then backup3.
* If primary becomes healthy again and auto_return is enabled, switch back to primary.
* Do not switch after one failed check.
* Use fail_threshold and restore_threshold.

fixed_proxy

Fields:

* fixed proxy
* optional backup proxies
* failure action: warn_only or switch_to_backup

Behavior:

* Always use the selected proxy while it is configured.
* Health check monitors the proxy.
* By default, do not auto-switch.
* If failure action is switch_to_backup, use the first healthy backup.

manual override

For strict_primary groups:

* if manual_override_proxy is set, use it instead of automatic selection.
* show a warning in LuCI.
* allow disabling override.

Routing rules

Required routing types:

Presets

Presets are a LuCI convenience layer, not a separate routing system.

Required behavior:

* Presets create ordinary `domain_rule` and `ip_rule` UCI sections.
* Created preset rules must be editable and removable through the normal Domain Groups and IP Rules pages.
* Duplicate protection is based on rule type, value, and target.
* If part of a preset already exists for the selected target, only missing values are added.
* After adding a preset, LuCI must save UCI changes, apply LuCI changes, and run the Podkopchik runtime apply path.
* If runtime apply fails, UCI changes remain saved and the user sees a clear runtime apply error.

Required presets:

* Telegram: 8 domain entries and 7 IP CIDR entries.
* YouTube: 15 domain entries, no IP entries in this beta step.
* Instagram: 14 domain entries, no IP entries in this beta step.
* TikTok: 14 domain entries, no IP entries in this beta step.
* X / Twitter: 19 domain entries, no IP entries in this beta step.
* Discord: 11 domain entries, no IP entries in this beta step.
* OpenAI / ChatGPT / Codex: 14 domain entries, no IP entries in this beta step.
* Canva: 10 domain entries, no IP entries in this beta step.

The OpenAI / ChatGPT / Codex, Canva, Discord, and CDN-related domain lists can change over time. Presets are a user-editable starting point and are not a permanent guarantee that every future service hostname is covered.

Domain rules

Fields:

* enabled
* domain list
* target group/proxy
* group_name
* group_tag
* group_order

Storage:

* one visual domain group is stored as one `domain_rule` UCI section
* domains are stored as repeated `list domain` values inside that section
* legacy configs with one `domain_rule` section per domain and matching `group_tag` or `group_name` must still be read
* saving a legacy group may migrate it to the one-section list format without losing domains

Examples:

* chatgpt.com -> group_chatgpt
* openai.com -> group_chatgpt
* youtube.com -> group_youtube

Destination IP/CIDR rules

Fields:

* enabled
* cidr
* target group/proxy

LuCI Save & Apply for IP rules must save UCI changes, apply LuCI changes, and then run the same Podkopchik runtime apply path as `podkopchikctl apply`, so the active Xray routing config is regenerated and restarted without requiring manual SSH commands.

Examples:

* 8.8.8.8/32 -> group_dns
* 142.250.0.0/15 -> group_youtube

LAN device rules

Fields:

* enabled
* name
* source_ip
* mode
* target group/proxy/direct
* speed_limit_enabled
* download_mbit
* upload_mbit
* speed_limit_mode
* speed_limit_hours
* speed_limit_until
* schedule_days
* schedule_start
* schedule_end
* unlimited_window_start
* unlimited_window_end

Required modes:

* full_proxy
* rules_only
* direct

Speed limit phase:

* `0.1.0-beta` stores LAN device speed limit configuration and exposes diagnostics only.
* Do not create `tc`, `ifb`, qdisc, nft mark, or interface shaping rules in this phase.
* Ordinary WAN-side QoS by original LAN source IP is not a valid design for proxied traffic because Xray creates router-to-proxy-server connections after TPROXY.
* Future enforcement must classify traffic on the LAN side before or around TPROXY, where the original LAN source IP is still visible.

DNS

Podkopchik `0.1.0-beta` uses OpenWrt dnsmasq.

Requirements:

* Do not replace dnsmasq.
* Do not install AdGuard Home, smartdns, mosdns, or dnscrypt-proxy.
* Add optional LAN DNS redirect:
    * UDP 53 from LAN clients to router DNS
    * TCP 53 from LAN clients to router DNS
* Do not hijack DNS generated by the router itself.
* Do not proxy DNS resolution of proxy server hostnames before proxy connection exists.
* Enable Xray sniffing for transparent inbound.
* Do not enable FakeDNS by default.
* Experimental Xray FakeDNS config is generated only when `podkopchik.main.fakedns_enabled=1`.
* Experimental LAN DNS hijack to Xray FakeDNS is active only when both `fakedns_enabled=1` and `fakedns_hijack_dns=1`.
* FakeDNS hijack must use a dedicated nft `dns_prerouting` nat chain.
* FakeDNS hijack must not add DNS redirect rules to the existing TPROXY/mangle chain.
* Do not add UDP/443 blocking or UDP TPROXY in this step.
* LuCI must warn that DoH, DoT, and Apple Private Relay can bypass normal DNS redirect.
* LuCI DNS page must expose optional FakeDNS settings without enabling FakeDNS by default:
    * `fakedns_enabled`
    * `fakedns_hijack_dns`
    * `fakedns_port`
    * `fakedns_pool_v4`
    * `fakedns_pool_size`
    * `fakedns_listen`
* LuCI DNS Save & Apply must save UCI changes, apply LuCI changes, and run the Podkopchik runtime apply path so FakeDNS/Xray/nft state matches the saved settings.
* The DNS page must explain that FakeDNS can help apps such as X/Twitter that do not route reliably with domain-only rules, and that Private DNS, DoH, iCloud Private Relay, or another VPN can bypass router DNS.

Health check and failover

Health checks must verify that a proxy outbound can reach a test URL when the router has a reliable local probe path.

This is not ICMP ping.

The `0.1.0-beta` implementation uses a temporary localhost SOCKS inbound backed by Xray plus `curl` for real outbound checks. If that probe path is unavailable, status must be recorded as `unknown` with a reason and must not be treated as healthy.

Temporary health-check Xray processes must be cleaned up on normal exit, probe failure, timeout, and interruption. Before starting a new probe, Podkopchik must remove only stale health-check Xray processes whose command line references `/tmp/podkopchik/health-*.json`; it must not kill the main Xray process using `/etc/podkopchik/config.json`.

When health state contains a failover switch event while routing is active, Podkopchik must regenerate and validate the active Xray config before replacing it. If that failover apply path is busy or fails, the previous health state must remain in place so the next health check can retry instead of recording a proxy selection that is not present in `/etc/podkopchik/config.json`.

Default values:

* probe URL: https://www.gstatic.com/generate_204
* method: HEAD
* interval: 30
* timeout: 5
* fail_threshold: 3
* restore_threshold: 2

State file:

* /tmp/podkopchik/state.json

The state file should include:

* proxy status
* fail counts
* success counts
* last error
* group active proxy
* last switch time
* reason for switch

Failover events must be logged.

Xray config generation

Podkopchik must generate:

/etc/podkopchik/config.json

The generated config must include:

* transparent inbound
* sniffing enabled
* direct outbound
* one outbound per enabled proxy
* routing rules for domains
* routing rules for destination IP/CIDR
* routing rules for source LAN IP
* selected active proxy for each group
* private/reserved networks routed direct by default

When `fakedns_enabled=1`, generated config must additionally include:

* top-level `dns` using Xray FakeDNS
* top-level `fakedns` pool configured from UCI
* `dns-in` inbound on `fakedns_port`
* `dns-out` outbound with protocol `dns`
* routing rule from `dns-in` to `dns-out`
* `fakedns` in transparent inbound sniffing `destOverride`

When `fakedns_enabled=0`, these FakeDNS sections must be absent.

When `fakedns_enabled=1`, the active `fakedns_pool_v4` must be excluded from:

* the generated Xray private/reserved direct routing rule
* the nftables `reserved4` bypass set

This allows TCP traffic to FakeDNS IPs to reach Xray's transparent inbound. When `fakedns_enabled=0`, the default reserved/direct behavior remains unchanged and `198.18.0.0/15` stays reserved/direct.

When `fakedns_enabled=1` and `fakedns_hijack_dns=1`, nftables apply must add:

* `chain dns_prerouting { type nat hook prerouting priority dstnat; policy accept; }`
* LAN UDP 53 redirect to `fakedns_port`
* LAN TCP 53 redirect to `fakedns_port`
* Xray `dns-in` listen address must default to `0.0.0.0` so redirected LAN DNS can reach it on the router LAN address

When `fakedns_hijack_dns=0`, `dns_prerouting` must be absent.
When `fakedns_enabled=1` and `fakedns_hijack_dns=0`, Xray `dns-in` listen address must default to `127.0.0.1`.

FakeDNS MVP validation milestone:

* Verified on GL.iNet Flint 2 / GL-MT6000, OpenWrt 24.10.4, Xray 25.1.30.
* Generated config passed `xray run -test`.
* With `fakedns_enabled=1` and `fakedns_hijack_dns=1`, Xray listened on `:::1053`.
* nftables contained `dns_prerouting` with LAN UDP/TCP 53 redirect to `:1053`.
* nftables `reserved4` did not contain active pool `198.18.0.0/15`.
* generated Xray private/reserved direct rule did not contain active pool `198.18.0.0/15`.
* LAN client DNS queries for `x.com` through the router returned FakeDNS addresses from `198.18.0.0/15`.
* X/Twitter app on iPhone worked through this path.
* Xray logs showed `[dns-in -> dns-out]` and `[transparent -> gerwarp]` for FakeDNS-routed traffic.

Stability pass verified on GL-MT6000 / OpenWrt 24.10.4:

* Verified on GL.iNet Flint 2 / GL-MT6000 running OpenWrt 24.10.4 after `podkopchikctl update-install` from GitHub `main`.
* No critical stability issues were found.
* `podkopchikctl validate`, `podkopchikctl generate`, and `xray run -test -config /etc/podkopchik/config.generated.json` passed.
* Repeated `podkopchikctl apply` was idempotent.
* The final process state had exactly one main Xray using `/etc/podkopchik/config.json`.
* Health-check cleanup left no stale `/tmp/podkopchik/health-*.json` Xray processes and no stale health locks after checks completed.
* nftables order kept `reserved4/6` and `proxy_bypass4/6` before the final TCP TPROXY rule.
* FakeDNS stayed coherent: `dns_prerouting` existed, `198.18.0.0/15` was present as the Xray FakeDNS pool, and the same pool was absent from nft `reserved4` and the Xray private/reserved direct rule.
* Direct FakeDNS queries to `127.0.0.1:1053` returned `198.18.x.x` or `198.19.x.x`.
* Telegram IP rules for `91.108.*` and `149.154.160.0/20` were present in the active Xray config.
* Exclusions were present in UCI, nft `proxy_bypass4`, and Xray direct domain routing.
* LuCI runtime apply behavior was verified on the installed version.
* `health check skipped; another health check is already running` during race sanity checks is expected and indicates lock protection.
* A temporary health probe Xray may appear during a mid-check snapshot; it is not a stale leak if it disappears after the health check completes.
* `ucode -V` can report `unrecognized option: V` on OpenWrt and is not a Podkopchik stability failure.

Router stability recheck command memo:

```sh
podkopchikctl update-install
/etc/init.d/rpcd restart
/etc/init.d/uhttpd restart
podkopchikctl validate
podkopchikctl generate
xray run -test -config /etc/podkopchik/config.generated.json
podkopchikctl apply
sleep 2
podkopchikctl apply
sleep 2
podkopchikctl status
pgrep -a xray || true
pgrep -af '/etc/podkopchik/config.json' | wc -l
pgrep -af '/tmp/podkopchik/health-.*.json' || echo 'OK: no stale health Xray'
ls -d /tmp/podkopchik/health-port-*.lock /tmp/podkopchik/health-check.lock 2>/dev/null || echo 'OK: no stale health locks'
nft -a list table inet podkopchik | grep -nE 'proxy_bypass|reserved|dns_prerouting|tproxy|chain prerouting|chain dns_prerouting'
jsonfilter -q -i /etc/podkopchik/config.generated.json -e '@.fakedns.ipPool' || true
jsonfilter -q -i /etc/podkopchik/config.generated.json -e '@.routing.rules[@.outboundTag="direct"].ip[*]' | grep -Fx '198.18.0.0/15' && echo 'WARNING: FakeDNS pool direct-routed' || echo 'OK: FakeDNS pool not direct-routed'
nft list set inet podkopchik reserved4 | grep '198.18.0.0/15' && echo 'WARNING: FakeDNS pool in reserved4' || echo 'OK: FakeDNS pool not in reserved4'
nslookup -port=1053 x.com 127.0.0.1 || true
grep -oE '91\.108\.[0-9.]+/[0-9]+|149\.154\.[0-9.]+/[0-9]+' /etc/podkopchik/config.json | sort -u
uci show podkopchik | grep -iE 'bypass_rule|host|comment' || true
nft list set inet podkopchik proxy_bypass4 || true
```

Generated config must be valid JSON.

Before applying:

* generate temporary config
* run Xray config test
* only replace active config if validation succeeds
* keep previous working config if validation fails

### Stage 4 r7: Apply And Startup Recovery

See [the 2026-11-04 AX6000 diagnosis and release gates](AWG-STABILITY-FIXES-20261104.md).
The main Xray procd instance has explicit soft/hard `nofile=16384 16384` limits,
including in AWG-only configurations where it remains the TPROXY/FakeDNS/routing
engine. Health workers and global limits are unchanged. This is capacity
headroom, not a guarantee against socket accumulation; see
[the FD incident and verification](XRAY-FD-20261105.md).
The r7 recovery candidate was subsequently installed on the approved AX6000. See
[the scoped r7 live pass and remaining acceptance gates](AWG-STAGE4-R7-LIVE-20261104.md).
Normal Apply/health/FakeDNS/LAN tests passed; destructive runtime faults and
reboot were not exercised on the working router.

### Universal Routing Preview

The preview is not a selectable runtime mode. A pure planner renders LAN
source, DNS-set and CIDR classification before transport. Native AWG uses
existing per-profile marks/tables, with a forward guard requiring the selected
interface and a terminal unreachable route. An atomic selection transaction
replaces only owned chains and leaves DNS sets intact. VLESS remains on the
legacy Xray path; it is rejected as a native adapter rather than sent direct.

The separate FakeDNS guard tracks only configured or previously issued pools.
It uses protocol-owned destination blackholes after the transparent local rule
and an owned nft table in output, forward and postrouting. A residual FakeDNS
IP is blocked in Xray before direct rules. Previously issued pools survive
stop, disable and rollback; the ledger is independent of the runtime snapshot.
No pool is reserved on a never-enabled installation. Explicit uninstall releases
ownership; clear client DNS caches before decommissioning. See the
[preview report](UNIVERSAL-ROUTING-20261105.md) for the remaining boot,
DNS transaction and live verification gates.

### Transactional Native DNS Preview

The native DNS experiment keeps the existing dnsmasq and Xray paths unchanged.
For a protected A/AAAA answer, a separate listener flattens the relevant CNAME
chain and assigns a synthetic address per policy and real destination. Before
sending an address, it durably reserves the allocation and commits both the
route-set element and its DNAT map entry in one nftables batch. A failed or
uncertain commit returns SERVFAIL without any answer address. Direct answers
need no nft transaction; two domains sharing an upstream IP can still use
different routes. A cache hit does not bypass the transaction.

The synthetic addresses are not reused across expired leases or daemon restarts
in one generation. An independent nft gate verifies the original conntrack
destination even after DNAT and blocks escape when the classification table
is absent or the packet uses the wrong egress. Expired and unknown synthetic
addresses are never classified as ordinary direct destinations. See the
[DNS preview evidence and remaining deployment gates](UNIVERSAL-DNS-20261106.md).

An optional, explicitly configured managed LAN DNS plan redirects UDP/TCP
port 53 to concrete IPv4/IPv6 listener addresses before native route selection.
Stock dnsmasq remains the local upstream on loopback. Separate input and forward
rules block plaintext bypass if redirection is lost; a stopped listener does
not fall back to an external resolver. The firewall4 fragment accepts only LAN
ingress with the expected Podkopchik mark and tunnel egress, appended after
existing forwarding rules. Explicit DNS rollback removes only managed DNS
chains and retains the guard for previously issued addresses. These blocks
are not enabled by the installer.

The boot fixture installs the synthetic-pool guard before creating WAN routes;
the LAN DNS redirect is a separate transaction once the previous resolver and
firewall are ready. A listener crash must not release the guard or permit
plaintext DNS fallback. The preview refuses software/hardware flow offload and
live flowtables. An independent procd watchdog restores tested stock DNS and
firewall state on timeout, retaining the quarantine. The private trial journal
uses a monotonic deadline and refuses to confirm an unfinished prior-boot
trial. See [release qualification](UNIVERSAL-RELEASE-VM-20261106.md) for the VM
evidence, encrypted-DNS limits, and outstanding physical deployment gates.

The [mixed transport canary](UNIVERSAL-MIXED-CANARY-20261106.md) retains a
synthetic address for protected DNS policies that share a real CDN address.
Native AWG uses kernel DNAT and policy routing. A separate VLESS adapter uses
TCP TPROXY after DNAT, with a dedicated Xray inbound and no direct outbound.
VLESS fallback does not forward unsupported UDP. The strict canary denies
unclassified forwarding, including real IPs cached before migration. Pool
admission rejects live-network and previously issued ranges; neither a new
production pool nor the canary is enabled by default.
The [AX6000 acceptance plan](UNIVERSAL-AX6000-ACCEPTANCE.md) adds offline
selection from explicitly approved pools against complete inventory. A
reserved conntrack mark byte pins a protected tuple to its first transport;
transport changes require a new tuple instead of migrating the old NAT state.
The independent output guard also blocks locally generated packets with an
owned AWG inner source on any non-owning egress, including TCP resets.
An explicitly approved RFC1918 /24 is eligible for the isolated trial only;
the default candidate set and protected destination validation are unchanged.
The [wired AX6000 pilot](UNIVERSAL-AX6000-PILOT.md) uses a separate runtime-only
recovery service. It preserves home services and persistent configuration and
keeps both synthetic pool generations in quarantine after rollback.

The earlier cone-disabling mitigation was withdrawn before deployment. The
main process must preserve full-cone behavior. The reviewed source-core
candidate instead limits each dokodemo transparent reply cache to 128 sockets,
expires entries after 120s idle with a 30s sweep, and recreates source sockets
on demand. The outbound full-cone socket, association key, routing, DNS/FakeDNS,
AWG roles and existing FD limit are unchanged. This is not a global FD budget.
The cache patch is built on a workstation, not on OpenWrt; both v26.3.27 and
v26.10.31 are source-hash-pinned. No cache timeout UCI option is invented.

A reviewed local core can be staged by root in private
`/tmp/podkopchik/xray-local/xray` and installed explicitly with
`podkopchikctl xray-install local SHA256`. Expected hash, owned private staging,
regular single-link file, matching ELF/config and build marker are required.
The existing managed binary/rollback path is reused; package-owned Xray is not
overwritten. This path is not offered through a new LuCI upload/ACL or background
job. LuCI displays the installed source and reported reply-cache build, and
warns that stock-core updates remove the local patch. Local build metadata is
not an official signature. No installation or core switch is automatic.
See [cache fix, evidence and remaining gates](XRAY-UDP-CACHE-FIX-20261105.md).

The subsequent AX6000 production pilot was rolled back and its release is HELD:
see [the scoped results](XRAY-UDP-LIVE-PILOT-20261105.md). Early live UDP inode
retirement passed, but unknown fake destinations were observed towards WAN;
the original core reproduced direct attempts in a contained synthetic control.
Neither long-term stability nor complete fail-closed acceptance is claimed.
The operator-only pilot/measurement tools are not installed by the application.

- Missing enabled connections/rules or failed candidate validation must not
  change `routing_enabled`, stop Xray, sync AWG or remove current interception.
- Runtime Apply and failover changes serialize, validate, preserve an owned
  last-working Xray/nft pair, arm an independent LAN forward guard, replace
  state and verify the new main Xray PID owns the transparent TCP listener.
- Checkpoints are private immutable `.working-*` directories under
  `/etc/podkopchik`, selected by an atomic `working-state.name` pointer. Keep
  current and one preceding generation. They contain secrets, not public data.
- A runtime failure restores the validated checkpoint, owned policy routes and
  AWG interfaces referenced by that config, without rewriting pending UCI
  roles. Failed recovery retains the guard and records an explicit error.
- The guard is only `inet podkopchik_guard`, forward priority `-10`, dropping
  forwarding from last-applied/pending LAN interfaces. It does not alter
  INPUT/OUTPUT, default routes or unrelated firewall tables. This fallback
  deliberately blocks otherwise-direct LAN forwarding too. If nft itself is
  unavailable, report that fail-closed cannot be guaranteed, never claim success.
- Startup nft failure must not start the candidate Xray or report routing
  active. It may start a validated last-working pair under the guard. Service
  stop/restart with routing requested retains protection; explicit Cleanup is
  the separate action that persists OFF and removes the owned guard.
- Routing requested and routing applied are distinct status fields. Readiness
  requires an actual main Xray listener, not a health probe or an old PID.
- Failover publishes new selected state only after the synchronous core restart
  succeeds. No restart is requested when selection did not change.
- Xray/curl stderr must be separate. Retained root-only redacted diagnostics
  are bounded to 4096 bytes per file; private raw files/configs are cleaned.
  Curl 28 alone means probe timeout with an unconfirmed TCP stage; only a
  corresponding Xray dial error identifies a TCP connect timeout.
- Guarded deployment/rollback must preserve explicit routing OFF. Restoring r6
  requires the new helper to release any owned guard only after listener
  confirmation (or explicit OFF). Uninstall removes the guard before its helper.

This is controlled recovery, not power-loss atomicity. Flow-offload/exhaustive
WAN-leak capture, real boot and failure-injection acceptance remain separate.

nftables / TPROXY

Podkopchik must use nftables/firewall4 style rules.

Requirements:

* require `ip-full`; BusyBox `ip` is not sufficient for fwmark policy routing
* create only Podkopchik-owned table/chains
* do not flush the whole ruleset
* do not modify unrelated OpenWrt firewall rules
* exclude local/private/reserved networks from loops
* exclude configured proxy endpoint destination IPs from TPROXY interception
* cleanup must be idempotent
* cleanup must remove only Podkopchik-created rules
* DNS redirect rules must also be Podkopchik-owned

Proxy endpoint bypass:

* Podkopchik must collect endpoint hosts from configured VLESS links during nftables apply
* endpoint IP literals are added directly to Podkopchik-owned `proxy_bypass4` or `proxy_bypass6` sets
* endpoint hostnames are resolved during apply and resolved IPs are added to those sets
* unresolved endpoint hostnames must warn but must not fail apply
* bypass return rules must run before the final generic TPROXY rule
* this prevents LAN clients with their own VLESS clients from being transparently redirected into the router Xray when connecting to the same proxy server

Manual direct exclusions:

* stored as UCI `bypass_rule` sections with `enabled`, `host`, and optional `comment`
* `host` accepts only domain, IPv4, IPv6, IPv4 CIDR, or IPv6 CIDR values
* URL schemes, paths, and ports are rejected in LuCI
* no port-specific matching is implemented
* IPv4/CIDR entries are added to `proxy_bypass4`
* IPv6/CIDR entries are added to `proxy_bypass6`
* domain entries are routed direct in generated Xray config above normal domain proxy rules
* domain entries are resolved during apply and resolved IPs are added to `proxy_bypass4` or `proxy_bypass6`
* unresolved manual bypass domains warn but must not fail apply
* manual bypass entries complement automatic proxy endpoint bypass entries

Installer

install.sh must:

* check that it runs as root
* check OpenWrt and report model, OpenWrt version, target, architecture, kernel, `/overlay` free space, and install mode
* use the shared `packages.sh` adapter: opkg for OpenWrt 24.10, apk for 25.12; refuse a missing expected manager instead of silently using the other one
* require `/overlay` to have at least 15 MB free before package installation
* warn when `/overlay` has less than the recommended 25 MB free
* detect conflicting proxy applications before package installation and stop by default
* treat an existing `/etc/config/podkopchik` as update mode, not as a conflict
* fetch the raw-install payload/shared adapter after space checks when needed, before conflict detection and package changes
* run `opkg update` or `apk update` with package signature verification enabled
* install missing required dependencies automatically
* report dependencies that are already installed
* validate after dependency installation that `ip-full`/`iproute2`, `nft`, `ucode`, `xray`, a download tool, LuCI, `rpcd`, and `uhttpd` are available
* install files into the correct OpenWrt paths
* normalize static payload directories to `0755` before tar installation so source archive root/parent metadata cannot propagate `0700` or group-writable `0775` modes; preserve file permissions and unrelated private directories
* create /etc/config/podkopchik if missing
* preserve existing /etc/config/podkopchik
* support running from a checked-out repository or from the raw GitHub `install.sh` by downloading the `main` branch payload when needed
* enable and start service
* restart rpcd/uhttpd if needed
* clear LuCI cache
* run post-install `podkopchikctl validate` and `podkopchikctl status`
* not reboot automatically

Installer dependencies:

* `luci-base`
* `luci-light`
* `rpcd`
* `rpcd-mod-file`
* `rpcd-mod-luci`
* `uhttpd`
* `ucode`
* `ucode-mod-fs`
* `ucode-mod-uci`
* `ucode-mod-ubus`
* `curl`
* `ca-bundle`
* `jsonfilter`
* `nftables-json`
* `kmod-nft-tproxy`
* `firewall4`
* `ip-full`
* `dnsmasq`
* `xray-core`
* `unzip`

Default conflict list:

* Podkop / `luci-app-podkop`
* sing-box
* Passwall
* OpenClash
* Mihomo / Clash
* v2rayA
* standalone non-Podkopchik Xray init/config

No separate user-facing safe mode is required.

Uninstaller

uninstall.sh must:

* stop Podkopchik service
* cleanup Podkopchik nftables rules
* remove installed files
* preserve /etc/config/podkopchik unless purge is explicitly requested
* be idempotent
* remove registered Podkopchik/i18n packages through opkg/apk before manual file cleanup; raw installs require no package removal
* preserve the UCI file independently of package removal scripts unless purge succeeds

Updates

LuCI Updates page must:

* show current Podkopchik version
* support update_channel `main` and `stable`
* default to `main` for development installs
* in `main` mode, download the configured GitHub branch archive without requiring a GitHub Release or sha256 asset
* warn that `main` mode is for development/testing and less safe than stable releases
* in `stable` mode, check GitHub Releases
* show latest available version
* show changelog if available
* download update package/archive
* verify sha256 in `stable` mode
* preserve /etc/config/podkopchik
* install update
* restart needed services
* provide rollback command

Do not update Xray core automatically in `0.1.0-beta`. Explicit user-requested
core updates are supported independently of application updates; see below.

## Manual Xray Core Manager

The Updates page exposes installed version/source, architecture, available
version for each source, last check and operation status. No version is guessed.
`podkopchikctl xray-status`, `xray-check package|official`,
`xray-install package|official`, and `xray-rollback` implement the same path.
LuCI uses short `xray-start-*` requests and polls background-job status through
`xray-status`; closing the page does not cancel an in-progress update.

All runtime Xray calls use `xray.sh`. Package mode uses the native package binary;
official/rollback mode uses `/usr/libexec/podkopchik-core/xray`. The selector,
previous executable and last update status live in that separate directory,
which application payload replacement does not overwrite. Normal uninstall
preserves this directory; explicit purge removes it.

Updates support Linux aarch64 and x86_64, use bounded HTTPS downloads, check
free space in persistent and temporary filesystems, and lock out concurrent
apply/health changes. Package mode targets only `xray-core` through opkg/apk
(with required dependencies resolved by the manager); official mode
uses the fixed XTLS/Xray-core release endpoint, published SHA256, matching ELF
machine and executable version. Extraction is limited to the fixed `xray`
member. The active config must pass candidate validation before activation.

Updates require active working routing and one configured main proxy.
Only the Xray procd instance is restarted; nft/FakeDNS/policy routing are
snapshotted and must remain unchanged. Verification checks a single selected
main executable, TCP transparent listener, optional FakeDNS UDP listener, and
HTTPS egress through the configured main proxy. Failure restores the old
binary/selector. Package dependencies/metadata are not downgraded by runtime
binary rollback. Interrupted operations use traps; abrupt power loss/SIGKILL
requires inspection of locks and possibly the retained previous binary.

`xray-status` separates the active executable version (`installed`) from
`package_version` and reports `package_manager`. APK installed/candidate
versions use structured `apk query` JSON. Package ownership is checked before
activation. Official/rollback executables remain separate from package files
and survive application reinstall/update. Neither source performs general
firmware/package updates. See [migration and recovery](OPENWRT-25.12-MIGRATION.md).

## Isolated VLESS Checks

Proxy Links checks pasted/changed VLESS URIs before final save and has a repeat
button. Checking failure does not block saving. Secret input uses RPC environment
data, not executable arguments; temporary files are root-only. A locked SOCKS
port (20999), live Xray PID and listener ownership are required. Results include
status, normalized error category, HTTPS request duration in milliseconds, IPv4
exit address, timestamp and a 300-second freshness interval. `api.ipify.org`
provides the exit IP; provider failure must never fabricate an IP or UP result.
The isolated checker does not publish failover state or alter LAN routing.

Existing health probes additionally write optional metrics/time to state,
preserving the existing fail/restore thresholds and selection algorithm.
External IP failure leaves that metric empty; it does not invalidate an otherwise
successful existing reachability test. The UI expires stale success/metrics.

## AWG 3.1 Configuration Management: Stage 1 Baseline

The Stage 1 baseline (superseded by Stages 2–3 below) manages multiple imported profiles without
changing the VLESS page, UCI routing model, Xray, FakeDNS, nftables or services.
There is no tunnel lifecycle, handshake, HTTPS check, AWG routing target or
AWG failover in this stage. Configuration validity is not network availability.

The root-only rpcd executable plugin exposes `podkopchik.awg` methods:
`list` (read ACL); `import`, `replace`, `rename`, `validate`, `delete` (write ACL).
Input uses JSON on stdin, not shell arguments, environment variables or an
arbitrary upload path. Backend validation is mandatory independently of LuCI.
No raw configuration/key read method or file ACL is provided.

Storage is `/etc/podkopchik/awg/`, root-owned mode `0700`. IDs and revision
names are random 128-bit hex strings independent of display/upload filenames.
Each ID has a `0600` JSON metadata record and its own `0600` revision `.conf`.
A new config is validated, written exclusively, flushed and atomically renamed;
metadata is atomically renamed last as the commit point. Failed replacement
keeps the old record/config. Exclusive OS file locks serialize operations and
release automatically when the RPC process exits. Symlinks, hardlinked files,
unsafe permissions and wrong ownership are rejected. Interrupted commits can
leave root-only orphan revisions; deletion removes only that ID's revisions.
No guarantee of power-loss durability beyond filesystem rename is asserted.

Validation uses an allowlist derived from tools `v3.1.20260812` and kernel
`v3.1.20260906`. It covers keys, IP/CIDR, IPv4/IPv6/domain endpoints, all
supported AWG device/peer parameters including CPS and timer ranges, and rejects
hooks, route-management directives, unknown sections and directives. Files are
limited to 64 KiB; at least one 3.x parameter is required rather than labelling
plain WireGuard/older AWG as 3.1. This is a strict supported profile format,
not proof of server protocol version or kernel acceptance of every combination.
Errors contain only a fixed code, line and allowlisted parameter name.

Profiles are kept by OpenWrt sysupgrade via `keep.d`; backups contain secrets.
Normal uninstall preserves profiles, explicit purge removes them.
No AWG packages or kernel modules are installed by this stage.
AX6000 25.12.6/kernel 6.12.112 previously passed module/tools checks; no handshake
has been verified. See [Stage 1 deployment and tests](AWG-STAGE1.md) and
[historical compatibility research](XRAY-AWG-RESEARCH.md).

## AWG 3.1 Runtime: Experimental Stages 2–3

The existing protected store/parser is retained. `awg_network.uc` owns kernel
lifecycle; `awg_manage.uc` coordinates UCI roles, transactions and RPC;
`awg_cli.uc` reconciles autostart, health and shutdown. The authenticated RPC
adds start/stop/restart/check/assign/set_probe/set_interception/recover; read
access remains list-only and never exposes private configuration contents.
Native ucode UCI named sections use set(config, section, type), not the LuCI-only
section() helper. CLI adds awg-list/start/stop/restart/check/recover commands.

Bindings are normal `proxy` sections with protocol `amneziawg`, an immutable
32-hex `awg_id`, and tag `awg_ID`. VLESS sections without protocol remain VLESS;
their URI format is not migrated. Roles are main, backup (1–3), rules_only and
disabled. Only the internal auto_proxy_group is maintained; manual groups are
preserved. Assignment checks real health before selecting a main/backup, writes
a protected rollback journal, serializes with health/config apply, validates
Xray, and restores previous UCI/config/state on apply failure. Crash recovery
is explicit or runs before service startup. This is not fsync/power-loss atomicity.

Stable AWG interfaces use `paw` plus 12 ID hex digits; private tables are
42000–50191, policy priority 20000–28191 and mark 536870912 + table, with
protocol 186. Collisions are refused, never taken over. Both families have
mark/oif policy rules and terminal unreachable defaults. Addresses use
noprefixroute and are checked against LAN/WAN/other tunnel prefixes. Interface
alias is set separately after link creation and verified, including runtime
ifindex tracking for interrupted creation. No awg-quick, hooks, main routes or
global sysctl changes. Strict global RPF is refused. Peer endpoints keep normal
WAN routing and supplement automatic endpoint bypass.

Xray AWG outbounds are marked/interface-bound freedom with ForceIP variants.
Unproven ownership, missing guards or stopped interfaces generate blackholes;
startup safely blocks stale AWG outbounds if normal regeneration fails. A real
TCP DNS resolver is added only with enabled AWG, routed through the active
automatic connection (or a fresh measured-UP independent connection when the
automatic group is blocked, without unblocking data rules). This is not per-profile
DNS; ForceIP skips FakeDNS and has no
system-resolver fallback. Local StatsService binds only 127.0.0.1:10085, rejects
listener collisions and reports unavailable counters honestly.

AWG availability requires a device-bound, pinned-IP HTTPS request with certificate
verification plus an actual handshake. HTTPS total duration is not ICMP RTT.
Checks expose measured counters, last check/success and exit IP when the probe
response supplies it. No interface-only UP claim. Existing fail/restore
thresholds and ordered fallback apply across both protocols; all-down is blocked.

Stage 4 separates `udp_interception=0` and `ipv6_interception=0`. UDP alone
does not enable IPv6 or AAAA FakeDNS. The old explicit `extended_interception`
value is a fallback only for absent new options; saving the new controls removes
it. LuCI assigns checkbox properties, not a boolean HTML attribute containing
the string `false`. Missing settings therefore render unchecked.

IPv4 TCP TPROXY remains enabled while routing is active. IPv6 interception adds
the IPv6 local policy route in table10991 and the FakeDNS pool2001:2::/48;
without it, interception is explicitly IPv4-only. UDP can be enabled independently
for the enabled address families. ND/RA/ICMPv6 are never intercepted, and IPv6
multicast/link-local/ULA/loopback remain bypassed. DNS/53 returns to the existing
NAT redirect chain when redirection is configured, for both TCP and UDP; otherwise
UDP/53 follows normal routing rules when UDP interception is enabled. Router
output and proxy endpoint destinations remain excluded. No UDP/443 block.

Enabling IPv6 through LuCI requires a usable LAN IPv6 address, an IPv6 address
and AllowedIPs `::/0` in every enabled AWG profile, its owned live IPv6 route,
and pinned IPv6 HTTPS through every enabled connection, including VLESS. Partial
IPv6 AllowedIPs are conservatively unsupported by the toggle. WAN IPv6 alone
does not pass this gate. Direct UCI Apply also runs the structural LAN/profile
preflight before any nft replacement. Regular health checks include IPv6 HTTPS
while IPv6 interception is enabled. No imported key or main default is changed.

Fail/restore thresholds have an effective minimum of two consecutive results.
Unknown/expired results break the consecutive streak. A new backup requires a
latest successful probe younger than 300 seconds, not merely a retained UP
state. `switch_cooldown` defaults to 60 seconds (0–3600): it delays preference
changes only while the current path has a fresh successful check, never escape
from a failed path or all-down blocking. Switch reasons/times remain in health
state/events and syslog; no Xray restart occurs without a selection change.

FakeDNS remains optional/off by default. nft replacement is one checked atomic
batch; failures retain the previous table and remove only newly acquired policy
resources. No global nft flush or default-route change. Disabled protocols,
unmatched/direct rules and explicit exclusions are outside proxy protection.
Full IPv6/QUIC and exhaustive WAN-leak acceptance are pending, not inferred from
local mocks. See [Stage 4 verification and deployment](AWG-STAGE4.md).

The authorized [AX6000 live pass, 2026-10-29](AWG-STAGE4-LIVE-20261029.md)
subsequently verified IPv4 TCP/UDP through AWG/VLESS, threshold failover/return,
scoped all-down packet counters and independent procd snapshot recovery.
IPv6/QUIC/exhaustive pcap and reboot remain unverified. Deployment requires a
matching armed independent watchdog; canonical snapshots reject root/system
parent directory entries. No private staging `tar .` repack is permitted.

The live AX6000 isolated controller and HTTPS tests passed; installed application
roles/failover, reboot recovery, real UDP/IPv6 and acceleration still require
the explicit deployment acceptance in [AWG-STAGE23.md](AWG-STAGE23.md).

Required CLI

podkopchikctl must support:
podkopchikctl status
podkopchikctl generate
podkopchikctl validate
podkopchikctl apply
podkopchikctl restart
podkopchikctl cleanup
podkopchikctl health
podkopchikctl update-check
podkopchikctl update-install
podkopchikctl rollback

Testing expectations
At minimum:
find . -name "*.sh" -exec sh -n {} \;
sh -n install.sh
sh -n uninstall.sh
sh tests/install_workflow_smoke.sh
find . -name "*.json" -exec python3 -m json.tool {} \; >/dev/null

Also include sample fake VLESS links for:

* TCP/REALITY
* XHTTP/REALITY

Do not include real proxy links.
