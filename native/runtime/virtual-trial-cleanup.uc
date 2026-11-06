'use strict';

import { stdin } from 'fs';

const action = ARGV[0], epoch = ARGV[1];
if (!match(epoch || '', /^[a-f0-9]{16}$/)) die('invalid virtual trial epoch');
const port = 'pv' + substr(epoch, 0, 12), alias = 'pkc-virtual-' + epoch;
const owners = {
	podkopchik_native: 'podkopchik-native-' + epoch,
	podkopchik_native_gate: 'podkopchik-native-dns-' + epoch,
	pkc_virtual_guard: alias,
};
const items = json(stdin.read('all')).nftables;
if (type(items) != 'array') die('invalid nftables data');

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
else die('invalid cleanup operation');
