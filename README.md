# Podkopchik

Podkopchik is an OpenWrt 24.10+ LuCI application for routing selected LAN traffic through Xray VLESS proxy links.

Package: `luci-app-podkopchik`  
Service: `podkopchik`  
UCI config: `/etc/config/podkopchik`  
Generated Xray config: `/etc/podkopchik/config.json`  
Runtime state: `/tmp/podkopchik/state.json`

Release: `0.1.0-beta`

## What 0.1.0-beta Includes

- LuCI JavaScript pages for status, proxy links, rule presets, domain groups, IP rules, direct exclusions, LAN devices, DNS, updates, logs, and advanced settings.
- UCI-backed VLESS TCP/REALITY and VLESS XHTTP/REALITY proxy definitions.
- Simple proxy roles: one main proxy, optional backup proxies, and disabled links.
- Internal automatic failover support for the selected main proxy and backups.
- Rule presets for popular services. Presets create ordinary editable domain and IP rules.
- Domain, destination CIDR, and LAN source IP routing rules.
- Manual direct exclusions for host/IP/CIDR entries that must bypass the transparent proxy.
- Xray transparent inbound with sniffing enabled and FakeDNS disabled.
- dnsmasq-based DNS with optional LAN UDP/TCP 53 redirect.
- Podkopchik-owned nftables/firewall4 table and cleanup.
- Proxy endpoint destinations are bypassed before transparent proxy interception so LAN clients can still connect to the same VLESS servers directly.
- Experimental Xray FakeDNS config generation and optional LAN DNS hijack, disabled by default.
- LAN device speed limit configuration and diagnostics only. Real `tc`/`ifb` enforcement is not active in this beta.
- Config validation before apply, preserving the previous working Xray config on failure.
- GitHub update checks with a development `main` branch channel and a future verified stable release channel.

This beta does not include subscription URLs, geoip/geosite databases, traffic statistics, QR import/export, FakeDNS by default, Xray core auto-updates, Docker, or router-side Python/Node.js runtimes.

## Install On OpenWrt 24.10 / 25.12

OpenWrt 24.10 uses `opkg`; OpenWrt 25.12 uses `apk`. The installer selects
the native manager from `/etc/openwrt_release`, not just the first binary in
PATH. A missing expected manager is an error. See
[AX6000 migration and recovery](docs/OPENWRT-25.12-MIGRATION.md) before changing
firmware. Firmware upgrades are not performed by Podkopchik.

SSH into the router as root. The recommended GitHub installer flow is:

```sh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/rezalik/Podkopchik/main/install.sh)"
```

On a clean image without curl, use OpenWrt's wget entry point instead:

```sh
wget -O /tmp/podkopchik-install.sh https://raw.githubusercontent.com/rezalik/Podkopchik/main/install.sh
sh /tmp/podkopchik-install.sh
```

If you already copied or extracted this repository to the router, run the local installer instead:

```sh
cd /tmp
curl -fL https://github.com/rezalik/Podkopchik/archive/refs/heads/main.tar.gz -o podkopchik.tar.gz
tar -xzf podkopchik.tar.gz
cd Podkopchik-main
sh install.sh
```

The installer first performs a system preflight, reports the router model, OpenWrt version, target, architecture, kernel, `/overlay` free space, and install mode. Existing `/etc/config/podkopchik` means update mode and is preserved.

Because user configuration is preserved, uninstalling and reinstalling Podkopchik does not remove old proxy tags or routing targets from `/etc/config/podkopchik`. During generate/apply, Podkopchik checks enabled routing rules for stale targets. If an old target no longer exists and the internal `auto_proxy_group` is valid, the rule target is repaired to `auto_proxy_group`; otherwise apply stops with a clear error naming the broken rule.

Free space thresholds:

- hard minimum: 15 MB free in `/overlay`
- recommended: 25 MB free in `/overlay`

The installer stops before installing packages when free space is below the hard minimum. Between 15 MB and 25 MB it continues with a clear warning.

