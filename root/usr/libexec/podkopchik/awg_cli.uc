'use strict';
import { cursor } from 'uci';
const awg = require('awg');
const manager = require('awg_manage');
let action = ARGV[0], ctx = cursor();
if (action == 'block-active') {
	// Startup fallback only: never permit a stale interface-bound freedom
	// outbound to fall through to WAN after /tmp policy ownership was lost.
	let cfg = json(require('fs').readfile('/etc/podkopchik/config.json'));
	printf('%J\n', require('awg_network').block_active(cfg));
}
else if (action == 'recover') {
	if (ARGV[1] == 'apply') manager.run('recover', {});
	else manager.recover();
}
else if (action == 'dispose-all') {
	// Only recorded, validated ownership. Also covers interrupted starts that
	// never acquired a persistent UCI binding. Caller must first stop Xray.
	let fs = require('fs'), network = require('awg_network').controller();
	for (let pid in fs.lsdir('/proc') || []) if (match(pid, /^[0-9]+$/)) {
		let args = split(fs.readfile('/proc/' + pid + '/cmdline') || '', '\x00');
		let pos = index(args, '-config'), path = pos >= 0 ? args[pos + 1] : '';
		if (index(args, 'run') >= 0 && (path == '/etc/podkopchik/config.json' ||
			substr(path || '', 0, 16) == '/tmp/podkopchik/')) awg.fail('in_use');
	}
	for (let name in fs.lsdir('/tmp/podkopchik/awg') || [])
		if (match(name, /^[a-f0-9]{32}\.json$/)) network.run('remove', substr(name, 0, 32));
}
else if (action == 'sync' || action == 'stop-all') {
	let failed = false, seen = {};
	ctx.foreach('podkopchik', 'proxy', function(p) {
		if (p.protocol != 'amneziawg') return;
		seen[p.awg_id] = true;
		try {
			if (action == 'stop-all') manager.runtime(p.awg_id, 'stop', false);
			else if (p.autostart == '1') manager.runtime(p.awg_id, 'start');
			else if (p.enabled != '0') manager.runtime(p.awg_id, 'park');
			else manager.runtime(p.awg_id, 'stop', false);
		}
		catch (e) {
			failed = true;
			warn('AWG ' + (p.tag || '') + ': ' + awg.error(e).code + '\n');
		}
	});
	let fs = require('fs');
	for (let name in fs.lsdir('/tmp/podkopchik/awg') || [])
		if (match(name, /^[a-f0-9]{32}\.json$/) && !seen[substr(name, 0, 32)]) {
			try { manager.runtime(substr(name, 0, 32), 'stop', false); }
			catch (e) { failed = true; warn('AWG orphan cleanup: ' + awg.error(e).code + '\n'); }
		}
	if (failed) exit(1);
}
else if (action == 'health') {
	let value;
	try { value = manager.runtime(ARGV[1], 'check'); }
	catch (e) { value = { status: 'unknown', reason: awg.error(e).code }; }
	printf('%J\n', value);
}
else if (action == 'list') printf('%J\n', manager.run('list', {}));
else if (action == 'endpoints') {
	let list = require('awg').store('/etc/podkopchik/awg', 0).run('list', {}).connections;
	for (let p in list)
		for (let value in p.endpoints || []) {
			let host = substr(value, 0, 1) == '[' ? substr(value, 1, index(value, ']') - 1) :
				substr(value, 0, rindex(value, ':'));
			printf('%s\n', host);
		}
}
else if (index([ 'start', 'stop', 'restart', 'check' ], action) >= 0)
	printf('%J\n', manager.run(action, { id: ARGV[1] }));
else awg.fail('request');
