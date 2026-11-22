'use strict';
import * as fs from 'fs';
const root = ARGV[0], owner = fs.stat(root).uid, awg = require('awg');
const db = awg.store(root + '/profiles', owner);
const conf = '[Interface]\nPrivateKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=\nRandomTrailers = on\n[Peer]\nPublicKey = AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=\nAllowedIPs = 0.0.0.0/0\nEndpoint = example.test:443\n';
let item = db.run('import', {name:'Fixture', config:conf}).connection;
let args = {id:item.id,revision:item.revision,endpoints:'["example.test:8443"]',mtu:'',listen_port:''};
let held = fs.open(root+'/.lock','a+',0o600), waits = 0, release = true;
let manager = require('awg_manage').create({store:db,tmp:root,native_state:root,owner,
	cursor:()=>({get:()=> 'native'}), wait_for_edit:ms=>{
		assert(ms == 250);
		let f = fs.open(root + '/awg-management.lock','a+',0o600);
		assert(f.lock('xn'), 'must not retain management lock while waiting'); f.close();
		waits++; if (release) held.close();
	}});
function refused(code) {
	let err; try { manager.run('edit_settings', args); } catch (e) { err = awg.error(e).code; }
	assert(err == code);
}
assert(held.lock('xn'));
let r = manager.run('edit_settings', args);
assert(waits == 1 && r.native_staged && r.connection.endpoints[0]=='example.test:8443');
refused('stale');
args.revision = r.connection.revision; args.endpoints = '["example.test:443"]';
held = fs.open(root+'/.lock','a+',0o600); assert(held.lock('xn'));
waits = 0; release = false; refused('busy'); assert(waits==16); held.close();
let meta = fs.open(root+'/runtime.json','w',0o600); meta.write('{"pending":"fixture"}'); meta.close();
waits = 0; refused('busy'); assert(!waits);
assert(db.run('list',{}).connections[0].revision == args.revision);
print('Editor lock: transient, timeout, stale revision and pending Apply OK\n');
