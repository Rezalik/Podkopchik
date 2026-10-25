'use strict';
const assert = require('assert');
const path = require('path');
const cp = require('child_process');
const fs = require('fs');
const ucode = process.env.UCODE || 'ucode';
if (cp.spawnSync(ucode, ['-h']).error) { console.log('SKIP: AWG RPC tests require local ucode + fs'); process.exit(0); }
const flags = ['-L', process.env.UCODE_MODULE_DIR || '/usr/lib/ucode', '-L', path.resolve('root/usr/libexec/podkopchik'), 'root/usr/libexec/podkopchik/awg_rpc.uc'];
function run(args, input) {
	const r = cp.spawnSync(ucode, flags.concat(args), { input, encoding: 'utf8', maxBuffer: 1024 * 1024 });
	assert.strictEqual(r.status, 0, r.stderr);
	assert.strictEqual(r.stderr, '', 'RPC stderr must not leak user values');
	return JSON.parse(r.stdout);
}
const methods = run(['list'], '');
assert.deepStrictEqual(Object.keys(methods).sort(), ['delete','import','list','rename','replace','validate']);
assert.strictEqual(run(['call', 'execute'], '{}').error, 'request');
assert.strictEqual(run(['call', 'import'], '{bad').error, 'request');
assert.strictEqual(run(['call', 'list'], '{"path":"/etc/shadow"}').error, 'request');
assert.strictEqual(run(['call', 'import'], JSON.stringify({name: 'x', config: {}, path: '../../x'})).error, 'request');
assert.strictEqual(run(['call', 'import'], 'x'.repeat(6 * 65536 + 4097)).error, 'size');
const moduleText = fs.readFileSync('root/usr/libexec/podkopchik/awg.uc', 'utf8');
assert(!/\b(system|popen|exec|logger)\s*\(/.test(moduleText), 'storage/parser must not execute or log uploaded data');
const entry = fs.readFileSync('root/usr/libexec/podkopchik/awg_rpc.uc', 'utf8');
assert(entry.includes("store('/etc/podkopchik/awg', 0)"));
assert(!entry.includes('getenv'), 'RPC storage path cannot be supplied by the caller');
assert.strictEqual(fs.readFileSync('root/lib/upgrade/keep.d/podkopchik-awg', 'utf8').trim(), '/etc/podkopchik/awg/');
console.log('AWG native RPC framing, limits, secret-free errors and fixed storage smoke OK');
