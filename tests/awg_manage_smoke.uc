'use strict';
import * as fs from 'fs';
import { cursor } from 'uci';
const awg = require('awg'), backend = require('awg_manage');
const root = ARGV[0], owner = fs.stat(root).uid, cfg = root + '/uci.json', active = root + '/active.json';
let assertions = 0, https_ok = true, failures = 0, calls = [], running = {};
function check(value, label) { if (!value) die('FAIL: ' + label); assertions++; }
function write(path, text) { let f = fs.open(path, 'w', 0o600); f.write(text); f.close(); }
function rows() { return json(fs.readfile(cfg)); }
function by_tag(tag) { for (let p in rows()) if (p['.type'] == 'proxy' && p.tag == tag) return p; return null; }
function main() { for (let p in rows()) if (p['.type'] == 'proxy' && p.role == 'main') return p.tag; return null; }
write(cfg, sprintf('%J', [
	{ '.type': 'settings', '.name': 'main', enabled: '1', routing_enabled: '1' },
	{ '.type': 'proxy', '.name': 'ibn_section', enabled: '1', name: 'ibn', tag: 'ibn', role: 'main', uri: 'SYNTHETIC_URI_UNCHANGED' },
	{ '.type': 'proxy_group', '.name': 'auto', enabled: '1', tag: 'auto_proxy_group', primary: 'ibn', mode: 'strict_primary' },
	{ '.type': 'proxy_group', '.name': 'legacy', enabled: '1', tag: 'legacy_manual', fixed_proxy: 'ibn', mode: 'fixed_proxy' }
]));
write(active, '{"outbounds":[{"tag":"ibn","protocol":"vless"}]}');
write(root + '/state.json', sprintf('%J', { proxies: { ibn: { status: 'up', checked_at: time() } },
	groups: { auto_proxy_group: { active_proxy: 'ibn' } } }));
let db = awg.store(root + '/profiles', owner);
const text = '[Interface]\nPrivateKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=\nAddress = 10.66.0.2/32\nRandomTrailers = on\n[Peer]\nPublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=\nEndpoint = vpn.example:443\nAllowedIPs = 0.0.0.0/0\n';
let a = db.run('import', { name: 'AWG A', config: text }).connection;
let b = db.run('import', { name: 'AWG B', config: text }).connection;
let tag_a = 'awg_' + a.id, tag_b = 'awg_' + b.id;
function net(action, id) {
	if (action == 'start' || action == 'restart') running[id] = true;
	if (action == 'stop' || action == 'remove') running[id] = false;
	return { running: !!running[id], status: action == 'check' && https_ok ? 'up' : 'down',
		checked_at: time(), latency_ms: 85, handshake_at: time(), external_ip: '192.0.2.8' };
}
let manager = backend.create({ root: root + '/profiles', tmp: root, owner: owner, uci_file: cfg, active: active,
	cursor: cursor, store: db, network: { run: net }, pid: 123, process_alive: function() { return ''; }, traffic: function() { return {}; },
	shell: function(args) {
		push(calls, args);
		if (index(join(' ', args), 'health_check.sh') >= 0) return '';
		if (index(join(' ', args), 'connection_check.sh') >= 0)
			return sprintf('%J', { status: 'up', checked_at: time() });
		check(length(filter(rows(), function(p) { return p['.type'] == 'proxy' && p.role == 'main'; })) == 1, 'single committed main');
		if (failures > 0) { failures--; awg.fail('apply_failed'); }
		let out = [];
		for (let p in rows()) if (p['.type'] == 'proxy' && p.enabled != '0')
			push(out, { tag: p.tag, protocol: p.protocol || 'vless' });
		write(active, sprintf('%J', { outbounds: out }));
		return '';
	}
});
function fails(method, args, code, label) {
	let error = null;
	try { manager.run(method, args); } catch (e) { error = awg.error(e); }
	check(error && error.code == code, label);
}
let before = fs.readfile(cfg);
https_ok = false;
fails('assign', { tag: tag_a, role: 'main' }, 'unhealthy', 'failed check cannot select a connection');
check(fs.readfile(cfg) == before && main() == 'ibn', 'failed check leaves original UCI byte-for-byte');
check(!running[a.id], 'failed new candidate is stopped');
https_ok = true;
manager.run('assign', { tag: tag_a, role: 'main', priority: '' });
check(main() == tag_a && by_tag('ibn').role == 'rules_only', 'VLESS to AWG main');
check(by_tag('ibn').uri == 'SYNTHETIC_URI_UNCHANGED', 'VLESS URI untouched');
manager.run('rename', { id: a.id, name: 'Renamed AWG main' });
check(by_tag(tag_a).name == 'Renamed AWG main', 'AWG rename updates shared target/status labels without changing roles');
manager.run('assign', { tag: 'ibn', role: 'backup', priority: '1' });
manager.run('assign', { tag: tag_b, role: 'backup', priority: '2' });
check(by_tag('ibn').role == 'backup' && by_tag(tag_b).role == 'backup', 'mixed ordered backups');
manager.run('assign', { tag: 'ibn', role: 'main', priority: '' });
check(main() == 'ibn' && by_tag(tag_a).role == 'rules_only', 'AWG to VLESS main');
before = fs.readfile(cfg);
fails('assign', { tag: tag_a, role: 'backup', priority: '2' }, 'roles', 'duplicate backup priority rejected');
check(fs.readfile(cfg) == before, 'ambiguous roles never committed');
let old_active = fs.readfile(active), old_state = fs.readfile(root + '/state.json');
failures = 1;
fails('assign', { tag: tag_a, role: 'main', priority: '' }, 'apply_failed', 'failed runtime apply reported');
check(fs.readfile(cfg) == before && fs.readfile(active) == old_active && fs.readfile(root + '/state.json') == old_state,
	'failed apply restores UCI, active config and selection');
