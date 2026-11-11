'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const dir = 'root/www/luci-static/resources/view/podkopchik/';
function exportsFrom(name, names, args, values) {
	const src = fs.readFileSync(dir + name + '.js', 'utf8');
	return new Function(...args, src.slice(0, src.indexOf('return view.extend({')) + '\nreturn {' + names + '};')(...values);
}
function E(tag, attrs, children) {
	return {tag, attrs, children, disabled: !!attrs.disabled, textContent: '', listeners: {},
		addEventListener(event, handler) { this.listeners[event] = handler; }};
}
const calls = [];
let modal, reply, notified;
const backend = { async exec_direct(command, args) {
	assert.equal(command, '/usr/bin/podkopchikctl');
	calls.push(args);
	if (reply instanceof Error) throw reply;
	return JSON.stringify(reply);
} };
const ui = { createHandlerFn: (_self, fn) => fn, showModal: (_title, body) => { modal = body; }, hideModal() {} };
const { migrationPanel } = exportsFrom('advanced', 'migrationPanel', ['fs', 'ui', 'E', '_', 'routing'],
	[backend, ui, E, s => s, {notifyApply: res => { notified = JSON.parse(res); }}]);
const { installAvailable } = exportsFrom('updates', 'installAvailable', [], []);
(async () => {
	const [, check, , validate, , migrate, status] = migrationPanel().children;
	assert(validate.disabled && migrate.disabled);
	reply = {ready:false, target:'flint2', issues:['platform_requirements'], checks:[{id:'software_offload',status:'fail'}]};
	await check.listeners.click();
	assert.match(status.textContent, /flint2:.*software_offload: fail/);
	assert(validate.disabled && migrate.disabled);
	reply = {ready:true, target:'flint2'};
	await check.listeners.click();
	assert(!validate.disabled && migrate.disabled);
	reply = new Error('internal configuration details');
	await validate.listeners.click();
	assert(migrate.disabled);
	assert.doesNotMatch(status.textContent, /internal configuration details/);
	reply = {valid:true};
	await validate.listeners.click();
	assert(!migrate.disabled);
	migrate.listeners.click();
	assert(!calls.some(([cmd]) => cmd === 'native-migrate'), 'opening the modal cannot activate routing');
	reply = {pending:'a'.repeat(32), confirmation_required:true, engine:'native'};
	await modal[1].children[2].attrs.click();
	assert.equal(notified.pending, reply.pending);
	assert(check.disabled && validate.disabled && migrate.disabled);
	assert.deepEqual(calls.map(([cmd]) => cmd), [
		'native-migration-readiness', 'native-migration-readiness', 'native-migrate-check', 'native-migrate-check', 'native-migrate'
	]);
	for (const target of ['flint2', 'ax6000']) {
		const fields = 'channel=native-rc\ntarget=' + target + '\nasset=podkopchik-native-' + target + '-candidate.tar.gz\n';
		assert(!installAvailable(fields + 'availability=no_compatible_release'));
		assert(installAvailable(fields + 'availability=available\narchive_url=https://github.com/asset\nsha256=' + 'a'.repeat(64)));
		assert(!installAvailable(fields.replace('asset=podkopchik-native-' + target, 'asset=podkopchik-native-unknown') +
			'availability=available\narchive_url=https://github.com/asset\nsha256=' + 'a'.repeat(64)));
	}
	assert(!installAvailable('Native update: unsupported_board'));
	assert(installAvailable('channel=stable\narchive_url=https://github.com/asset\n\nchangelog:\nchannel=native-rc'));
	const acl = JSON.parse(fs.readFileSync('root/usr/share/rpcd/acl.d/luci-app-podkopchik.json', 'utf8'));
	const {read, write} = acl['luci-app-podkopchik'];
	assert.deepEqual(read.file['/usr/bin/podkopchikctl native-migration-readiness'], ['exec']);
	for (const cmd of ['native-migrate-check', 'native-migrate']) {
		assert.equal(read.file['/usr/bin/podkopchikctl ' + cmd], undefined);
		assert.deepEqual(write.file['/usr/bin/podkopchikctl ' + cmd], ['exec']);
	}
	console.log('PASS: Native migration refusal, dry run, explicit submit, ACL, per-target release availability');
})().catch(e => { console.error(e); process.exitCode = 1; });
