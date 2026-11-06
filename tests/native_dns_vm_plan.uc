'use strict';
const native = require('universal_plan');
const network = require('awg_network');
const a = '11111111111111111111111111111111', b = '22222222222222222222222222222222';
const ar = network.resources(a), br = network.resources(b);

function plan(active) {
	return native.compile({ lan: 'br-lan', automatic: active,
		adapters: [{ id: a, type: 'amneziawg', usable: active == ar.tag, ipv4: true, ipv6: true },
			{ id: b, type: 'amneziawg', usable: active != 'blocked', ipv4: true, ipv6: true }],
		fake_pools: ['198.19.0.0/16'], bypass: ['192.0.2.2'],
		synthetic: { epoch: '0011223344556677', pools: ['198.18.0.0/16', '2001:2::/48'] },
		clients: [{ cidr: '10.19.0.3', target: br.tag }],
		domains: [{ names: ['protected.example'], target: 'auto_proxy_group' },
			{ names: ['direct.example'], target: 'direct' }],
		ips: [{ cidr: '203.0.113.81', target: 'auto_proxy_group' }] });
}

let primary = plan(ar.tag), backup = plan(br.tag), down = plan('blocked');
switch (ARGV[0]) {
	case 'gate': print(native.dns_gate(primary)); break;
	case 'primary': print(native.batch(primary)); break;
	case 'backup': print(native.switch_batch(primary, backup)); break;
	case 'down': print(native.switch_batch(backup, down)); break;
	case 'restore': print(native.switch_batch(down, primary)); break;
	case 'dns': printf('%J\n', native.dns_policy(primary, '10.19.0.1:1058', '127.0.0.1:1059', [])); break;
	case 'resources':
		for (let x in [ar, br]) printf('%s %d %d %d\n', x.interface, x.mark, x.table, x.priority);
		break;
	default: die('unknown fixture mode');
}
