# Acceptance criteria for Podkopchik 0.1.0-beta

## Must exist

- Makefile
- README.md
- install.sh
- uninstall.sh
- root/etc/config/podkopchik
- root/etc/init.d/podkopchik
- root/usr/bin/podkopchikctl
- root/usr/libexec/podkopchik/generate.uc
- root/usr/libexec/podkopchik/parse_vless.uc
- root/usr/libexec/podkopchik/apply_rules.sh
- root/usr/libexec/podkopchik/cleanup_rules.sh
- root/usr/libexec/podkopchik/health_check.sh
- root/usr/share/luci/menu.d/luci-app-podkopchik.json
- root/usr/share/rpcd/acl.d/luci-app-podkopchik.json
- LuCI JS views for Status, Proxy Links, Presets, Domain Groups, IP Rules, Exclusions, LAN Devices, DNS, Updates, Logs, Advanced

## Functional requirements

- Add/edit/delete named VLESS links.
- Support VLESS TCP/REALITY.
- Support VLESS XHTTP/REALITY.
- Choose main/backup/disabled proxy roles in the simple Proxy Links UI.
- Maintain an internal automatic proxy group from proxy roles.
- Support strict_primary group mode.
- Support fixed_proxy group mode.
- Support manual override.
- Route domain groups to the automatic proxy group, a specific proxy, or direct.
- Route destination IP/CIDR to proxy groups.
- Add presets for Telegram, YouTube, Instagram, TikTok, X / Twitter, Discord, OpenAI / ChatGPT / Codex, and Canva.
- Presets create ordinary editable `domain_rule` and `ip_rule` sections; they must not introduce a separate routing system.
- Presets must skip duplicates by rule type, value, and target, and report added and skipped counts.
- LuCI Save & Apply on routing-affecting pages, including Proxy Links, Domain Groups, IP Rules, Exclusions, LAN Devices, DNS, and Advanced settings, and Add preset on Presets, updates the active runtime state through the Podkopchik apply/cleanup path when routing is active; manual SSH apply is not required.
- Add manual Exclusions for domain, IP, and CIDR destinations that must go direct without port matching.
- Manual Exclusions Save & Apply must run the Podkopchik runtime apply path; manual SSH apply is not required.
- Route source LAN IP devices to proxy groups/direct.
- Store LAN device speed limit settings and expose diagnostics without enabling real `tc`/`ifb` enforcement.
- Use dnsmasq as default DNS.
- Optionally redirect LAN UDP/TCP 53 DNS to router DNS.
- Enable Xray sniffing.
- Do not enable FakeDNS by default.
- Implement health checks.
- Implement failover to backups.
- Implement auto-return to primary.
- Generate Xray config.
- Validate config before applying.
- Manage only Podkopchik nftables rules.
- Provide LuCI update page with `main` development branch updates and `stable` GitHub Release updates.
- Preserve /etc/config/podkopchik on update/uninstall unless purge is explicitly requested.
- Service is enabled and started by install.sh, while TPROXY interception remains inactive until a valid proxy/rule set is applied.
- Health checks record real probe results when Xray plus curl probing is available; otherwise they report unknown with the reason and do not mark proxies up.
- Health-check cleanup removes stale temporary Xray processes using `/tmp/podkopchik/health-*.json` and never targets the main `/etc/podkopchik/config.json` Xray process.
- `podkopchikctl status` reports Xray as running only when the main process uses `/etc/podkopchik/config.json`; stale health probe processes must not be counted as the main service.
- If failover config apply cannot acquire the runtime apply path or fails validation/application, health state is not advanced to the new active proxy; the next health check can retry without drifting away from the active Xray config.

## Preset acceptance

- Telegram preset creates 8 domain entries and 7 IP CIDR entries.
- YouTube preset creates 15 domain entries and no IP entries.
- Instagram preset creates 14 domain entries and no IP entries.
- TikTok preset creates 14 domain entries and no IP entries.
- X / Twitter preset creates 19 domain entries and no IP entries.
- Discord preset creates 11 domain entries and no IP entries.
- OpenAI / ChatGPT / Codex preset creates 14 domain entries and no IP entries.
- Canva preset creates 10 domain entries and no IP entries.
- Re-applying the same preset to the same target adds no duplicates.
- Presets can target the automatic proxy group, an existing proxy group, a specific proxy outbound, or direct.
- OpenAI / ChatGPT / Codex, Canva, Discord, and CDN domain lists are editable starting points because service hostnames can change.

