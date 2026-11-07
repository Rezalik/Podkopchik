'use strict';
const assert = require('assert');
const fs = require('fs');
const source = fs.readFileSync('root/usr/libexec/podkopchik/native_runtime.uc', 'utf8');
const start = source.indexOf('function start_transports(g){');
const end = source.indexOf('\nfunction dns_transport_state', start);
// ucode iterates array values with `in`; JavaScript uses `of` for this case.
const block = source.slice(start, end).replace('for(let id in spec.profiles)', 'for(let id of spec.profiles)');
const fn = new Function('data', 'awg', 'network', 'TMP', 'net', block + ';return start_transports;');
for (const change of [{}, {running:false}, {guarded:false}, {addresses_assigned:false}, {revision:'changed'}]) {
	const calls = [];
	const live = {running:true, guarded:true, addresses_assigned:true, revision:'attested', ...change};
	const store = {run:() => ({meta:{revision:'attested'}})};
	const invoke = fn(() => ({profiles:['one'], endpoint_pins:{}}), {store:() => store}, {
		controller:() => ({inspect_status:() => live, run:(action,id) => calls.push([action,id])})
	}, '/private', () => {throw Error('unexpected router command');});
	invoke('/generation');
	assert.deepStrictEqual(calls, Object.keys(change).length ? [['start','one']] : []);
}
console.log('Native transport start PASS: attested healthy AWG does not contend with health lock; changed/unguarded interfaces still reconcile');
