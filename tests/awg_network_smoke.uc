'use strict';
import * as fs from 'fs';
const awg = require('awg'), net = require('awg_network');
const root = ARGV[0], owner = fs.stat(root).uid;
let links = [], policy = { '-4': [], '-6': [] }, routes = { '-4': [], '-6': [] }, calls = [], fail_setconf = false;
let handshake = 1000, https_ok = true, clock = 1000, rpf = '0';
let count = 0;
function check(test, label) { if (!test) die('FAIL: ' + label); count++; }
function param(args, key) { let i = index(args, key); return i < 0 ? null : args[i + 1]; }
function mock(args) {
	push(calls, args);
	let cmd = join(' ', args);
	if (cmd == 'awg --version') return 'amneziawg-tools v3.1.20260812';
	if (args[0] == 'sysctl') return rpf;
	if (args[0] == 'modprobe') return '';
	if (cmd == 'ip -d -j link show') return sprintf('%J', links);
	if (cmd == 'ip -j address show') return sprintf('%J', [
		{ ifname: 'br-lan', addr_info: [ { local: '192.168.1.1', prefixlen: 24 } ] }, ...links
	]);
	if (args[0] == 'ip' && args[2] == '-j' && args[3] == 'rule') return sprintf('%J', policy[args[1]]);
	if (args[0] == 'ip' && args[2] == '-j' && args[3] == 'route') return sprintf('%J', routes[args[1]]);
	if (args[0] == 'ip' && args[1] == 'link') {
		let name = param(args, 'dev');
		if (args[2] == 'add') {
			for (let l in links) if (l.ifname == name) die('duplicate interface');
			push(links, { ifindex: 100 + length(calls), ifname: name, ifalias: param(args, 'alias'), flags: [], linkinfo: { info_kind: 'amneziawg' } });
		}
		else if (args[2] == 'delete') {
			links = filter(links, function(l) { return l.ifname != name; });
			for (let f in [ '-4', '-6' ]) {
				routes[f] = filter(routes[f], function(r) { return r.dev != name; });
				// Real iproute2 emits this null marker after link deletion.
				for (let rule in policy[f]) if (rule.oif == name) rule.oif_detached = null;
			}
		}
		else if (param(args, 'alias')) { for (let l in links) if (l.ifname == name) l.ifalias = param(args, 'alias'); }
		else if (index(args, 'up') >= 0) for (let l in links) if (l.ifname == name) l.flags = [ 'UP' ];
		return '';
	}
	if (args[0] == 'ip' && args[2] == 'address') {
		let addr = split(args[4], '/');
		for (let l in links) if (l.ifname == param(args, 'dev')) {
			if (!l.addr_info) l.addr_info = [];
			push(l.addr_info, { local: addr[0], prefixlen: +addr[1] });
		}
		check(index(args, 'noprefixroute') >= 0, 'no connected main route'); return '';
	}
	if (args[0] == 'ip' && args[2] == 'rule') {
		let f = args[1], rule = { priority: +param(args, 'priority'), table: '' + param(args, 'table'), protocol: '186' };
		if (param(args, 'fwmark')) rule.fwmark = sprintf('0x%x', +param(args, 'fwmark'));
		if (param(args, 'oif')) rule.oif = param(args, 'oif');
		if (args[3] == 'add') push(policy[f], rule);
		else policy[f] = filter(policy[f], function(r) {
			return !(r.priority == rule.priority && r.table == rule.table && r.fwmark == rule.fwmark && r.oif == rule.oif);
		});
		return '';
	}
	if (args[0] == 'ip' && args[2] == 'route') {
		let f = args[1], dst = args[4] == 'unreachable' ? 'default' : args[4];
		// ip -N JSON uses numeric RTN_UNREACHABLE=7, not a named type.
		let table = '' + param(args, 'table'), type = args[4] == 'unreachable' ? 7 : 1;
		if (args[3] == 'replace' || args[3] == 'del')
			routes[f] = filter(routes[f], function(r) { return !(r.table == table && r.type == type && r.dst == dst); });
		if (args[3] != 'del') push(routes[f], { dst: dst, table: table, type: type, dev: param(args, 'dev'), protocol: '186', metric: +param(args, 'metric') });
		return '';
	}
	if (args[0] == 'awg') {
		if (args[1] == 'setconf' && fail_setconf) die('synthetic failure');
		if (args[1] == 'show' && args[3] == 'latest-handshakes') return 'SYNTHETIC_PUBLIC_KEY\t' + handshake + '\n';
		if (args[1] == 'show' && args[3] == 'transfer') return 'SYNTHETIC_PUBLIC_KEY\t123\t456\n';
		return '';
	}
	if (args[0] == 'curl') {
		check(param(args, '--interface') == 'if!' + links[0].ifname, 'probe is device-bound');
		check(param(args, '--noproxy') == '*' && param(args, '--resolve') != null, 'probe cannot use env proxy or WAN DNS');
		if (!https_ok) die('synthetic HTTPS failure');
		let path = param(args, '-o'); fs.writefile(path, 'ip=192.0.2.8\n'); return '0.085';
	}
	die('unhandled mock command');
}
const fake = awg.parse('[Interface]\nPrivateKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=\nAddress = 10.66.0.2/32, fd00::2/128\nRandomTrailers = on\n[Peer]\nPublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=\nEndpoint = vpn.example:443\nAllowedIPs = 0.0.0.0/0, ::/0\n');
const fake_b = awg.parse(replace(replace(fake.config, '10.66.0.2', '10.67.0.2'), 'fd00::2', 'fd01::2'));
const a = '11111111111111111111111111111111', b = '22222222222222222222222222222222';
const db = { run: function(method, args) { return { meta: { revision: '1' }, parsed: args.id == b ? fake_b : fake }; } };
const ctl = net.controller({ root: root + '/network', owner: owner, run: mock, store: db, now: function() { return clock; } });
let started = ctl.run('start', a);
check(started.running && started.guarded, 'start');
check(length(policy['-4']) == 2 && length(policy['-6']) == 2, 'mark and oif isolation in both families');
check(net.resources(a).table != net.resources(b).table, 'distinct routing tables');
let before = length(calls);
ctl.run('start', a);
check(length(filter(slice(calls, before), function(x) { return index([ 'add', 'set', 'replace', 'delete' ], x[2]) >= 0; })) == 0, 'idempotent start');
let tested = ctl.run('check', a);
check(tested.status == 'up' && tested.latency_ms == 85 && tested.handshake_at == handshake, 'measured HTTPS and handshake');
check(tested.rx_bytes == 123 && tested.tx_bytes == 456, 'real tool counters parsed');
let actual_addresses = links[0].addr_info;
links[0].addr_info = [];
check(ctl.run('check', a).status == 'down', 'interface UP without configured addresses is not healthy');
links[0].addr_info = actual_addresses;
handshake = 0;
check(ctl.run('check', a).status == 'down', 'HTTPS without handshake is not UP');
handshake = 1000; https_ok = false;
check(ctl.run('check', a).status == 'down', 'handshake without HTTPS is not UP');
https_ok = true;
ctl.run('start', b);
check(length(links) == 2, 'multiple interfaces');
let overlap_failed = false;
try { ctl.run('start', '33333333333333333333333333333333'); } catch (e) { overlap_failed = awg.error(e).code == 'address_conflict'; }
check(overlap_failed && length(links) == 2, 'overlapping inner addresses cannot disturb another tunnel');
ctl.run('stop', a);
check(length(links) == 1 && length(policy['-4']) == 4, 'stop preserves guards and other tunnel');
check(ctl.run('status', a).status == 'down', 'stopped is not available');
ctl.run('remove', a);
check(length(policy['-4']) == 2 && length(links) == 1, 'remove only own policy resources');
ctl.run('stop', b); ctl.run('remove', b);
check(length(links) == 0 && length(policy['-4']) == 0 && length(routes['-4']) == 0, 'complete scoped cleanup');
fail_setconf = true;
let failed = false;
try { ctl.run('start', a); } catch (e) { failed = true; }
check(failed && length(links) == 0 && length(policy['-4']) == 2, 'failed start cleans interface and preserves terminal guard');
check(!fs.lstat(root + '/network/' + a + '.setconf'), 'private temporary config removed');
fail_setconf = false; ctl.run('remove', a);
push(policy['-4'], { priority: net.resources(a).priority, table: '999', fwmark: '0x1234' });
failed = false;
try { ctl.run('start', a); } catch (e) { failed = awg.error(e).code == 'conflict'; }
check(failed && length(links) == 0 && policy['-4'][0].table == '999', 'foreign rule is never taken over/deleted');
policy['-4'] = []; rpf = '1'; failed = false;
try { ctl.run('start', a); } catch (e) { failed = awg.error(e).code == 'rpf'; }
check(failed && length(links) == 0, 'unsupported strict global RPF fails without mutation');
rpf = '0';
for (let i = 0; i < 10; i++) push(links, { ifname: 'test' + i,
	ifalias: 'podkopchik-awg:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', linkinfo: { info_kind: 'amneziawg' } });
