'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const source = fs.readFileSync('root/usr/libexec/podkopchik/native_runtime.uc', 'utf8');
function body(name) {
	const start = source.indexOf('function ' + name + '(');
	const end = source.indexOf('\n}', start) + 2;
	assert(start >= 0 && end > start);
	return source.slice(start, end);
}
function rollback(state) {
	const calls = [];
	const invoke = new Function('m', 'calls', `
		const LIB='installed', META='runtime';
		const generation=id=>'g-'+id;
		const data=path=>path.endsWith('/code.json')?{path:LIB}:{lan:'br-lan'};
		const transition=()=>{}, stop=()=>{}, verify=()=>{};
		const journal=(action)=>{calls.push(action); return 'waiting';};
		const save=()=>{};
		const activate=g=>calls.push('activate:'+g);
		const recover_kernel=g=>calls.push('recovery:'+g);
		${body('rollback')}
		rollback(m);
	`);
	invoke(state, calls);
	return calls;
}
assert.deepEqual(rollback({current:'confirmed',confirmed:'confirmed',previous:'older',pending:null}),
	['recovery:g-confirmed'], 'recovery cannot select an obsolete generation over the confirmed one');
assert.deepEqual(rollback({current:'trial',confirmed:'confirmed',previous:'older',pending:'trial'}),
	['poll','abort','activate:g-confirmed','restored']);
assert.deepEqual(rollback({current:'first',pending:'first'}),
	['poll','abort','recovery:g-first','restored']);
for (const phase of ['recovery', 'active']) {
	const unlinked = [];
	new Function('phase', 'unlinked', `
		const m={engine:'native',phase,current:'same'};
		const index=(values,value)=>values.indexOf(value);
		const meta=()=>m, generation=id=>id, verify=()=>{};
		const RUNTIME='runtime', TMP='tmp';
		const data=()=>({compiled:{}}), compile=()=>({compiled:{}});
		const recovery_policy=x=>x, planner={switch_batch:()=>''};
		const nft=()=>{},publish_dns_transport=()=>{},xray_service=()=>{},save=()=>{};
		const fs={unlink:p=>unlinked.push(p)};
		${body('select_state')}
		select_state();
	`)(phase, unlinked);
	assert.equal(unlinked.length, phase === 'active' ? 1 : 0, 'a health refresh in recovery must preserve the failure diagnostic');
}
console.log('PASS: confirmed-generation recovery, first-trial recovery and retained recovery error');