Before installing files, the installer checks for conflicting proxy applications such as Podkop, sing-box, Passwall, OpenClash, Mihomo, Clash, v2rayA, and a standalone non-Podkopchik Xray service/config. It does not remove them automatically.

The raw installer downloads its payload/shared package adapter after the space
check when needed. Before package changes it checks conflicts, then runs
`opkg update` / `apk update` and installs missing dependencies with
`opkg install` / `apk add`. It validates dependencies, installs files and the
Russian catalog, restarts `rpcd`/`uhttpd`, clears LuCI cache and enables/starts
Podkopchik. It never reboots or upgrades the whole system.

Installer-managed dependencies:

```text
luci-base luci-light rpcd rpcd-mod-file rpcd-mod-luci uhttpd ucode ucode-mod-fs ucode-mod-uci
ucode-mod-ubus curl ca-bundle jsonfilter nftables-json kmod-nft-tproxy
firewall4 ip-full dnsmasq xray-core unzip
```

`ip-full` is installed automatically when missing. BusyBox `/sbin/ip` is not sufficient because Podkopchik needs `iproute2` fwmark policy routing for TPROXY.

After install, the service is enabled and its health loop can run. Traffic interception remains inactive until you configure at least one valid VLESS proxy, one routing rule, and click **Apply** in LuCI or run:

```sh
podkopchikctl apply
```

Open LuCI at **Services → Podkopchik**.

## Example Fake VLESS Links

These are documentation-only examples with reserved domains and fake keys:

```text
vless://11111111-2222-3333-4444-555555555555@example.invalid:443?type=tcp&security=reality&sni=example.invalid&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=abcd1234&flow=xtls-rprx-vision#fake-tcp-reality
vless://aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:xhttp.example.invalid:443?type=xhttp&security=reality&sni=xhttp.example.invalid&fp=chrome&pbk=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB&sid=1234abcd&path=%2Fxhttp&host=xhttp.example.invalid#fake-xhttp-reality
```

Do not expect these links to connect.

## Configure

1. Add proxy links under **Proxy Links**. Choose exactly one **Main proxy** and, optionally, up to three **Backup proxy** links.
2. Optional: open **Presets**, choose a service and target, then click **Add preset**. Presets create normal rules that can be edited or deleted later.
   - Telegram adds domain rules and Telegram IP ranges.
   - YouTube, Instagram, TikTok, X / Twitter, Discord, OpenAI / ChatGPT / Codex, and Canva are domain-only in this beta step.
   - OpenAI, ChatGPT, Codex, Canva, Discord, and CDN domain lists can change over time, so presets are a starting point rather than a permanent guarantee.
3. Create or edit **Domain Groups** such as YouTube, ChatGPT, or Instagram. Put one domain per line and choose a target:
   - **Automatic: main + backups** uses the main proxy and backups.
   - **Specific proxy** sends the group to one selected proxy.
   - **Direct** bypasses the proxy.
   - Each visual domain group is stored as one `domain_rule` UCI section with multiple `list domain` entries. Older one-section-per-domain configs are still read and are migrated on save.
4. Add optional routing rules:
   - **IP Rules** for CIDRs such as `8.8.8.8/32`.
   - **LAN Devices** for source IP behavior: `full_proxy`, `rules_only`, or `direct`. LAN device speed limit settings can be saved here, but enforcement is diagnostic-only in this beta.
5. Add optional **Exclusions** for direct access to hosts, IPs, or CIDR networks that should never be transparently proxied, for example `famalymovi.ru`, `5.42.117.16`, or `panel.example.com`. Do not include scheme, path, or port.
6. Optional: enable LAN DNS redirect on the **DNS** page.
7. Click **Apply** on the **Status** page.

Traffic for domains and IPs not listed in a rule goes direct by default.

Podkopchik validates the generated Xray config before replacing `/etc/podkopchik/config.json`. If validation fails, the previous working config remains in place.

When routing is applied, Podkopchik resolves configured VLESS endpoint hosts and adds their IP addresses to a Podkopchik-owned nftables bypass set. This prevents LAN devices with their own VLESS clients from being transparently redirected back into the router Xray when they connect to the same proxy server, for example on TCP/443. If an endpoint hostname cannot be resolved during apply, routing still applies and Podkopchik logs a warning.

