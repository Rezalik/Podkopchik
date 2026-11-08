'use strict';
const assert = require('assert');
const notifications = [];
const routing = require('./lib/luci-routing')({
	ui: {addNotification: (...args) => notifications.push(args)},
	E: (tag, attrs, children) => ({tag, attrs, children})
});
const policy = settings => routing.fromSettings(name => settings[name]);
const selective = policy({});
assert.strictEqual(selective.mode, 'compatible');
assert.strictEqual(selective.unknown, 'direct');
assert(routing.description(selective).includes('All other traffic goes directly'));
for (const value of [true, 1, '1', 'true']) {
	const migration = policy({native_migration_restrict_unknown: value});
	assert.strictEqual(migration.unknown, 'protected');
	assert.strictEqual(routing.label(migration), 'Migration restriction');
}
const strict = policy({native_classification_mode: 'strict'});
const blocked = policy({native_classification_mode: 'strict', native_unknown_action: 'block'});
assert.strictEqual(strict.unknown, 'protected');
assert.strictEqual(blocked.unknown, 'drop');
assert(routing.description(blocked).includes('blocked'));
assert.strictEqual(policy({native_classification_mode: 'invalid'}), null);
assert.strictEqual(policy({native_unknown_action: 'invalid'}), null);
assert.strictEqual(routing.activePolicy({classification: strict}), strict);
assert(routing.differs(strict, selective));
assert(!routing.differs(selective, policy({})));
assert.strictEqual(routing.activePolicy({unknown_fallback: {'4': {tcp:'blocked',udp:'blocked',other:'blocked'},
	'6': {tcp:'blocked',udp:'blocked',other:'blocked'}}}), null, 'all-down cannot identify the configured policy');
assert.strictEqual(routing.activePolicy({unknown_fallback: {'4': {tcp:'direct',udp:'direct',other:'direct'},
	'6': {tcp:'direct',udp:'direct',other:'direct'}}}).unknown, 'direct');
assert.strictEqual(routing.activePolicy({}), null, 'unavailable status cannot claim selective routing');
const result = JSON.stringify({engine:'native',pending:'a'.repeat(32),confirmation_required:true});
assert.strictEqual(routing.notifyApply(result), result);
assert.strictEqual(notifications[0][2], 'warning');
assert.strictEqual(notifications[0][1].children[1].attrs.href, '/admin/services/podkopchik/status');
routing.notifyApply(JSON.stringify({engine:'native',pending:'b'.repeat(32),confirmation_required:true,recovery_policy:'repair'}));
assert(notifications[1][1].children[0].children.includes('Emergency recovery remains active'));
assert(!notifications[1][1].children[0].children.includes('rollback deadline'));
routing.notifyApply('Legacy routing applied.');
assert.strictEqual(notifications[2][1].tag, 'pre');
console.log('Native UI policy PASS: selective/Strict/migration, authoritative runtime, invalid/unavailable status and explicit Apply confirmation');
