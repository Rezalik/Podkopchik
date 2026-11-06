'use strict';

import { readfile, stdin } from 'fs';

const action = ARGV[0], epoch = ARGV[1];
if (!match(epoch || '', /^[a-f0-9]{16}$/)) die('invalid virtual trial epoch');
const port = 'pv' + substr(epoch, 0, 12), alias = 'pkc-virtual-' + epoch;
const owners = {
	podkopchik_native: 'podkopchik-native-' + epoch,
	podkopchik_native_gate: 'podkopchik-native-dns-' + epoch,
	pkc_virtual_guard: alias,
};
const data = json(stdin.read('all'));
const items = data?.nftables;
if (index(['tables', 'rules'], action) >= 0 && type(items) != 'array') die('invalid nftables data');

if (action == 'tables') {
	for (let item in items) {
		let t = item.table;
		if (t?.family != 'inet' || !owners[t.name]) continue;
		if (t.comment != owners[t.name]) die('foreign table occupies virtual trial name');
		printf('delete table inet %s\n', t.name);
	}
}
else if (action == 'rules') {
	for (let item in items) {
		let r = item.rule;
		if (r?.comment != alias) continue;
		if (r.family != 'inet' || r.table != 'fw4' || index(['input', 'forward'], r.chain) < 0 ||
			type(r.handle) != 'int' || r.handle < 1 || type(r.expr) != 'array' ||
			!length(filter(r.expr, e => e.match?.op == '==' && e.match.right == port &&
				(e.match.left?.meta?.key == 'iifname' || (r.chain == 'forward' && e.match.left?.meta?.key == 'oifname')))))
			die('refusing an unscoped virtual trial tag');
		printf('delete rule inet fw4 %s handle %d\n', r.chain, r.handle);
	}
}
else if (action == 'routing') {
	const r = json(readfile(ARGV[2] || '', 4097) || '{}');
	const mark = '0x504b0901', table = 48181, prio = 11581;
	if (r.owner != alias || r.port != port || r.mark != mark || r.route_table != table || r.priority != prio ||
		!match(r.device || '', /^paw[0-9a-f]{12}$/) || type(data?.rules) != 'array' || type(data?.routes) != 'array')
		die('invalid virtual route ownership');
	let seen = {};
	for (let x in data.rules) if (x.priority == prio || +x.table == table) {
		if (seen.rule || x.priority != prio || +x.table != table || x.fwmark != mark ||
			(x.fwmask && +x.fwmask != 0xffffffff) || index(['172.31.252.2', '172.31.252.2/32'], x.src) < 0 ||
			x.iif != port || +x.protocol != 242 || (x.dst && x.dst != 'all') || x.oif || x.not || x.suppress_prefixlength != null)
			die('refusing foreign policy rule');
		seen.rule = true; print('rule\n');
	}
	for (let x in data.routes) {
		if (x.dst != 'default' || +x.protocol != 242 || x.gateway || x.nexthops || x.prefsrc ||
			(x.type == 'unreachable' ? (x.dev || x.metric != 42760) : (x.type && x.type != 'unicast') || x.dev != r.device || x.metric != 100))
			die('refusing foreign trial table route');
		let kind = x.type == 'unreachable' ? 'unreachable' : 'tunnel';
		if (seen[kind]) die('duplicate trial table route');
		seen[kind] = true; print(kind + '\n');
	}
}
else die('invalid cleanup operation');
