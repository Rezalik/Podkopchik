# AX6000 virtual canary review

This replaces the wired canary *proposal* only. It is not part of the
Podkopchik install/update workflow. Do not run the new engine or stage a
watchdog on the physical router without separate approval. No physical port
is a resource of this trial.

## Hardware preparation

- Xiaomi Redmi AX6000 stock, OpenWrt 25.12.6 `mediatek/filogic`,
  `aarch64_cortex-a53`; installed kernel package
  `6.12.112~f0a7348f9cb959e1bf4d0447669b031e-r1`.
- `kmod-veth` 6.12.112-r1 was selected **by package name** from a private
  temporary copy of the official signed ABI repository. `apk verify` accepted
  `packages.adb` with the device's stock key. The repository and APK bytes
  matched the checked SHA256 values; a second offline simulation and the real
  transaction both selected only `kmod-veth`. No trust overrides, dependency
  overrides or persistent repository changes were used. OpenWrt's repository
  signature authenticates package identity; a standalone unsigned APK was
  not installed.
- APK SHA256:
  `840efffc07d53a038662cfcfbe47bce215bdf3186bb31cc1d547949a5a1b6f1c`.
- Installed `veth.ko` reported `6.12.112 SMP mod_unload aarch64`. One
  unaddressed veth pair was created with one endpoint in a separate network
  namespace. The pair and namespace were immediately deleted. The module
  stays installed for a later authorized pilot. Do not remove it while a
  namespace or interface is using it.
- Before/after package inventory, configuration hashes, both IP route/policy
  sets, nft rules, interface set, Xray/dnsmasq/uhttpd PIDs and the three AWG
  links were compared. The only package delta was `kmod-veth`. Stock DNS and
  direct WAN HTTPS worked; interface-bound HTTPS returned 200 via all three
  existing AWG interfaces after installation. Both Wi-Fi APs, WAN and lan2
  retained carrier; SSH and the LuCI login form remained reachable.

## Separate recovery contract

`ax6000-virtual-watch.sh` and `virtual-trial-cleanup.uc` share the existing
`trial-state.uc` journal. Stage only in a root-owned mode-0700 directory
`/tmp/pkc-vpilot.<16-hex-epoch>`; do not add a persistent init service.
The host veth name is `pv` plus the first twelve hex digits. It must be a veth
with alias `pkc-virtual-<epoch>`; its peer belongs to the named network
namespace `pkcv-<epoch>`. Record the kernel namespace identity from
`ip netns exec "$namespace" readlink /proc/self/ns/net` in `namespace.id`
while the pair is still down. Refuse pre-existing names. The DNS and client
procd services carry the epoch in their names and the private directory as a
separate command argument. All scripts and runtime input must be verified
before registration.

1. With the virtual host veth down and before adding any packet rules or IP
   addresses, arm the monotonic journal with `ucode trial-state.uc arm DIR 600`.
   Start the independent watcher with `sh ax6000-virtual-watch.sh start DIR`.
   Verify its PID and journal through ubus and the independent management path.
   A first timed rehearsal may keep the pair unaddressed with no live rules.
2. On rollback the worker first brings down only its identified veth. It stops
   only its scoped services, checks the namespace identity and refuses to kill
   unknown processes. It atomically deletes only epoch-owned tables and scoped
   firewall4 handles, then deletes the pair and namespace. The worker writes a
   compact result and unregisters itself. It can retry after a foreign resource
   is removed; a failed check is not a successful rollback. It never flushes
   shared chains, touches a physical port, restarts a daemon or restores UCI
   wholesale. No `ip rule` creation/removal is supported by this kit.
3. On a later authorized pilot, keep the activation owner short-lived. It must
   stop on any error or deadline and explicitly abort on an activation failure.
   Do not call `confirm`. Leave no test client outside the disposable namespace,
   and do not make test DNS accessible to household clients. After rollback,
   verify resources really disappeared, household hashes/routes/PIDs stayed
   unchanged and DNS, SSH and LuCI still respond. Only then remove the private
   `/tmp` trial directory. There is no reboot step.

## Gates before enabling traffic on Xiaomi

The initial test design uses an IPv4 client at `172.31.252.2/30`, an isolated
gateway at `.1`, and the explicit `172.31.253.0/24` synthetic pool. Recheck
the complete current inventory and confirm the Mac and `media` on lan2 can
independently authenticate to SSH and reach LuCI. Do not add routes or addresses
on any physical link. Verify rollback on Xiaomi first with no traffic and with
the activation owner detached. Do not send a packet into the new engine until
that rehearsal passes.

Do **not** apply the wired or VM fixture nft batch in the Xiaomi root namespace.
The normal engine gate has shared AWG-source and legacy FakeDNS guards; applying
those unscoped could change household traffic. The remaining data-plane gate
is either a verified interface/source-scoped batch for the shared AWG, including
containment after conntrack expires, or a fully separate test-router namespace
with its own test AWG identity. A dedicated tunnel must never reuse an active
AWG peer identity. The second option needs a distinct test profile and a
separate reviewed integration; it is not enabled by this kit. Do not add
global exceptions or switch the household to work around this gate.

Required physical acceptance after separate authorization: DNS UDP/TCP,
protected domain and IP policy, TCP/UDP/QUIC through native AWG without any
new Xray process, direct positive control, unavailable-transport fail-closed,
old/unknown synthetic destination drops, actual expiry rollback without SSH,
and preservation of household traffic throughout. WAN capture requires a
trusted capture tool; if unavailable, physical leak verification is SKIPPED.
VM transport stand-ins do not prove real AWG traffic.

## VM regression

`tools/ax6000-virtual-watch-vm-test.sh` runs in the NIC-free OpenWrt guest with
real nftables, netns/veth and procd. The timeout scenario kills the activation
owner and checks the watchdog removes the veth, named namespace, owned tables,
tagged handles and test services without management input. The fault scenario
injects a deliberately mis-scoped tag, checks the owned interface is down and
the foreign rule was not deleted, kills the worker and checks procd respawns it.
After removing the injected test fault, the worker must finish and exit.
Both compare baseline household rules, policy rules, routes and the PID of a
stand-in home service. The existing native data-plane VM suite is separate.
