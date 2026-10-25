'use strict';
// Explicit isolated execution from /tmp only, never installed or UCI-bound.
import * as fs from 'fs';
const awg = require('awg'), net = require('awg_network');
let work = ARGV[0], id = ARGV[1];
if (!match(work || '', /^\/tmp\/podkopchik-awg-controller\.[a-zA-Z0-9]+$/) ||
	trim(fs.readfile('/tmp/sysinfo/board_name') || '') != 'xiaomi,redmi-router-ax6000-stock') die('wrong test environment');
let r = net.resources(id), controller = net.controller({ root: work + '/runtime' });
let failed = false;
try {
	let start = controller.run('start', id);
	if (!start.running || !start.guarded) die('start failed');
	controller.run('start', id);
	let check = controller.run('check', id);
	if (check.status != 'up') die('real HTTPS/handshake failed');
	printf('CONTROLLER_REAL_AWG_HTTPS_UP latency_ms=%d handshake_age=%d rx=%d tx=%d external_ip=%s\n',
		check.latency_ms, check.handshake_age, check.rx_bytes, check.tx_bytes, check.external_ip);
	controller.run('stop', id);
	let stopped = controller.run('status', id);
	if (stopped.running || stopped.status != 'down' || !stopped.guarded) die('stop/guard failed');
	let p = fs.popen(sprintf('ip -4 route get 1.1.1.1 mark %d 2>/dev/null', r.mark), 'r');
	let output = p.read('all'), rc = p.close();
	if (rc == 0 || length(trim(output))) die('stopped tunnel can reach WAN');
	print('STOPPED_MARK_LOOKUP_UNREACHABLE\n');
}
catch (e) { failed = true; warn('Controller isolated test failed: ' + awg.error(e).code + '\n'); }
try { controller.run('remove', id); }
catch (e) { failed = true; warn('Controller cleanup failed; retain test directory and inspect ownership\n'); }
if (fs.lstat('/sys/class/net/' + r.interface)) failed = true;
if (failed) exit(1);
print('CONTROLLER_REAL_LIFECYCLE_PASS; TEMP_INTERFACE_REMOVED\n');
