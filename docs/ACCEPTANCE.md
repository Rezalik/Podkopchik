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
- LuCI JS views for Status, Proxy Links, Domain Groups, IP Rules, Exclusions, LAN Devices, DNS, Updates, Logs, Advanced

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
- Changing IP Rules in LuCI and pressing Save & Apply updates the active Xray routing by running the Podkopchik runtime apply path; manual SSH apply is not required.
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
