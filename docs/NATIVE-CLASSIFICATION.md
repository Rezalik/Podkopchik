# Native classification and migration

Historical classification checkpoint through `8c59dc7`. Its scope/release-gate
table below is not the current whole-LAN lifecycle; see
[Permanent Native Apply](UNIVERSAL-PERMANENT-APPLY.md) for that implementation.

This changes the existing native planner and DNS classifier, not the installed
legacy Xray path. It does not authorize a household rollout. The Xiaomi is not
contacted by these tests.

## Policy contract

| Policy | Unknown forwarded traffic | Direct authorization |
| --- | --- | --- |
| Strict | Available protected transport by default; otherwise denied, IPv4 and IPv6 | Confirmed whole-IP/CIDR, infrastructure endpoint or whole-client exception |
| Compatible | May use the normal direct route | Explicit rules still take precedence; there is no strict domain fail-closed guarantee |
| Either mode with migration restriction | Protected fallback or explicit block policy, never implicit WAN | Same scope as Strict, not a DNS-derived real-IP allowlist |

New UCI defaults are `native_classification_mode=strict`, `native_unknown_action=protected`,
`native_migration_restrict_unknown=1` and `native_direct_grants_confirmed=0`.
The planner also defaults an omitted classification mode to Strict; an older
unrestricted fixture must now request Compatible explicitly.
They are native settings only. Saving them does not change the working legacy
runtime. LuCI Advanced identifies that scope and displays the Compatible
warning and Strict domain-only-direct limitation.

Direct exceptions are privileged administrator policy, not proof of a domain.
An approved address grants that address for all names and protocols; an approved
client grants that source. Therefore a protected name sharing a directly approved
IP is also subject to the explicit exception. Approval is required before a
restricted native plan can contain such exceptions. No DNS response or cached
association automatically grants direct WAN access.
LAN-device scopes match their configured source IP/CIDR, not a MAC identity;
an unlisted IPv6 address still follows its own policy. During migration an
already-established unmarked flow may need to reconnect before it can obtain
its explicit direct pin. This is a fail-closed interruption, not a WAN fallback.
An explicit direct exception can also carry DoH or another opaque tunnel;
it is not a per-application filter within its approved scope.

Before approval, `podkopchikctl native-direct-grants INVENTORY.json` lists the
canonical destination/client scopes read-only. It works with confirmation off
and emits a review-only object with no nft batch, DNS policy or credentials;
it cannot be passed to the activation controller. Restricted activation still
refuses unconfirmed exceptions. The normal candidate carries the same grant
list for the later full Native Apply transaction.

Order remains: reject retired/unknown synthetic destinations, classify live
synthetic policies and client overrides, preserve router-local delivery, apply
infrastructure bypass, apply explicit client policy, apply IP/CIDR rules in UCI
order, and finally handle unknown traffic according to the mode. A source Direct
rule does not forward an undecoded synthetic destination to WAN. The DNS layer
returns real answers to that explicitly approved device instead. This decision
is made after the shared upstream cache lookup, so the next protected client
still receives its own committed synthetic mapping.

Strict direct flows use a dedicated skb mark and a reserved conntrack pin.
Unknown flows use an available Main/Backup transport with support for the
address family and protocol. TCP-only VLESS is never selected for unknown UDP;
an available native backup can carry it instead. Known synthetic/domain/IP
policies are not relaxed by that fallback. The alternative `block` setting
denies unknown traffic. When no suitable configured automatic-group transport
is available, unknown traffic is denied before firewall4's established allow;
router INPUT, DNS, DHCP and management remain available. An established
unmarked connection from before migration cannot bypass the new deny.
Local, broadcast and multicast FIB destinations return before client/fallback
marking, so DHCP and IPv6 neighbour discovery are not routed into a tunnel.
This does not grant external forwarding: the separate Strict FORWARD gate
still rejects unmarked traffic. The full VM fixture checks DHCP/ACK without
changing its static client address and refreshes IPv6 neighbour discovery.
Unsupported family/transport and all-down paths never become implicit direct.
The existing two native tables cross-check forwarding: loss of the classifier
still leaves an independent unmarked-flow deny, and loss of the DNS gate still
leaves the classifier's WAN and plain-DNS denies. Fault tests remove each table
separately. Direct availability may temporarily fail closed during that fault;
it is not replaced with an unverified WAN fallback.
Changing classification or approval is a full-transaction change, not a
health-only transport switch. Validation errors do not downgrade the mode.

## Why SNI and Host Are Not Direct Grants

TCP SYN precedes HTTP Host and TLS ClientHello. Classifying on that later data
would require a local stream gateway or reliable buffering/reassembly, not just
a destination-IP nft rule. A clear HTTP request can be distinguished at that
gateway, but doing so once does not enforce every later request on a reused
connection. No such gateway is added here.

