'use strict';
const g = require('fakedns_guard');
function ok(cond, message) { if (!cond) die(message + '\n'); }
function rejects(fn, message) {
	let failed = false; try { fn(); } catch (e) { failed = true; }
	ok(failed, message);
}
const empty = { schema: 1, pools: [], lans: [] };
let configured = { fakedns: [{ ipPool: '198.19.9.3/15' }, { ipPool: '2001:2::1234/48' }] };
let s = g.desired(empty, [configured], ['br-lan']);
ok(length(g.desired(empty, [{}], ['br-lan']).pools) == 0, 'disabled FakeDNS must not reserve benchmark space');
ok(index(s.pools, '198.18.0.0/15') >= 0 && index(s.pools, '2001:2:0:0:0:0:0:0/48') >= 0, 'canonical IPv4/IPv6 pools');
let stale = g.desired(s, [{ fakedns: { ipPool: '192.0.2.0/24' } }], ['br-guest']);
ok(length(stale.pools) == 3 && length(stale.lans) == 2, 'new pool and LAN retain issued pool/history');
ok(length(g.desired(stale, [{}], []).pools) == 3, 'disabled routing/FakeDNS must retain stale pools');
rejects(() => g.pools({ fakedns: { ipPool: '0.0.0.0/0' } }), 'default route must be rejected');
rejects(() => g.pools({ fakedns: { ipPool: '198.18.0.0/15; flush ruleset' } }), 'invalid CIDR must be rejected');
rejects(() => g.check_conflicts(s.pools, [{ addr_info: [{ local: '198.19.7.1', prefixlen: 24 }] }], [], []), 'interface conflict');
rejects(() => g.check_conflicts(s.pools, [], [{ dst: '2001:2:1::/64' }, { dst: '2001:2::/64' }], []), 'real routed subnet conflict');
rejects(() => g.check_conflicts(s.pools, [], [], ['198.18.0.1']), 'explicit exclusion conflict');
g.check_conflicts(s.pools, [{ addr_info: [{ local: '192.168.1.1', prefixlen: 24 }] }], [{ dst: 'default' }], []);
ok(g.rule_pool({ priority: 10992, src: 'all', dst: '198.18.0.0', dstlen: 15, action: '6', protocol: '187' }, '-4') == '198.18.0.0/15', 'kernel numeric ownership');
rejects(() => g.rule_pool({ priority: 10992, dst: '198.18.0.0/15', action: 'blackhole', protocol: 187, iif: 'wan' }, '-4'), 'foreign selector must not be owned');
let text = g.batch(s, true);
ok(index(text, 'delete table inet podkopchik_fake_guard\n') == 0, 'replace only owned fake guard');
for (let chain in ['forward', 'output', 'postrouting']) for (let family in ['ip', 'ip6'])
	ok(index(text, chain + ' ' + family + ' daddr @fake') >= 0, 'both families at each egress path');
ok(index(text, 'oifname != { "lo", "br-lan" } counter drop') >= 0, 'local fake-source replies allowed');
print('FakeDNS quarantine model PASS: scoped pools, conflicts, ownership, stale union, dual stack\n');
