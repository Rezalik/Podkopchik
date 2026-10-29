'use strict';

import { fdopen } from 'fs';
const awg = require('awg');
const methods = {
	list: {},
	import: { name: '', config: '' },
	replace: { id: '', name: '', config: '' },
	validate: { id: '' },
	rename: { id: '', name: '' },
	delete: { id: '' },
	start: { id: '' },
	stop: { id: '' },
	restart: { id: '' },
	check: { id: '' },
	recover: {},
	set_interception: { udp: '', ipv6: '' },
	set_probe: { id: '', url: '', address: '', timeout: '' },
	assign: { tag: '', role: '', priority: '' }
};

if (ARGV[0] == 'list') {
	printf('%J\n', methods);
	exit(0);
}

try {
	if (ARGV[0] != 'call' || !exists(methods, ARGV[1])) awg.fail('request');
	let input = fdopen(0, 'r').read(awg.max_request + 1);
	if (input == null || length(input) > awg.max_request) awg.fail('size');
	let args;
	try { args = json(input); } catch (e) { awg.fail('request'); }
	if (type(args) != 'object') awg.fail('request');
	for (let field, value in args)
		if (field != 'ubus_rpc_session' && (!exists(methods[ARGV[1]], field) || type(value) != 'string'))
			awg.fail('request');
	let result = require('awg_manage').run(ARGV[1], args);
	result.ok = true;
	printf('%J\n', result);
}
catch (e) {
	// Never forward parser/runtime exception text: it may include source data.
	let detail = awg.error(e);
	printf('%J\n', { ok: false, error: detail.code, line: detail.line || 0, field: detail.field || '' });
}
