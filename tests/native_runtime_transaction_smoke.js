'use strict';
// Exercise the production final staging block, without executing router tools.
const assert = require('assert');
const fs = require('fs');
const source = fs.readFileSync('root/usr/libexec/podkopchik/native_runtime.uc', 'utf8');
const begin = source.indexOf("\tlet c=ctx();c.set('podkopchik','main','enabled','1');");
const end = source.indexOf('\n}', begin);
assert(begin > 0 && end > begin);
function stage(commitOK, watcherOK) {
	const calls = [], prior = {current:'previous'};
	const ctx = () => ({set(){}, commit(){calls.push('commit'); return commitOK;}});
	const run = new Function('ctx','watch_service','save','journal','fail','META','prior','g','id','seconds','repair', source.slice(begin, end));
	let result, error;
	try {
		result = run(ctx, () => {calls.push('watch'); if (!watcherOK) throw Error('watch failed');},
			(path, value) => {assert.strictEqual(path, 'metadata'); assert.strictEqual(value, prior); calls.push('restore');},
			action => calls.push(action), message => {throw Error(message);}, 'metadata', prior, 'candidate', 'a'.repeat(32), 300, false);
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
console.log('Native staging compensation smoke PASS: UCI commit/supervisor errors retain the previous pointer');
