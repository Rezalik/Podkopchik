'use strict';

import { readfile, stdin } from 'fs';
const pool = require('native_pool');
const action = ARGV[0];
const raw = readfile(ARGV[1] || '', 8193);
if (!raw || length(raw) > 8192) die('invalid recovery manifest length');
const spec = json(raw);
if (spec.schema != 1 || !match(spec.epoch || '', /^[a-f0-9]{16}$/) || type(spec.restore_up) != 'bool' ||
	type(spec.issued) != 'array' || !length(spec.issued) || length(spec.issued) > 16 ||
	type(spec.awg_sources) != 'array' || !length(spec.awg_sources) || length(spec.awg_sources) > 64)
	die('invalid AX6000 recovery manifest');
const fresh = pool.prefix(spec.pool), issued = map(spec.issued, pool.prefix);
if (!pool.private_v4(fresh) || pool.overlaps(fresh, issued)) die('invalid AX6000 recovery pools');
const sources = {};
for (let entry in spec.awg_sources) {
	if (!match(entry?.device || '', /^paw[a-f0-9]{12}$/) || type(entry.address) != 'string' || index(entry.address, '/') >= 0)
		die('invalid AX6000 AWG address ownership');
	let address = split(pool.prefix(entry.address), '/')[0];
	push(sources[address] ??= [], entry.device);
}
const quarantine = 'pkc_ax6000_quarantine', native = 'podkopchik_native', gate = 'podkopchik_native_gate';
const owners = {
	[quarantine]: 'podkopchik-ax6000-' + spec.epoch,
	[native]: 'podkopchik-native-' + spec.epoch,
	[gate]: 'podkopchik-native-dns-' + spec.epoch,
};

if (action == 'info') {
	printf('%s %d\n', spec.epoch, spec.restore_up ? 1 : 0);
}
else if (action == 'quarantine') {
	let base = 'inet ' + quarantine;
	print('add table ' + base + ' { comment "' + owners[quarantine] + '"; }\n');
	for (let hook in ['output', 'forward', 'postrouting']) {
		print('add chain ' + base + ' ' + hook + ' { type filter hook ' + hook + ' priority ' +
			(hook == 'postrouting' ? 300 : -10) + '; policy accept; }\n');
		let r = 'add rule ' + base + ' ' + hook + ' ';
		if (hook != 'forward') for (let address, devices in sources) {
			let proto = pool.family(address) == '4' ? 'ip' : 'ip6';
			let egress = '{ ' + join(', ', map(['lo', ...devices], d => '"' + d + '"')) + ' }';
			print(r + proto + ' saddr ' + address + ' oifname != ' + egress + ' counter drop\n');
		}
		for (let p in [...issued, fresh]) {
			let proto = pool.family(p) == '4' ? 'ip' : 'ip6';
			print(r + proto + ' daddr ' + p + ' counter drop\n');
			print(r + 'ct direction original ct original ' + proto + ' daddr ' + p + ' counter drop\n');
			let egress = p == fresh ? '"lo"' : '{ "lo", "br-lan" }';
			print(r + proto + ' saddr ' + p + ' oifname != ' + egress + ' counter drop\n');
		}
	}
}
else if (action == 'tables') {
	const tables = json(stdin.read('all')).nftables;
	if (type(tables) != 'array') die('invalid nft table listing');
	let seen = {};
	for (let item in tables) if (item.table?.family == 'inet' && owners[item.table.name]) {
		if (ARGV[2] == 'quarantine' && item.table.name != quarantine) continue;
		if (seen[item.table.name] || item.table.comment != owners[item.table.name]) die('foreign nft table');
		seen[item.table.name] = true;
	}
	if (ARGV[2] == 'quarantine') print(seen[quarantine] ? 'owned\n' : 'absent\n');
	else for (let name in [native, gate]) if (seen[name]) print('delete table inet ' + name + '\n');
}
else if (action == 'rules') {
	const rules = json(stdin.read('all')).nftables;
	if (type(rules) != 'array') die('invalid nft rule listing');
	for (let item in rules) if (item.rule?.comment == 'pkc-ax6000-' + spec.epoch) {
		const r = item.rule;
		if (r.family != 'inet' || r.table != 'fw4' || index(['input', 'forward'], r.chain) < 0 ||
			type(r.handle) != 'int' || r.handle < 1) die('invalid owned fw4 rule');
		print('delete rule inet fw4 ' + r.chain + ' handle ' + r.handle + '\n');
	}
}
else die('invalid recovery data action');
