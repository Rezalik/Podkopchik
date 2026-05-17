# Podkopchik

Podkopchik is an OpenWrt 24.10+ LuCI application for routing selected LAN traffic through Xray VLESS proxy links.

Package: `luci-app-podkopchik`  
Service: `podkopchik`  
UCI config: `/etc/config/podkopchik`  
Generated Xray config: `/etc/podkopchik/config.json`  
Runtime state: `/tmp/podkopchik/state.json`

## What v1.0 Includes

- LuCI JavaScript pages for status, proxy links, groups, rules, DNS, updates, logs, and advanced settings.
- UCI-backed VLESS TCP/REALITY and VLESS XHTTP/REALITY proxy definitions.
- Strict-primary and fixed-proxy groups with manual override, backup selection, and auto-return.
- Domain, destination CIDR, and LAN source IP routing rules.
- Xray transparent inbound with sniffing enabled and FakeDNS disabled.
- dnsmasq-based DNS with optional LAN UDP/TCP 53 redirect.
- Podkopchik-owned nftables/firewall4 table and cleanup.
- Config validation before apply, preserving the previous working Xray config on failure.
- GitHub Releases update checks and verified update installation.

v1.0 does not include subscription URLs, geoip/geosite databases, traffic statistics, QR import/export, FakeDNS by default, Xray core auto-updates, Docker, or router-side Python/Node.js runtimes.

## Install On OpenWrt 24.10

SSH into the router as root, copy this repository to the router, then run:

```sh
cd /tmp/Podkopchik
sh install.sh
```

From GitHub, the same flow is:

```sh
cd /tmp
curl -fL https://github.com/rezalik/Podkopchik/archive/refs/heads/main.tar.gz -o podkopchik.tar.gz
tar -xzf podkopchik.tar.gz
cd Podkopchik-main
sh install.sh
```

The installer uses `opkg`, installs required packages where possible, preserves an existing `/etc/config/podkopchik`, enables and starts the `podkopchik` service, restarts `rpcd` and `uhttpd`, and does not reboot.

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

1. Add one or more proxy links under **Proxy Links**. Use safe tags such as `proxy_main` and `proxy_backup`.
2. Create a proxy group under **Proxy Groups**:
   - `strict_primary` uses the primary while healthy, then moves to the first healthy backup after thresholded failures.
   - `fixed_proxy` stays on the selected proxy unless `failure_action` is `switch_to_backup`.
3. Add routing rules:
   - **Domain Rules** for domains such as `chatgpt.com`.
   - **IP Rules** for CIDRs such as `8.8.8.8/32`.
   - **LAN Devices** for source IP behavior: `full_proxy`, `rules_only`, or `direct`.
4. Optional: enable LAN DNS redirect on the **DNS** page.
5. Click **Apply** on the **Status** page.

Podkopchik validates the generated Xray config before replacing `/etc/podkopchik/config.json`. If validation fails, the previous working config remains in place.

## CLI

```sh
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
```

`cleanup` disables routing interception and removes only the Podkopchik-owned nftables table and matching policy routing entries.

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

Updates are pulled from the configured GitHub Releases repository. `update-install` requires a matching `.tar.gz` release asset and a `.sha256` asset. It verifies the archive, preserves `/etc/config/podkopchik`, restarts needed services, and stores a local rollback archive.

Rollback:

```sh
podkopchikctl rollback
```

Podkopchik v1.0 never auto-updates Xray core.

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