check(!fs.lstat(root + '/config-apply.lock'), 'transaction lock cleaned');
let c = db.run('import', { name: 'Unselected candidate', config: text }).connection;
failures = 1;
fails('assign', { tag: 'awg_' + c.id, role: 'main', priority: '' }, 'apply_failed', 'new candidate apply fails');
check(!running[c.id] && fs.readfile(cfg) == before, 'failed role transaction stops newly started unselected candidate');
manager.run('delete', { id: c.id });
fs.mkdir(root + '/health-check.lock');
fails('assign', { tag: tag_a, role: 'main', priority: '' }, 'busy', 'health/apply concurrency is refused');
check(fs.readfile(cfg) == before, 'busy health operation does not commit roles');
fs.rmdir(root + '/health-check.lock');
manager.run('set_interception', { enabled: '1' });
check(rows()[0].extended_interception == '1', 'explicit extended interception saved');
let ctx = cursor();
ctx.set('podkopchik', 'site', 'domain_rule');
for (let key, value in { enabled: '1', target: tag_a, domain: [ 'example.com' ] }) ctx.set('podkopchik', 'site', key, value);
ctx.commit('podkopchik');
fails('assign', { tag: tag_a, role: 'disabled', priority: '' }, 'in_use', 'explicit domain target cannot be silently disabled');
ctx = cursor(); ctx.set('podkopchik', 'site', 'target', 'direct'); ctx.commit('podkopchik');
manager.run('assign', { tag: tag_a, role: 'disabled', priority: '' });
manager.run('stop', { id: a.id });
manager.run('delete', { id: a.id });
check(length(db.run('list', {}).connections) == 1 && db.run('list', {}).connections[0].id == b.id, 'safe scoped profile deletion');
check(by_tag('ibn').uri == 'SYNTHETIC_URI_UNCHANGED', 'VLESS preserved after deletion');
check(length(filter(rows(), function(r) { return r.tag == 'legacy_manual'; })) == 1, 'manual legacy group preserved');
let original = fs.readfile(cfg), original_active = fs.readfile(active);
fs.mkdir(root + '/config-apply.lock');
write(root + '/config-apply.lock/connection-journal.json', sprintf('%J', {
	pid: 99999999, phase: 'prepared', uci: original, active: original_active, state: old_state
}));
write(root + '/config-apply.lock/connection-token', 'synthetic-token');
write(cfg, '[]'); write(active, '{"outbounds":[]}');
fails('list', {}, 'recovery_required', 'interrupted transition is visible, not silently ignored');
check(manager.recover(), 'recover dead transaction');
check(fs.readfile(cfg) == original && fs.readfile(active) == original_active, 'crash journal restores previous files');
check(!fs.lstat(root + '/config-apply.lock'), 'crash lock removed');
fs.mkdir(root + '/config-apply.lock');
write(root + '/config-apply.lock/connection-journal.json', sprintf('%J', {
	pid: 99999999, phase: 'prepared', uci: original, active: original_active, state: old_state
}));
write(root + '/config-apply.lock/connection-token', 'synthetic-recovery-token');
write(cfg, '[]'); write(active, '{"outbounds":[]}');
failures = 1;
fails('recover', {}, 'rollback_failed', 'failed runtime recovery is reported');
check(fs.lstat(root + '/config-apply.lock/connection-journal.json') != null, 'failed runtime recovery retains journal');
check(fs.readfile(cfg) == original && fs.readfile(active) == original_active, 'failed recovery retains restored files');
fails('list', {}, 'recovery_required', 'failed recovery remains visible for retry');
manager.run('recover', {});
check(!fs.lstat(root + '/config-apply.lock'), 'successful runtime recovery removes journal only after apply');
check(fs.readfile(cfg) == original && by_tag('ibn').uri == 'SYNTHETIC_URI_UNCHANGED', 'recovery retry preserves VLESS');
// Exercise the real bounded-stderr path only where the absolute router command
// is absent. Never execute a host/router's installed controller from this test.
if (!fs.lstat('/usr/bin/podkopchikctl')) {
	let mock_manager = manager;
	manager = backend.create({ root: root + '/profiles', tmp: root, owner: owner, uci_file: cfg, active: active,
		cursor: cursor, store: db, network: { run: net }, pid: 123,
		process_alive: function() { return ''; }, traffic: function() { return {}; } });
	fs.mkdir(root + '/config-apply.lock');
	write(root + '/config-apply.lock/connection-journal.json', sprintf('%J', {
		pid: 99999999, phase: 'prepared', uci: original, active: original_active, state: old_state
	}));
	write(root + '/config-apply.lock/connection-token', 'synthetic-error-token');
	fails('recover', {}, 'rollback_failed', 'real subprocess failure remains a safe error code');
	let detail = fs.lstat(root + '/connection-last-apply-error');
	check(detail && detail.uid == owner && (detail.mode & 0o777) == 0o600 && detail.size <= 4096,
		'apply stderr is bounded and private');
	check(index(fs.readfile(root + '/connection-last-apply-error') || '', 'SYNTHETIC_URI_UNCHANGED') < 0,
		'diagnostic contains no UCI URI');
	check(length(filter(fs.lsdir(root), function(name) { return substr(name, 0, 19) == 'connection-command-'; })) == 0,
		'temporary stderr file is removed');
	manager = mock_manager;
	manager.run('recover', {});
}
check(index(sprintf('%J', calls), 'SYNTHETIC_URI_UNCHANGED') < 0, 'URIs never passed to subprocess argv');
printf('AWG/VLESS role/rollback UCI MOCK integration OK (%d assertions; no real network claims)\n', assertions);
