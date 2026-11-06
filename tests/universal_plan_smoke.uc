'use strict';
const native = require('universal_plan');
const awg = require('awg_network');
const a = '11111111111111111111111111111111', b = '22222222222222222222222222222222';
const ra = awg.resources(a), rb = awg.resources(b);
function ok(value, label) { if (!value) die(label + '\n'); }
function rejects(fn, label) { let failed = false; try { fn(); } catch (e) { failed = true; } ok(failed, label); }
function fixture(active) {
	return { lan: 'br-lan', automatic: active,
		adapters: [{ id: a, type: 'amneziawg', usable: active == ra.tag, ipv4: true, ipv6: false },
			{ id: b, type: 'amneziawg', usable: active != 'blocked', ipv4: true, ipv6: true }],
		fake_pools: ['198.18.0.0/15', '2001:2::/48'], bypass: ['192.0.2.2'],
		clients: [{ cidr: '10.19.0.3', target: 'direct' }, { cidr: '10.19.0.4', target: rb.tag }],
		domains: [{ names: ['known.pkc.invalid'], target: 'auto_proxy_group' }],
		ips: [{ cidr: '203.0.113.81', target: 'auto_proxy_group' }, { cidr: '2001:db8:9::80', target: 'auto_proxy_group' }] };
}
const up = native.compile(fixture(ra.tag)), fallback = native.compile(fixture(rb.tag)), down = native.compile(fixture('blocked'));
const initial = native.batch(up), failover = native.switch_batch(up, fallback), failed = native.switch_batch(fallback, down);
const r = 'add rule inet podkopchik_native classify iifname "br-lan" ';
ok(index(initial, r + 'ip daddr @fake4') < index(initial, r + 'ip daddr @bypass4'), 'fake takes precedence over direct');
ok(index(initial, r + 'ip saddr 10.19.0.4/32') < index(initial, r + 'ip daddr @domain_0_4'), 'client policy precedes domain');
ok(index(initial, r + 'ip daddr @domain_0_4 meta mark set ' + ra.mark) >= 0, 'main uses kernel AWG mark');
ok(index(initial, r + 'ip6 daddr @domain_0_6 counter drop') >= 0, 'unsupported IPv6 blocked');
ok(index(failover, r + 'ip daddr @domain_0_4 meta mark set ' + rb.mark) >= 0, 'fallback uses backup mark');
ok(index(failover, 'add set') < 0 && index(failover, 'delete table') < 0, 'failover keeps DNS sets');
ok(index(failed, r + 'ip daddr @domain_0_4 counter drop') >= 0, 'all-down blocks protected domain');
ok(index(initial, 'oifname != "' + ra.interface + '" counter drop') >= 0, 'lost policy cannot escape via WAN');
ok(index(initial, 'tproxy') < 0 && index(initial, 'xray') < 0, 'native path has no Xray');
let bad = fixture(ra.tag); bad.bypass = ['198.19.2.3'];
rejects(() => native.compile(bad), 'reject bypass conflict with fake pool');
bad = fixture(ra.tag); bad.adapters[0].type = 'vless';
rejects(() => native.compile(bad), 'do not fake native VLESS support');
bad = fixture(ra.tag); bad.domains[0].names = ['other.pkc.invalid'];
rejects(() => native.switch_batch(up, native.compile(bad)), 'do not reuse DNS leases for changed names');
bad = fixture(ra.tag);
bad.synthetic = { epoch: '0011223344556677', pools: ['198.18.0.0/16'], inventory: {
	addresses: [{ addr_info: [{ local: '10.19.0.1', prefixlen: 24 }] }], routes: [{ dst: '192.0.2.0/24' }], issued: [] } };
rejects(() => native.compile(bad), 'legacy FakeDNS /15 overlaps native /16');
bad.synthetic.pools = ['100.127.253.0/24'];
ok(length(native.compile(bad).fake) == 2, 'disjoint lab pool accepted');
bad.synthetic.inventory.routes = [{ dst: '100.64.0.0/10' }];
rejects(() => native.compile(bad), 'carrier or VPN route overlaps native pool');
bad.synthetic.inventory.routes = [{ dst: '192.0.2.0/24' }];
bad.synthetic.inventory.issued = ['100.127.253.128/25'];
rejects(() => native.compile(bad), 'previous generation cannot be reused');
bad.synthetic.inventory.issued = ['100.127.252.0/24'];
ok(index(native.compile(bad).fake, '100.127.252.0/24') >= 0, 'retired pool automatically guarded');
bad.synthetic.inventory.addresses = [{ addr_info: [{ local: '100.127.253.1', prefixlen: 32 }] }];
rejects(() => native.compile(bad), 'address overlapping pool rejected');
bad = fixture(ra.tag); bad.legacy_lans = ['br-lan'];
rejects(() => native.compile(bad), 'legacy TPROXY cannot share the canary LAN');
if (ARGV[0] == 'initial') print(initial);
else if (ARGV[0] == 'failover') print(failover);
else if (ARGV[0] == 'down') print(failed);
else print('Native AWG planner PASS: precedence, failover, set retention, fail-closed, adapter validation\n');
