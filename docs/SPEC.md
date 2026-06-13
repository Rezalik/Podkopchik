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

Target platform:
- OpenWrt 24.10+
- LuCI openwrt-24.10 branch
- firewall4 / nftables
- ip-full for fwmark policy routing
- opkg package manager
- no Python, Node.js, npm, Docker, or heavy runtime dependencies on the router

Primary target device:
- Xiaomi Redmi Router AX6000
- OpenWrt 24.10.1

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
3. Domain Groups
4. IP Rules
5. LAN Devices
6. DNS
7. Updates
8. Logs
9. Advanced

Pages that change active routing inputs must not stop at a UCI save. Save & Apply on Proxy Links, Domain Groups, IP Rules, Exclusions, LAN Devices, DNS, and active Advanced settings must invoke the Podkopchik runtime apply path, or cleanup when the service is disabled, so the active Xray config and Podkopchik-owned nftables state match the saved settings.

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

Generated config must be valid JSON.

Before applying:

* generate temporary config
* run Xray config test
* only replace active config if validation succeeds
* keep previous working config if validation fails

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
* check OpenWrt
* use opkg for OpenWrt 24.10
* install required dependencies if possible
* install files into the correct OpenWrt paths
* create /etc/config/podkopchik if missing
* preserve existing /etc/config/podkopchik
* enable and start service
* restart rpcd/uhttpd if needed
* not reboot automatically

No separate user-facing safe mode is required.

Uninstaller

uninstall.sh must:

* stop Podkopchik service
* cleanup Podkopchik nftables rules
* remove installed files
* preserve /etc/config/podkopchik unless purge is explicitly requested
* be idempotent

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

Do not update Xray core automatically in `0.1.0-beta`.

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
find . -name "*.json" -exec python3 -m json.tool {} \; >/dev/null

Also include sample fake VLESS links for:

* TCP/REALITY
* XHTTP/REALITY

Do not include real proxy links.
