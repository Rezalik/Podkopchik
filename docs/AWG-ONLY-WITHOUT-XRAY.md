# AWG-Only Without Xray: Architecture Assessment

Date: 2026-11-05, Europe/Moscow. Analysis only. No classifier, DNS replacement,
NAT, firewall, failover or routing change was implemented for this proposal.

## Current AWG-Only Is Not Coreless

The live AX6000 has three AmneziaWG profiles and no VLESS profiles. Nevertheless,
the main Xray is the transparent data/DNS engine:

- `transparent` dokodemo-door on12345 accepts TCP/UDP and sniffs HTTP/TLS/QUIC
  plus FakeDNS metadata.
- `dns-in` on1053 feeds `dns-out`; FakeDNS owns domain-to-fake-IP mappings.
- Xray evaluates the domain/IP/device rules and chooses direct, blocked or an
  marked/interface-bound `freedom` outbound to an owned kernel AWG interface.
- Current AWG interfaces already have isolated policy tables and terminal
  unreachable routes. Global default routing is unchanged.

Deleting VLESS profiles does not remove those responsibilities. Simply stopping
Xray, or routing198.18.0.0/15 into AWG, is not a working coreless mode. The target
domain must be recovered from the fake IP before real traffic can reach it.
See [Xray FakeDNS](https://xtls.github.io/en/config/fakedns.html).

## Feasible Native Data Path

Proposed direction, not implemented:

1. Classify original LAN packets in owned nft prerouting state, before routing.
2. Preserve explicit direct exclusions and proxy endpoint bypass.
3. For protected packets, select a per-profile policy mark/table. Forward them
   through the owned kernel AWG interface rather than a local Xray socket.
4. Keep direct/unmatched traffic on normal routing, with deterministic rule
   precedence and no global default-route replacement.
5. Add narrowly scoped AWG egress SNAT/masquerade when the server only accepts
   the assigned tunnel address. Existing Xray originates from that address;
   native forwarded LAN packets otherwise retain192.168.x.x as their source.
6. Integrate the owned AWG forwarding path with firewall4. A separate early
   accept cannot be assumed to override a later firewall4 drop.

SNAT/DNAT require correct connection tracking and reply translation, not just
packet marks. See [nftables NAT](https://wiki.nftables.org/wiki-nftables/index.php/Performing_Network_Address_Translation_(NAT)).
Existing policy marks cannot be repurposed without ownership and loop checks.

## Domain Classification Choices

### Real DNS Answers And nft Sets

A DNS-aware controller could place resolved addresses for each domain group in
owned IPv4/IPv6 sets, then select AWG/direct by destination IP. dnsmasq supports
`--nftset` in capable builds; see its [manual](https://thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html).
The installed AX6000 dnsmasq2.93 explicitly reports **no-nftset**. This is not
available by simply adding a UCI option; any package/build change needs a
separate compatibility review and permission. No dnsmasq was replaced here.

Limitations: domains sharing a CDN IP may require conflicting targets; DoH,
cached answers, CNAMEs, TTL expiry and DNS responses outside the controlled
resolver complicate coverage. An IP-set design is not equivalent to the current
per-domain FakeDNS semantics or opportunistic TLS/QUIC sniffing.

### Preserve FakeDNS Semantics

To retain distinct fake addresses without Xray, a separate lightweight,
well-tested DNS/mapping component is required. It must coordinate:

- domain, fake IP, real DNS answers and selected group/target;
- owned kernel fake-to-real DNAT and the reverse translation for replies;
- marks selected before policy routing, address reuse, TTLs and live conntrack;
- real resolver reachability, local/DHCP names and no DNS/FakeDNS loops;
- restart recovery, bounded memory, mapping exhaustion and atomic publication.

This is new data-plane/control-plane work, not a small dnsmasq rule. Replacing
only FakeDNS answers while keeping no reverse mapping would break connections.
IPv6 requires separate validation; it must not be silently enabled.

## Failover And Fail-Closed

The existing real AWG handshake/HTTPS checks and role model can be retained in
principle, but their runtime apply target must become a transactional kernel
controller instead of generated Xray outbounds/restarts.

Use fresh measured health, existing thresholds/ordered backups and an explicit
all-down blocked target. Preserve per-flow selection with connection tracking
where appropriate. Changing tunnels/public exit addresses cannot be promised
to migrate existing TCP sessions seamlessly. Policy lookup must terminate in
unreachable/drop on failure, never fall through to WAN for protected traffic.

Required gates include source NAT, firewall4 forwarding, endpoint bypass,
simultaneous domain targets, DNS/cache transitions, all-down capture, repeated
apply, restart/reboot and ownership-safe cleanup/rollback.

## Smaller Prefilter Before Xray

A hybrid mode is a more incremental research phase: keep Xray for DNS/FakeDNS
and packets that need its rule/sniffing/mapping semantics; bypass only packets
proved direct by an equivalent classifier.

Do not blindly return all real-IP UDP packets or all unlisted addresses before
TPROXY: explicit IP/device rules, QUIC on real IPs, DoH clients and sniffed domain
targets can otherwise change behavior. Fake-IP traffic still needs translation,
including domains whose final target is direct. No generic UDP bypass or port
block was added by the FD hotfix.

The objective is to reduce unnecessary Xray sockets, not claim fewer provider
connections. Direct packets bypassing Xray still create normal WAN NAT flows;
reducing those requires an explicit source/session policy. Kernel routing also
keeps connection state: coreless is not stateless networking.

## Recommendation

Following the reproducible PacketWriter test on AX6000, the current repair
selects option A: bound and expire only transparent reply sockets in Xray,
preserving full-cone and FakeDNS. See
[the comparison, isolated results and remaining gates](XRAY-UDP-CACHE-FIX-20261105.md).
No coreless mode is implemented or advertised. The installed dnsmasq still
reports no-nftset; shared real CDN addresses cannot encode conflicting domain
targets without an additional mapping/classification design. Its replacement
must not be smuggled into a socket-lifecycle fix.

Keep the working Xray-backed AWG data plane for now. First measure socket
lifetime/retention and specify prefilter equivalence tests. Then prototype a
native classifier in an isolated VM/network with explicit DNS capability gates.
Preserving exact FakeDNS, domain routing, failover and fail-closed without Xray
is technically feasible but requires a dedicated implementation phase, not a
toggle or a dependency removal. No implementation is included in this task.