Manual exclusions use this UCI model:

```text
config bypass_rule
	option enabled '1'
	option host 'famalymovi.ru'
	option comment '3x-ui / VPS direct'
```

IP and CIDR exclusions are added to the Podkopchik-owned nftables `proxy_bypass4` or `proxy_bypass6` sets before the final TPROXY rule. Domain exclusions are added to an Xray `direct` domain rule above normal proxy domain routing and are also resolved during apply so their IPs can bypass TPROXY. Port-specific exclusions are intentionally not implemented in this beta step.

## Experimental FakeDNS

FakeDNS is off by default. It can be enabled from LuCI under Podkopchik -> DNS or with UCI. Enabling `fakedns_enabled` changes generated Xray config: it adds Xray `dns`, `fakedns`, `dns-in`, and `dns-out` sections and adds `fakedns` to transparent inbound sniffing. LAN DNS hijack is separate and only active when `fakedns_hijack_dns=1`.

Use FakeDNS for mobile or CDN-heavy apps that do not route reliably with domain-only sniffing. The X/Twitter app is the main tested example. When FakeDNS and LAN DNS hijack are enabled, LAN DNS queries on UDP/TCP port 53 are redirected to Xray FakeDNS, and clients can receive fake IP addresses from `198.18.0.0/15`. That is expected. Private DNS, DoH, iCloud Private Relay, or another VPN on a client can bypass router DNS and prevent this path from working.

FakeDNS MVP was verified on a GL.iNet Flint 2 / GL-MT6000 running OpenWrt 24.10.4 with Xray 25.1.30. The verified path is:

- generated Xray config passes `xray run -test`;
- Xray `dns-in` listens on port `1053`;
- nftables `dns_prerouting` redirects LAN UDP/TCP 53 to `:1053`;
- active FakeDNS pool `198.18.0.0/15` is excluded from nft `reserved4`;
- active FakeDNS pool `198.18.0.0/15` is excluded from Xray's private/reserved direct rule;
- a LAN client DNS query for `x.com` through the router returns `198.18.x.x` or `198.19.x.x`;
- X/Twitter app on iPhone works through the FakeDNS path;
- Xray logs show `[dns-in -> dns-out]` DNS handling and `[transparent -> gerwarp]` for FakeDNS traffic.

This MVP does not enable UDP TPROXY and does not add UDP/443 blocking.

Enable for config validation experiments:

```sh
uci set podkopchik.main.fakedns_enabled='1'
uci commit podkopchik
podkopchikctl generate
xray run -test -config /etc/podkopchik/config.generated.json
```

Enable experimental LAN DNS hijack to Xray FakeDNS:

```sh
uci set podkopchik.main.fakedns_enabled='1'
uci set podkopchik.main.fakedns_hijack_dns='1'
uci commit podkopchik
podkopchikctl apply
nft list table inet podkopchik
```

The same settings are available in LuCI on the DNS page:

- Enable FakeDNS
- Hijack LAN DNS queries
- FakeDNS port
- FakeDNS IPv4 pool
- FakeDNS pool size
- FakeDNS listen address

Use Save & Apply on that page to save UCI, apply LuCI changes, and run the Podkopchik runtime apply path.

When DNS hijack is enabled, the Xray `dns-in` inbound listens on `0.0.0.0` by default so nft redirected LAN DNS packets can reach it on the router LAN address. The nft rule is still limited to the configured LAN interface. Without DNS hijack, `dns-in` listens on `127.0.0.1`.

When FakeDNS is enabled, the active FakeDNS IPv4 pool, default `198.18.0.0/15`, is not added to the nftables reserved bypass set and is not routed direct by Xray's private/reserved rule. This lets TCP traffic to fake IPs enter the Xray transparent inbound. When FakeDNS is disabled, `198.18.0.0/15` remains treated as a reserved/direct range.

Acceptance checklist on a router:

