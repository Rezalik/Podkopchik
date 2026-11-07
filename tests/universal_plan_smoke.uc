'use strict';
const native = require('universal_plan');
const pool = require('native_pool');
const awg = require('awg_network');
const a = '11111111111111111111111111111111', b = '22222222222222222222222222222222';
const ra = awg.resources(a), rb = awg.resources(b);
function ok(value, label) { if (!value) die(label + '\n'); }
function rejects(fn, label) { let failed = false; try { fn(); } catch (e) { failed = true; } ok(failed, label); }
function fixture(active) {
	return { lan: 'br-lan', automatic: active,
		classification: { mode: 'compatible' },
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
ok(index(initial, 'mss_fix iifname "br-lan" meta mark ' + ra.mark + ' oifname "' + ra.interface +
	'" tcp flags & (fin | syn | rst) == syn tcp option maxseg size set rt mtu') >= 0, 'AWG egress clamps TCP MSS without altering interface MTU');
ok(index(initial, 'mss_fix iifname "' + ra.interface + '" oifname "br-lan" ct mark & 0xff000000 ' + up.adapters[ra.tag].pin) >= 0,
	'AWG reply MSS correction requires the owned transport pin');
ok(index(failover, 'flush chain inet podkopchik_native mss_fix') >= 0, 'MSS correction participates in atomic transport updates');
ok(index(initial, 'tproxy') < 0 && index(initial, 'xray') < 0, 'native path has no Xray');
let bad = fixture(ra.tag); bad.bypass = ['198.19.2.3'];
rejects(() => native.compile(bad), 'reject bypass conflict with fake pool');
bad = fixture(ra.tag); bad.adapters[0].type = 'vless';
rejects(() => native.compile(bad), 'do not fake native VLESS support');
bad = fixture(ra.tag); bad.domains[0].names = ['other.pkc.invalid'];
rejects(() => native.switch_batch(up, native.compile(bad)), 'do not reuse DNS leases for changed names');
bad = fixture(ra.tag);
bad.adapters[0].source_ips = ['192.0.2.101'];
bad.adapters[1].source_ips = ['192.0.2.102', '2001:db8:1::2'];
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
let inventory = { addresses: [{ addr_info: [{ local: 'fd12::1', prefixlen: 64 }] }],
	routes: [{ dst: 'default', gateway: '100.127.250.1' }, { dst: '100.127.251.0/24' }],
	rules: [{ priority: 100, dst: '100.127.252.7' }], issued: ['198.18.0.0/15'],
	endpoints: ['100.127.253.7'], exclusions: ['100.127.254.0/24'] };
let candidates = ['198.18.0.0/16', '100.127.250.0/24', '100.127.251.0/24', '100.127.252.0/24',
	'100.127.253.0/24', '100.127.254.0/24', '100.127.255.0/28', '100.127.255.0/24', 'fd12::/112', 'fd13::/112'];
let choice = pool.select(candidates, inventory, { '4': 240, '6': 240 });
ok(choice['4'].cidr == '100.127.255.0/24' && choice['4'].capacity == 254 &&
	choice['6'].cidr == pool.prefix('fd13::/112'), 'deterministic choice checks old pool, gateways, routes, selectors, exclusions and capacity');
rejects(() => pool.select(['8.8.8.0/24'], inventory, { '4': 100 }), 'public IPv4 pool is not eligible');
rejects(() => pool.select(['fe80::/112'], inventory, { '6': 100 }), 'IPv6 link-local pool is not eligible');
rejects(() => pool.select(candidates, { ...inventory, rules: null }, { '4': 240 }), 'require complete rule snapshot');
rejects(() => pool.select(candidates, { ...inventory, routes: [{ dst: 'malformed' }] }, { '4': 240 }), 'invalid inventory must not be ignored');
rejects(() => pool.select(candidates, inventory, { '4': 255 }), 'no silent capacity downgrade');
let private_pool = '172.31.253.0/24';
rejects(() => pool.select([private_pool], inventory, { '4': 254 }), 'private pool requires explicit consent');
ok(pool.select([private_pool], inventory, { '4': 254 }, private_pool)['4'].capacity == 254,
	'opted-in /24 has 254 leases despite the default route');
rejects(() => pool.select([private_pool], { ...inventory, routes: [...inventory.routes, { dst: '172.31.0.0/16' }] },
	{ '4': 254 }, private_pool), 'reject larger remote private route');
rejects(() => pool.select([private_pool], inventory, { '4': 255 }, private_pool), 'reject pool undersizing');
ok(pool.select(['172.31.0.0/16'], inventory, { '4': 4096 }, '172.31.0.0/16')['4'].capacity >=4096,
	'explicitly admitted production pool supports a whole LAN');
rejects(() => pool.select(['172.16.0.0/12'], inventory, { '4': 254 }, '172.16.0.0/12'), 'reject unbounded RFC1918 approval');
if (ARGV[0] == 'initial') print(initial);
else if (ARGV[0] == 'failover') print(failover);
else if (ARGV[0] == 'down') print(failed);
else print('Native AWG planner PASS: precedence, failover, set retention, fail-closed, adapter validation\n');