failed = false;
try { ctl.run('start', a); } catch (e) { failed = awg.error(e).code == 'limit'; }
check(failed && length(links) == 10, 'bounded interface count');
links = [];
let safe = net.block_active({ inbounds: [ { tag: 'transparent' } ], dns: { servers: [ 'fakedns' ] }, outbounds: [
	{ tag: 'awg_' + a, protocol: 'freedom', settings: {}, streamSettings: { sockopt: { mark: 123 } } },
	{ tag: 'direct', protocol: 'freedom' }, { tag: 'ibn', protocol: 'vless' }
] });
check(safe.outbounds[0].protocol == 'blackhole' && !safe.outbounds[0].streamSettings, 'startup blocks stale AWG bind');
check(safe.outbounds[1].protocol == 'freedom' && safe.outbounds[2].protocol == 'vless' && safe.dns.servers[0] == 'fakedns',
	'startup fallback preserves direct, VLESS and FakeDNS');
check(awg.overlap('10.0.0.2/32', '10.0.0.1/24') && !awg.overlap('10.0.1.2/32', '10.0.0.1/24'), 'IPv4 prefix overlap');
check(awg.overlap('2001:db8::2/128', '2001:db8::1/64') && !awg.overlap('2001:db9::2/128', '2001:db8::1/64'), 'IPv6 prefix overlap');
check(index(sprintf('%J', calls), fake.interface.PrivateKey) < 0, 'keys never enter command arguments');
for (let args in calls) {
	check(index(args, 'main') < 0 && index(args, 'flush') < 0, 'no main route mutation or broad flush');
	check(index(args, 'awg-quick') < 0, 'never execute quick hooks');
}
printf('AWG kernel lifecycle MOCK integration OK (%d assertions; no real handshake claimed)\n', count);