```sh
podkopchikctl generate
xray run -test -config /etc/podkopchik/config.generated.json
podkopchikctl apply
netstat -lnp 2>/dev/null | grep -E '1053|12345'
nft -a list table inet podkopchik | grep -A10 -B3 'dns_prerouting'
nft list set inet podkopchik reserved4 | grep '198.18.0.0/15' || echo 'OK: FakeDNS pool is not in reserved4'
jsonfilter -q -i /etc/podkopchik/config.generated.json -e '@.routing.rules[*].ip[*]' | grep '198.18.0.0/15' || echo 'OK: FakeDNS pool is not direct-routed'
nslookup x.com 192.168.8.1
logread | grep -iE 'dns-in|dns-out|transparent.*198\\.18|transparent.*198\\.19'
```

Rollback:

```sh
uci set podkopchik.main.fakedns_enabled='0'
uci set podkopchik.main.fakedns_hijack_dns='0'
uci commit podkopchik
podkopchikctl apply
```

## CLI

```sh
podkopchikctl status
podkopchikctl generate
podkopchikctl validate
podkopchikctl apply
podkopchikctl restart
podkopchikctl cleanup
podkopchikctl health
podkopchikctl shaping-status
podkopchikctl update-check
podkopchikctl update-install
podkopchikctl rollback
```

`cleanup` disables routing interception and removes only the Podkopchik-owned nftables table and matching policy routing entries.

## LAN Device Speed Limits

Podkopchik can store per-LAN-device speed limit settings and show diagnostics for them. This is Phase 1 only: no `tc`, `ifb`, qdisc, nft mark, or interface shaping rules are created yet.

Ordinary WAN-side QoS rules matching a LAN source IP can fail for proxied traffic. After TPROXY hands traffic to Xray, the WAN connection is usually from the router to the VLESS server, so the original LAN source IP is no longer visible on the WAN side.

The intended enforcement design is LAN-side classification before or around TPROXY, where the original LAN source IP is still visible:

- upload: classify client-to-router traffic at LAN ingress
- download: classify router-to-client traffic at LAN egress
- cleanup: remove only Podkopchik-owned shaping state

Check configured speed limit diagnostics with:

```sh
podkopchikctl shaping-status
```

Real enforcement requires physical-router testing with proxied LAN traffic before it is enabled.

## Health And Failover

Health checks first validate generated Xray configs. When `xray` and `curl` are available, Podkopchik starts a temporary localhost SOCKS inbound per proxy and probes the configured URL through that outbound. Results are real `up` or `down` observations.

If the probe path is not available, status is recorded as `unknown` with the reason. Podkopchik does not fake `up` results. Failover only happens after thresholded real failures; unknown status keeps the current/default group selection.

## Update

From LuCI, open **Updates**, click **Check**, then **Install Update**.

From SSH:

```sh
podkopchikctl update-check
podkopchikctl update-install
```

The default update channel is `main`, which downloads the configured GitHub branch archive directly for development and VM testing. This mode does not require a GitHub Release or `.sha256` file.

For future stable releases, set `podkopchik.main.update_channel=stable`. Stable mode uses GitHub Releases, requires a matching `.tar.gz` release asset and `.sha256` asset, verifies the archive, preserves `/etc/config/podkopchik`, restarts needed services, and stores a local rollback archive.

Rollback:

```sh
podkopchikctl rollback
```

Podkopchik `0.1.0-beta` never auto-updates Xray core.

### Manual Xray Core Updates

The **Updates** page has an independent **Xray Core** section with installed
version, installed source, CPU architecture, last check time and operation
status. Select **OpenWrt package (opkg/apk)** or **Official Xray release**, then
**Check for updates**. Versions come from the router/selected source.
Updates run only when explicitly requested. Working routing and exactly one
main proxy must be configured before a core update can pass verification.
LuCI starts a background job and polls its status, so a long download does not
depend on one HTTP request remaining open.

The package source refreshes the native manager's configured feeds and runs
`opkg upgrade xray-core` / `apk upgrade xray-core`, or installs that package
when absent. The package manager handles signatures and necessary dependencies.
The manager refuses package updates when opkg signature checking is disabled.
No general OpenWrt package upgrade is performed. Use correctly configured,
trusted feeds for the installed OpenWrt release.