## FakeDNS MVP acceptance

FakeDNS is experimental and must remain disabled by default.

When explicitly enabled with:

```sh
uci set podkopchik.main.fakedns_enabled='1'
uci set podkopchik.main.fakedns_hijack_dns='1'
uci set podkopchik.main.fakedns_port='1053'
uci set podkopchik.main.fakedns_listen=''
uci set podkopchik.main.fakedns_pool_v4='198.18.0.0/15'
uci commit podkopchik
```

the router acceptance checklist is:

- `xray run -test -config /etc/podkopchik/config.generated.json` reports `Configuration OK`.
- nft table `inet podkopchik` contains `dns_prerouting`.
- Xray listens on port `1053`.
- active FakeDNS pool `198.18.0.0/15` is absent from nft `reserved4`.
- active FakeDNS pool `198.18.0.0/15` is absent from Xray private/reserved direct rule.
- a LAN client DNS query for `x.com` via router DNS returns `198.18.x.x` or `198.19.x.x`.
- X/Twitter app works on an iPhone LAN client.

The FakeDNS MVP must not add UDP TPROXY or UDP/443 blocking.

## Stability pass verified on GL-MT6000 / OpenWrt 24.10.4

This stability checkpoint was verified on a GL.iNet Flint 2 / GL-MT6000 router
running OpenWrt 24.10.4 after `podkopchikctl update-install` from GitHub
`main`.

The checkpoint covers:

- update-install from GitHub `main`
- `rpcd` and `uhttpd` restart after update
- `podkopchikctl validate`
- `podkopchikctl generate`
- `xray run -test -config /etc/podkopchik/config.generated.json`
- repeated `podkopchikctl apply` idempotency
- exactly one final main Xray process using `/etc/podkopchik/config.json`
- no stale `/tmp/podkopchik/health-*.json` Xray processes after health checks
- no stale health port locks after health checks
- nftables rule order with `reserved4/6` and `proxy_bypass4/6` before final TCP TPROXY
- FakeDNS with `dns_prerouting`, active pool in Xray FakeDNS, and active pool absent from Xray direct reserved rules and nft `reserved4`
- direct FakeDNS query to `127.0.0.1:1053` returning `198.18.x.x` or `198.19.x.x`
- Telegram IP rules in active Xray config for `91.108.*` and `149.154.160.0/20`
- Exclusions in UCI, nft `proxy_bypass4`, and Xray direct domain rules
- LuCI runtime apply path on the installed version

Expected safe warnings:

- `health check skipped; another health check is already running` can appear during race sanity checks; this means the health lock worked.
- An active health probe Xray may be visible during a mid-check process snapshot; it is not stale if it disappears after the check completes.
- `ucode -V` can report `unrecognized option: V` on OpenWrt; this is not a Podkopchik failure.

Repeat the stability check on a router with:

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
jsonfilter -q -i /etc/podkopchik/config.generated.json -e '@.routing.rules[*].ip[*]' | grep '198.18.0.0/15' && echo 'WARNING: FakeDNS pool direct-routed' || echo 'OK: FakeDNS pool not direct-routed'
nft list set inet podkopchik reserved4 | grep '198.18.0.0/15' && echo 'WARNING: FakeDNS pool in reserved4' || echo 'OK: FakeDNS pool not in reserved4'
nslookup -port=1053 x.com 127.0.0.1 || true
grep -oE '91\.108\.[0-9.]+/[0-9]+|149\.154\.[0-9.]+/[0-9]+' /etc/podkopchik/config.json | sort -u
uci show podkopchik | grep -iE 'bypass_rule|host|comment' || true
nft list set inet podkopchik proxy_bypass4 || true
```

## Required commands

These commands must exist:

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
