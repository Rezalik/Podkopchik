'use strict';
import { readfile } from 'fs';
const native = require('universal_plan');
const network = require('awg_network');
const a = '11111111111111111111111111111111', b = '22222222222222222222222222222222';
const ar = network.resources(a), br = network.resources(b);

function plan(active) {
	return native.compile({ lan: 'br-lan', legacy_lans: ['legacy0'], automatic: active,
		unknown_candidates:[ar.tag,br.tag],
		classification:{mode:getenv('PKC_VM_CLASSIFICATION') || 'compatible',
			migration_restrict_unknown:getenv('PKC_VM_MIGRATION')=='1',direct_grants_confirmed:true,
			unknown_action:getenv('PKC_VM_UNKNOWN_ACTION') || 'protected'},
		adapters: [{ id: a, type: 'amneziawg', usable: active == ar.tag, ipv4: true, ipv6: true, source_ips: ['198.51.1.1', '2001:db8:1::1'] },
			{ id: b, type: 'amneziawg', usable: active == ar.tag || active == br.tag || active=='lab_vless', ipv4: true, ipv6: true, source_ips: ['198.51.2.1', '2001:db8:2::1'] },
			{ tag: 'lab_vless', type: 'vless', usable: true, port: 23000, ipv4: true, ipv6: true }],
		fake_pools: ['198.18.0.0/15'], bypass: ['192.0.2.2','2001:db8::2'],
		synthetic: { epoch: '0011223344556677', private_pool: '172.31.253.0/24', pools: ['172.31.253.0/24', '2001:2::/48'],
			inventory: { addresses: [{ addr_info: [{ local: '10.19.0.1', prefixlen: 24 }, { local: 'fd19::1', prefixlen: 64 }] }],
				routes: map(['192.0.2.0/24', '198.51.1.0/24', '198.51.2.0/24', '203.0.113.0/24', '2001:db8::/32'], dst => ({ dst })),
				issued: ['198.18.0.0/15'] },
			dns: { port: 1058, ipv4: '10.19.0.1', ipv6: 'fd19::1' } },
		clients: [{ cidr: '10.19.0.3', target: br.tag },{cidr:'10.19.0.4',target:'direct'},
			{cidr:'fd19::4',target:'direct'}],
		domains: [{ names: ['protected.example'], target: 'auto_proxy_group' },
			{ names: ['direct.example'], target: 'direct' },
			{ names: ['vless.example'], target: 'lab_vless' }],
		ips: [{ cidr: '203.0.113.81', target: 'auto_proxy_group' },
			{cidr:'203.0.113.82',target:'direct'}, {cidr:'2001:db8:82::1',target:'direct'}] });
}

let primary = plan(ar.tag), backup = plan(br.tag), down = plan('blocked'), vless = plan('lab_vless');
switch (ARGV[0]) {
	case 'bootstrap-gate': print(native.dns_gate({...primary,classification:native.classification({mode:'compatible'})})); break;
	case 'gate': print(native.dns_gate(primary)); break;
	case 'canary': print(native.canary_guard(primary)); break;
	case 'edge': print(native.dns_edge(primary)); break;
	case 'release': print(native.legacy_restore(primary)); break;
	case 'forward': print(native.fw4_forward(primary)); break;
	case 'primary': print(native.batch(primary)); break;
	case 'backup': print(native.switch_batch(primary, backup)); break;
	case 'down': print(native.switch_batch(backup, down)); break;
	case 'restore': print(native.switch_batch(down, primary)); break;
	case 'to-vless': print(native.switch_batch(primary, vless)); break;
	case 'from-vless': print(native.switch_batch(vless, primary)); break;
	case 'dns': printf('%J\n', native.dns_policy(primary, '10.19.0.1:1058', '127.0.0.1:53', [])); break;
	case 'xray': printf('%J\n', native.xray_config(primary, { lab_vless: { tag: 'lab_vless', protocol: 'vless',
		settings: { vnext: [{ address: '192.0.2.2', port: 18443,
			users: [{ id: '11111111-2222-4333-8444-555555555555', encryption: 'none' }] }] } } })); break;
	case 'xray-route': let x = primary.adapters.lab_vless; printf('%d %d %d\n', x.delivery, x.table, x.priority); break;
	case 'live-inventory':
		native.check_pool_inventory(values(primary.synthetic.pools), { addresses: json(readfile(ARGV[1])),
			routes: [...json(readfile(ARGV[2])), ...json(readfile(ARGV[3]))], issued: primary.fake,
			rules: [...json(readfile(ARGV[4])), ...json(readfile(ARGV[5]))] }, primary.synthetic.private_pool);
		break;
	case 'resources':
		for (let x in [ar, br]) printf('%s %d %d %d\n', x.interface, x.mark, x.table, x.priority);
		break;
	default: die('unknown fixture mode');
}
