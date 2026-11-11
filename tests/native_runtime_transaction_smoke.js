'use strict';
// Exercise the production final staging block, without executing router tools.
const assert = require('assert');
const fs = require('fs');
const source = fs.readFileSync('root/usr/libexec/podkopchik/native_runtime.uc', 'utf8');
const begin = source.indexOf('\tlet c=ctx(),committed=false;');
const end = source.indexOf('\n}', begin);
assert(begin > 0 && end > begin);
const block = source.slice(begin, end).replace('for(let key,value in intent)', 'for(const [key,value] of Object.entries(intent))');
function stage(commitOK, watcherOK, migrate = false, changed = false) {
	const calls = [], prior = {current:'previous'};
	const ctx = () => ({set(){}, commit(){calls.push('commit'); return commitOK;}});
	const run = new Function('ctx','watch_service','save','journal','fail','META','prior','g','id','seconds','repair',
		'migrate','intent','original','read','UCI_DIR','before','restore_legacy_intent', block);
	let result, error;
	try {
		result = run(ctx, () => {calls.push('watch'); if (!watcherOK) throw Error('watch failed');},
			(path, value) => {assert.strictEqual(path, 'metadata'); assert.strictEqual(value, prior); calls.push('restore');},
			action => calls.push(action), message => {throw Error(message);}, 'metadata', prior, 'candidate', 'a'.repeat(32), 300, false,
			migrate, {enabled:'1',routing_enabled:'1'}, 'saved', () => changed ? 'edited' : 'saved', '/etc/config', {routing_engine:'legacy'},
			before => {assert.strictEqual(before.routing_engine, 'legacy'); calls.push('restore-intent'); return true;});
	} catch (e) {error=e;}
	return {calls, result, error};
}
let r = stage(true, true);
assert.deepStrictEqual(r.calls, ['commit','watch']);
assert.strictEqual(r.result.confirmation_required, true);
for (const [commitOK, watcherOK, expected] of [
	[false,true,['commit','restore','abort','restored']],
	[true,false,['commit','watch','restore','abort','restored']]
]) {
	r = stage(commitOK, watcherOK);
	assert(r.error && r.error.message.includes('previous runtime retained'));
	assert.deepStrictEqual(r.calls, expected);
}
r = stage(true, false, true);
assert.deepStrictEqual(r.calls, ['commit','watch','restore-intent','restore','abort','restored']);
r = stage(true, true, true, true);
assert(r.error);
assert.deepStrictEqual(r.calls, ['restore','abort','restored']);
console.log('Native staging compensation smoke PASS: commit/supervisor errors retain pointer and migration intent');