Ordinary TLS 1.3 can expose ClientHello SNI, but ECH encrypts ClientHello
([RFC 9849](https://www.rfc-editor.org/rfc/rfc9849.html)). HTTP/2 permits
multi-origin connection reuse ([RFC 9113, section 9.1.1](https://www.rfc-editor.org/rfc/rfc9113.html#section-9.1.1));
HTTP/3 has the corresponding rule
([RFC 9114, section 3.3](https://www.rfc-editor.org/rfc/rfc9114.html#section-3.3)).
Thus even a visible initial SNI is not authentication of every later origin.
QUIC Initial inspection alone is not an ECH or application-origin enforcement
solution. DoH carries DNS over HTTPS
([RFC 8484](https://www.rfc-editor.org/rfc/rfc8484.html)); redirecting port 53
cannot transparently classify arbitrary DoH connections. Strict sends their
unknown destinations through a suitable protected transport, or denies them
under the block policy or when no suitable transport is available. Explicit
privileged direct exceptions still apply. Literal addresses need an explicit
IP/client policy or remain unknown.

## Shared CDN Acceptance

The original `PKC_VM_CHECK_MIGRATION=1` regression is retained as the stricter
per-domain distinction test. Compatible still exhibits the documented
real-address fallback; that is a known tradeoff, not a passing security test.
Strict sends both unclassified names on the shared cached real IP through the
protected fallback, or denies both under the optional block policy.
**This is not domain identification and does not make the original per-domain
Direct distinction PASS.**

The accepted strict contract protects cached real-address connections through
the automatic transport group and uses deliberately approved address/client
scopes for direct. Fresh transactional DNS retains its precise mapped policy.
Those approvals must not be described as enforcing different domains on the
same directly permitted destination. If strict separation of such origins is
required on one client, use an explicitly configured application gateway with
an enforceable origin policy, or keep the entire ambiguous scope on a protected
transport. The current native kernel path does not implement that gateway.

## Tests and Native Apply Preparation

On the workstation, run `tests/native_classification_smoke.sh`,
`node tests/native_classification_ui_smoke.js`, the Go race suite, gettext/i18n
checks and the existing smoke suites. `tools/prepare-native-dns-vm.sh` assembles
the signed offline VM dependencies and current ARM64 test binaries.

Inside the NIC-free guest run `sh /mnt/lab/native-classification-vm-test.sh`.
It exercises both modes with migration restriction on and off, real kernel
fwmarks/conntrack, explicit direct, DNS UDP/TCP, client-aware DNS, both address
families, native transport stand-ins, backup/all-down and a WAN capture with
positive direct controls. The full `setup-native-dns-guest.sh` suite additionally
tests real Xray/VLESS, UDP round trips, QUIC, TTL, procd, fw4 reload and rollback.
Run `PKC_VM_CLASSIFICATION=strict sh /mnt/lab/native-dns-vm-test.sh` for the
restricted full fixture, including certificate-verified TLS 1.3 over native
and VLESS paths, and unknown QUIC over the protocol-capable native backup.

For an actual EFI reboot, use a fresh disk from
`tools/run-native-reboot-vm.sh`, create a private `/etc/pkc-native-vm-state`
directory and its `classification-only` marker in that disposable guest, then
run `install-native-vm-boot.sh`. procd repeats the matrix after reboot and checks
that the previous boot's verified but unconfirmed journal cannot be confirmed.
This tests the classification contract and lab lifecycle, not recovery of an
installed whole-household Native Apply.

The compiler now carries mode, migration state, consent and ordered client DNS
policy in the candidate, so activation cannot silently infer them from an IP
cache or change them in a health-only switch. Full household Apply/confirm,
persistent allocation across changed domain layouts, confirmed native boot
and complete legacy restoration still require qualification. No production
activation path is claimed by this patch, and the review archive remains
unsuitable for installation over the running router.
The existing scoped activation controller rejects a mismatch between compiled
classification and DNS policy before arming or mutating nftables; its deadline
and automatic restoration are also exercised with Strict classification.
The full-LAN VM rollback now compiles `legacy_restore()` alongside the verified
old firewall in one nft transaction. It removes native routing, DNS interception
and unknown-flow restrictions, while rebuilding both pool guards and retaining
tunnel-source protection. The restored native LAN can deliver the old FakeDNS
pool locally to its legacy Xray; that does not authorize forwarding fake IPs
to WAN. Old native-pinned connections need to reconnect. DNS-only release is
not sufficient for a Strict-to-legacy rollback.
The independent procd watchdog refuses an invalid restore transaction and keeps
the native protection until a valid old firewall and resolver are available.

## Laboratory Execution Boundary

The UTM 4.7.5 environment uses QEMU 10.0.2 TCG. Direct execution of the temporary
Go probe from its read-only 9p share produced two startup crashes in 100
argument-validation runs, outside the DNS-classification path. A byte-identical
copy in guest tmpfs had zero crashes in 200 runs. An independent 100-run shared
probe with `GODEBUG=madvdontneed=0` also had zero failures, but that is not enough
to attribute this particular fault or justify a production runtime change.

`native-vm-binaries.sh` now verifies SHA256 and stages immutable copies of the
four test executables in private guest tmpfs before network mutation. It never
overwrites a running executable. The application build and router environment
are unchanged; no GODEBUG workaround is shipped. Related upstream emulation
reports exist ([Go issue 77572](https://github.com/golang/go/issues/77572)), but
they are not proof of the cause in this full-system guest. The old crashing
runs are failed lab runs, not silently counted as acceptance passes. Repeat
physical startup and long-load acceptance remain separate release gates.

## Verification Record, 2026-11-07

No connection was made to Xiaomi or `openwrt2` for this change. Network results
below are from a NIC-free OpenWrt 25.12.6 / Linux 6.12.112 guest. Native tunnel
interfaces are Ethernet stand-ins; the VLESS peer uses the real pinned Xray
26.3.27 binary with a synthetic test profile, not a household credential.

| Check | Result and evidence |
| --- | --- |
| Strict, Compatible and migration | PASS: both modes with migration on/off, plus explicit unknown block. IPv4/IPv6 shared cached addresses stay protected or denied in restricted modes. |
| Explicit direct | PASS: literal-address controls and a whole-client exception on the same shared CDN. Source-specific DNS bypass does not contaminate another client's cached answer. This does not authenticate application domains. |
| Protocol-aware fallback | PASS: unknown HTTPS uses the selected real VLESS peer; unknown UDP and QUIC use the native-capable backup. Known DNS-mapped VLESS UDP remains denied. |
| DNS, TTL and faults | PASS: UDP/TCP, aliases/cache, concurrent queries and selection changes, real rejected nft transaction, missing sets/tables, classifier stop/restart/SIGKILL, expired leases and existing conntrack. No raw-answer fallback on classification failure. |
| LAN control plane | PASS: DHCP has a successful pre-activation control, then obtains an ACK under Strict without changing the static test address; refreshed IPv6 neighbour discovery and local router access work. |
| Virtual WAN | PASS: final Strict capture reports protected=0, plaintext_dns=0, direct=64, endpoint=91; selected primary/backup captures contain 151/26 packets. Captures have zero kernel drops. These are not physical-WAN results. |
| Legacy restore | PASS: invalid recovery batch leaves protection intact; valid independent procd recovery restores DNS and local old-FakeDNS delivery on the former native LAN. Post-restore capture has synthetic=0 and direct=8. Recovery fixture files total 14,570 bytes, not a Xiaomi flash budget. |
| Reboot | PASS for the procd/journal fixture: actual autonomous EFI reboot, matrix rerun and rejection of the prior unconfirmed journal. This is not confirmed household-native boot recovery. |
| Scoped activation | PASS: mode/DNS mismatch rejected before arming, actual UCI mapping/review, timeout and watchdog fault recovery; claim/quarantine retained and legacy nft left intact. |
| Workstation checks | PASS: shell/LuCI syntax, 18 JS smoke suites, 41 shell suites with documented platform skips, uncached Go race tests and vet, tracked JSON, gettext check, i18n/real-LMO coverage and diff whitespace. Native UCI coverage and real Xray config syntax also run in the guest. |
| Original per-domain raw-IP distinction | NOT CLAIMED: two opaque connections to the same cached IP are not identified by domain. The accepted policy uses protected fallback and explicit privileged scopes. |
| Physical profiles, hardware offload, prolonged load | SKIPPED: no router contact, no physical AWG/Reality credentials, no hardware PPE environment or multi-hour native acceptance. Offload remains a preflight refusal, not a supported mode. |
| Whole-household Native Apply | FAIL as a release gate: permanent Apply/confirm, native boot, health-to-runtime wiring, allocator continuity across policy changes and complete installed legacy recovery are not finished. The guarded scoped controller is not a replacement for them. |

The initial shared-executable startup failures remain recorded above. One
unchanged workstation connection-check mock also failed in an earlier aggregate
run; its isolated rerun and the final 41-suite run passed. Neither failed run is
counted as a successful run, and no health-check runtime change was made.

The ARM64 review archive is built twice and checked byte-for-byte, with verified
per-file SHA256, regular flat paths and root UID/GID. It is not an installer or
a production-ready household release. Do not deploy it over the working Xiaomi
or replace `podkopchikctl apply` until the remaining lifecycle gates are closed.
