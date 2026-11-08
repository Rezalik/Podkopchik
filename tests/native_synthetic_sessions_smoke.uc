'use strict';
const n = require('universal_plan');
const a = require('awg_network').resources('11111111111111111111111111111111');
function ok(value, label) { if (!value) die(label + '\n'); }
function fixture(usable) {
	return { lan: 'br-lan', automatic: usable ? a.tag : 'blocked', classification: { mode: 'compatible' },
		adapters: [{ id: a.id, type: 'amneziawg', usable, ipv4: true, ipv6: true,
			source_ips: ['198.51.1.1', '2001:db8:1::1'] },
			{ tag: 'vless_session', type: 'vless', port: 23000, usable, ipv4: true, ipv6: true }],
		fake_pools: ['198.18.0.0/15'], bypass: [], ips: [],
		clients: [{ cidr: '10.19.0.3', target: 'direct' }],
		domains: [{ names: ['video.example'], target: 'auto_proxy_group' }],
		synthetic: { epoch: 'aabbccddeeff0011', private_pool: '172.31.253.0/24',
			pools: ['172.31.253.0/24', '2001:2::/48'], inventory: {
				addresses: [{ addr_info: [{ local: '10.19.0.1', prefixlen: 24 }] }],
				routes: [{ dst: '198.51.1.0/24' }, { dst: '2001:db8::/32' }], issued: ['198.18.0.0/15'] },
			dns: { port: 1058, ipv4: '10.19.0.1', ipv6: 'fd19::1' } } };
}
const up = n.compile(fixture(true)), down = n.compile(fixture(false));
const rules = n.batch(up), failed = n.switch_batch(up, down);
if (ARGV[0] == 'rules') { print(rules); return; }
for (let row in [{ proto: 'ip', pool: up.synthetic.pools['4'], family: '4' },
	{ proto: 'ip6', pool: up.synthetic.pools['6'], family: '6' }]) {
	let prefix = 'classify iifname "br-lan" ' + row.proto + ' daddr ' + row.pool +
		' ct direction original ct state established ct status dnat ';
	let resume = prefix + 'meta l4proto { tcp, udp } ct mark & 0xff000000 ' + up.adapters[a.tag].pin +
		' meta mark set ' + a.mark + ' counter accept';
	ok(index(rules, resume) >= 0, 'admitted AWG session requires exact transport pin and DNAT');
	ok(index(rules, prefix + 'jump synth_clients' + row.family) < index(rules, resume), 'current client override precedes session resumption');
	ok(index(rules, resume) < index(rules, 'daddr @s_aabbccddeeff0011_g0_' + row.family), 'session is not coupled to DNS TTL');
	ok(index(rules, row.proto + ' daddr ' + row.pool + ' counter drop') > index(rules, resume), 'new stale and unknown synthetic destinations still drop');
	ok(index(failed, resume) < 0, 'unavailable transport cannot resume an established flow');
	let v = up.adapters.vless_session;
	ok(index(rules, prefix + 'meta l4proto tcp ct mark & 0xff000000 ' + v.pin) >= 0, 'VLESS session resumption is TCP only');
	ok(index(rules, prefix + 'meta l4proto { tcp, udp } ct mark & 0xff000000 ' + v.pin) < 0, 'VLESS cannot acquire unsupported UDP');
}
ok(index(rules, 'ip daddr @fake4 counter drop') < index(rules, 'ct direction original ct state established'), 'retired FakeDNS pool remains blocked before session admission');
let limited = fixture(true); limited.adapters[0].ipv6 = false;
ok(index(n.batch(n.compile(limited)), 'ip6 daddr ' + up.synthetic.pools['6'] + ' ct direction original ct state established ct status dnat meta l4proto { tcp, udp }') < 0,
	'IPv4-only transport cannot become an IPv6 bypass');
ok(index(n.dns_gate(up), 'flow_pin iifname "br-lan" ct mark & 0xff000000 != 0 counter drop') >= 0,
	'missing classifier still blocks owned connection pins');
print('Native synthetic sessions PASS: DNS TTL, transport pins, current policy, IPv4/IPv6 and fail-closed\n');