The official source downloads a matching Linux release from `XTLS/Xray-core`
on GitHub over HTTPS, verifies its SHA256 digest (or upstream `.dgst`), checks
its Linux ELF architecture and version, and tests the active config. Only the
`xray` archive member is extracted; bundled geoip/geosite databases are ignored.
Checksum verification trusts the publisher and is not an independent signature.
`unzip` is installed as a dependency. Linux arm64 and x86_64 are supported by
the update manager; other architectures are rejected.

The active selector and managed executable live in
`/usr/libexec/podkopchik-core/`, outside application payload replacement.
`/usr/bin/xray` remains owned by the native package manager. Init, validation, health and isolated
checks share the selector in `xray.sh`. The manager reserves free space for
staging, extraction and a copy of the previous binary. It serializes with
Apply and health and restarts only the Xray procd instance.

Verification requires one main process, transparent/FakeDNS listeners, unchanged
active config/nft/policy routing, and successful HTTPS egress through the main
proxy. Failed startup or verification restores the previous executable.
The primary can be reachable while a different outbound is currently selected
by failover; the updater deliberately checks the configured main connection.

```sh
podkopchikctl xray-status
podkopchikctl xray-check package
podkopchikctl xray-check official
# Run one of these only when ready for a short proxy interruption:
podkopchikctl xray-install official
# Or: podkopchikctl xray-install package
podkopchikctl xray-status
podkopchikctl validate-active
podkopchikctl status
```

Restore the previous runtime binary with `podkopchikctl xray-rollback` or the
**Restore previous Xray** button. This is a binary rollback, not a downgrade of
opkg/apk package metadata/dependencies. A failed package upgrade can therefore
leave a newer package installed while Podkopchik runs the protected old copy
(`source=rollback`). A subsequent successful package update can select package mode
again. If startup recovery needs manual intervention:

```sh
cp /usr/libexec/podkopchik-core/previous/xray /usr/libexec/podkopchik-core/xray.recovery
chmod 755 /usr/libexec/podkopchik-core/xray.recovery
mv /usr/libexec/podkopchik-core/xray.recovery /usr/libexec/podkopchik-core/xray
printf '%s\n' rollback > /usr/libexec/podkopchik-core/selected
/etc/init.d/podkopchik core_restart
podkopchikctl validate-active
podkopchikctl status
```

Normal exit and handled signals release locks and attempt rollback after a
switch. Power loss or SIGKILL cannot run shell traps: inspect running processes
before removing an orphan update lock, and use the retained previous binary
if needed. Managed core files survive normal uninstall/reinstall; `--purge`
removes them. Application rollback and core rollback are independent.

### Connection Checks

Proxy Links automatically checks pasted/changed VLESS URIs and checks them
before saving. **Check again** repeats the isolated check. A failed check is a
warning and does not prevent saving. The current connection type remains
VLESS/Reality until AWG 3.1 runtime compatibility is established.

Checks use a separate Xray SOCKS listener on root-owned, locked local port
20999. The checker verifies the process and listener owner before trusting
curl. One HTTPS request to `api.ipify.org` obtains an IPv4 exit address and
measures total request time, displayed as HTTPS check latency (not ICMP ping).
Temporary configuration/logs are root-only and removed on exit/interruption;
the URI is passed to the checker in the RPC environment, never process arguments
or diagnostic output. The primary/group selection and LAN rules are untouched.

Periodic health checks retain the existing thresholds and ordered failover;
they additionally record HTTPS request latency, external IP when available and
check time. An external-IP lookup failure does not turn a successful existing
reachability check into a failover. The Proxy Links page hides success/latency/IP
after five minutes and labels the result outdated. Immediate pre-save results
are held in the current page; periodic results appear from the health state.

### AWG 3.1 Configuration Management (Stage 1)

The separate **AmneziaWG** page imports multiple `.conf` files, lists safe
metadata, renames, replaces, revalidates and deletes profiles. The existing
Proxy Links/VLESS workflow is unchanged. This stage does **not** start tunnels,
check connectivity, assign routing targets or participate in failover.
"Configuration is valid" means static format validation, not a handshake.

