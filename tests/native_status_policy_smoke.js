'use strict';
const assert = require('assert');
const fs = require('fs');
const routing = require('./lib/luci-routing')();
const source = fs.readFileSync('root/usr/libexec/podkopchik/native_runtime.uc', 'utf8');
const start = source.indexOf("else if(action=='status'){");
const end = source.indexOf("\nelse fail('unknown native lifecycle action')", start);
assert(start >= 0 && end > start);
const body = source.slice(start + "else if(action=='status'){".length, end).replace(/}\s*;?$/, '');
const args = ['meta','generation','data','RUNTIME','settings','printf','helper_available','journal','healthy','planner','DNS_STATE','read','TMP'];
function status(saved) {
	const active = {classification:{mode:'strict',unknown:'protected'},rules:{domains:81,ips:7,clients:0},
		dns:{listen:'192.168.1.1:1053',pools:['172.30.0.0/16'],protected_upstream:'/private/state'},automatic:{active:'awg_main'}};
	let result;
	new Function(...args, body)(
		()=>({current:'a'.repeat(32),engine:'native',phase:'active',pending:null}), id=>'generation/'+id,
		path=>path==='runtime'?active:{schema:1}, 'runtime', ()=>saved,
		(_format,value)=>{result=value;}, ()=>true, ()=>'waiting', ()=>true,
		{classification: value=>{
			const p=routing.fromSettings(name=>({native_classification_mode:value.mode,
				native_migration_restrict_unknown:value.migration_restrict_unknown,native_unknown_action:value.unknown_action,
				native_direct_grants_confirmed:value.direct_grants_confirmed})[name]);
			if(!p)throw Error('invalid policy');return p;
		}}, 'dns-state', ()=>'', '/tmp/example');
	return result;
}
let r=status({routing_engine:'native',private_key:'secret-must-not-be-exposed'});
assert.strictEqual(r.classification.mode,'strict','active policy cannot be read from saved UCI');
assert.strictEqual(r.configured_classification.mode,'compatible');
assert.strictEqual(r.configured_classification.unknown,'direct');
assert.strictEqual(r.dns.listen,'192.168.1.1:1053');
assert.strictEqual(r.dns.protected,true);
assert(!JSON.stringify(r).includes('secret-must-not-be-exposed'));
assert(!JSON.stringify(r.dns).includes('/private/state'));
r=status({routing_engine:'native',native_migration_restrict_unknown:'1'});
assert.strictEqual(r.configured_classification.unknown,'protected');
r=status({native_direct_grants_confirmed:'1'});
assert.strictEqual(r.configured_classification.direct_grants_confirmed,true,'saved exception consent must not be reported as false');
r=status({native_classification_mode:'invalid'});
assert.strictEqual(r.configured_classification,null,'invalid saved policy must not break runtime status');
console.log('Native status contract PASS: live/saved separation, selective defaults, migration override and no config-secret exposure');