Profiles are limited to 64 KiB each and stored in `/etc/podkopchik/awg/`:
root-owned directory `0700`, configuration and metadata files `0600`. Keys are
not stored in UCI, returned by RPC or shown in the list/edit form. The authenticated
rpcd API accepts file contents, never a caller-supplied filesystem path.
Use HTTPS for LuCI when importing keys; protect downloaded sysupgrade backups,
which include these private files through `/lib/upgrade/keep.d/podkopchik-awg`.

AX6000 stock / OpenWrt 25.12.6 / kernel 6.12.112 has passed the earlier AWG 3.1
module/tools and temporary-interface checks. This does not establish handshake
or HTTPS tunnel functionality. Older GL-MT6000/AX6000 kernels remain unverified;
this change does not install or update any AWG package.

See [format, tests, manual installation and rollback](docs/AWG-STAGE1.md).

## Uninstall

Preserve user configuration:

```sh
sh uninstall.sh
```

Remove configuration too:

```sh
sh uninstall.sh --purge
```

The uninstaller stops the service, removes only Podkopchik nftables rules, deletes installed files, restarts LuCI services, and is safe to run more than once.

## Recovery

Disable interception:

```sh
podkopchikctl cleanup
```

Restore the previous Xray config if needed:

```sh
cp /etc/podkopchik/config.json.prev /etc/podkopchik/config.json
/etc/init.d/podkopchik restart
```

Inspect state and logs:

```sh
podkopchikctl status
logread -e podkopchik
```

## Troubleshooting

- If **Apply** fails, run `podkopchikctl validate` and inspect the error.
- If reinstalling did not help, remember that `/etc/config/podkopchik` is intentionally preserved. Run `podkopchikctl generate` or `podkopchikctl apply`; stale rule targets are repaired to `auto_proxy_group` when the automatic proxy group is valid, or reported with the exact broken rule.
- If install fails while installing a dependency, check OpenWrt repositories, WAN/DNS, free `/overlay` space, and kernel kmod compatibility.
- If Apply reports `Missing required dependency: ip-full`, rerun the installer or install `ip-full`; BusyBox `ip` cannot add Podkopchik fwmark policy rules.
- If a phone or laptop inside LAN needs direct access to a 3x-ui panel, VPS, or proxy endpoint, add the host/IP/CIDR under **Exclusions**. Then verify that resolved IPs appear in `nft list table inet podkopchik` under `proxy_bypass4` or `proxy_bypass6`.
- If routing is inactive after reboot, check `uci get podkopchik.main.routing_enabled` and `podkopchikctl status`.
- If DNS redirect appears ineffective, check whether the client uses DoH, DoT, or Apple Private Relay.
- If health status is `unknown`, install/verify `xray-core`, `curl`, and `ca-bundle`, then run `podkopchikctl health`.
- If nftables rules need clearing, run `podkopchikctl cleanup`; it does not flush unrelated firewall rules.

## Test On An OpenWrt x86_64 VM

1. Download an OpenWrt 24.10 x86_64 image and boot it in your hypervisor.
2. Ensure the VM has WAN access and a LAN bridge or test client network.
3. Copy the repository to the VM:

```sh
scp -r ./Podkopchik root@192.168.1.1:/tmp/Podkopchik
```

4. Install and open LuCI:

```sh
ssh root@192.168.1.1
cd /tmp/Podkopchik
sh install.sh
/etc/init.d/podkopchik status
```

5. Add fake links first to confirm validation rejects unusable configuration, then add real test VLESS TCP/REALITY or XHTTP/REALITY links.
6. Add a test group and route a harmless domain or one LAN test client.
7. Click **Apply**, then verify:

```sh
podkopchikctl status
nft list table inet podkopchik
ip rule show
logread -e podkopchik
```

8. Run cleanup and verify the Podkopchik table is gone:

```sh
podkopchikctl cleanup
nft list table inet podkopchik
```
