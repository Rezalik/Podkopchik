'use strict';

import * as fs from 'fs';
import { cursor as native_cursor } from 'uci';
const awg = require('awg');
const net = require('awg_network');
function create(options) {
options = options || {};
const ROOT = options.root || '/etc/podkopchik/awg';
const TMP = options.tmp || '/tmp/podkopchik';
const UCI_FILE = options.uci_file || '/etc/config/podkopchik';
const ACTIVE = options.active || '/etc/podkopchik/config.json';
const OWNER = options.owner == null ? 0 : options.owner;
const cursor = options.cursor || native_cursor;
const db = options.store || awg.store(ROOT, OWNER);
const network = options.network || net.controller();
const LOCK = TMP + '/config-apply.lock';
const JOURNAL = LOCK + '/connection-journal.json';

function atomic(path, text) {
	let tmp = path + '.new';
	fs.unlink(tmp);
	let f = fs.open(tmp, 'wx', 0o600);
	if (!f) awg.fail('storage');
	let n = f.write(text), flushed = f.flush(), closed = f.close();
	if (n != length(text) || !flushed || !closed || !fs.rename(tmp, path)) {
		fs.unlink(tmp); awg.fail('storage');
	}
}
function remove_transaction() {
	fs.unlink(JOURNAL); fs.unlink(JOURNAL + '.new');
	fs.unlink(LOCK + '/connection-token'); fs.unlink(LOCK + '/connection-token.new'); fs.rmdir(LOCK);
}
function restore(journal) {
	atomic(UCI_FILE, journal.uci);
	let files = [ [ ACTIVE, journal.active ], [ TMP + '/state.json', journal.state ] ];
	for (let item in files) {
		let path = item[0], content = item[1];
		if (content == null) fs.unlink(path);
		else atomic(path, content);
	}
}
function recovery_needed() {
	if (!fs.lstat(JOURNAL)) return false;
	let s = fs.lstat(JOURNAL);
	if (s.type != 'file' || s.uid != OWNER || (s.mode & 0o077)) awg.fail('storage');
	let journal = json(fs.readfile(JOURNAL));
	let cmd = options.process_alive ? options.process_alive(journal.pid) : (fs.readfile('/proc/' + journal.pid + '/cmdline') || '');
	if (index(cmd, 'awg_rpc.uc') >= 0 || index(cmd, 'awg_cli.uc') >= 0) awg.fail('busy');
	return journal;
}
function recover(apply_runtime) {
	let journal;
	try { journal = recovery_needed(); }
	catch (e) { if (awg.error(e).code == 'busy') return false; die(e.message); }
	if (!journal) return false;
	if (journal.phase != 'committed') {
		restore(journal);
		if (apply_runtime) {
			let token = awg.nonce();
			journal.pid = options.pid || int(split(fs.readfile('/proc/self/stat') || '', ' ')[0]);
			if (!journal.pid) awg.fail('component');
			atomic(LOCK + '/connection-token', token);
			atomic(JOURNAL, sprintf('%J', journal));
			try { apply_runtime(token); }
			catch (e) { awg.fail('rollback_failed'); }
			journal.phase = 'committed'; atomic(JOURNAL, sprintf('%J', journal));
		}
	}
	remove_transaction(); return true;
}

function all(ctx) {
	let list = [];
	ctx.foreach('podkopchik', 'proxy', function(p) { push(list, p); });
	return list;
}
function awg_proxy(ctx, id, create) {
	let found = null, r = net.resources(id);
	ctx.foreach('podkopchik', 'proxy', function(p) {
		if (p.protocol == 'amneziawg' && p.awg_id == id) {
			if (found) awg.fail('conflict');
			found = p;
		}
	});
	if (!found && create) {
		let meta = db.run('profile', { id: id }).meta;
		let sid = r.tag;
		if (ctx.get('podkopchik', sid) != null) awg.fail('conflict');
		if (!ctx.set('podkopchik', sid, 'proxy')) awg.fail('storage');
		let fields = {
			protocol: 'amneziawg', awg_id: id, tag: r.tag, name: meta.name,
			enabled: '0', role: 'disabled', autostart: '0'
		};
		for (let key, value in fields) if (!ctx.set('podkopchik', sid, key, value)) awg.fail('storage');
		found = ctx.get_all('podkopchik', sid);
	}
	return found;
}
function shell(args) {
	if (options.shell) return options.shell(args);
	let words = [];
	for (let arg in args) push(words, "'" + replace('' + arg, "'", "'\\''") + "'");
	let err = TMP + '/connection-command-' + awg.nonce() + '.err';
	let f = fs.open(err, 'wx', 0o600);
	if (!f) awg.fail('storage');
	f.close();
	let p = fs.popen(join(' ', words) + " 2>'" + replace(err, "'", "'\\''") + "'", 'r');
	if (!p) { fs.unlink(err); awg.fail('apply_failed'); }
	let output = p.read('all'), rc = p.close();
	let is_apply = index(args, '/usr/bin/podkopchikctl') >= 0 && args[length(args) - 1] == 'apply';
	if (rc != 0 && is_apply) {
		// Keep bounded stderr root-only for SSH diagnostics. Never include the
		// command/token or raw error in RPC responses or public health state.
		try { atomic(TMP + '/connection-last-apply-error', fs.readfile(err, 4096) || 'Apply command failed\n'); }
		catch (ignored) { }
	}
	fs.unlink(err);
	if (rc != 0) awg.fail('apply_failed');
	return output;
}
function active_ref(tag) {
	let raw = fs.readfile(ACTIVE);
	if (!raw) return false;
	try {
		let cfg = json(raw);
		for (let out in cfg.outbounds || []) if (out.tag == tag) return true;
	} catch (e) { awg.fail('in_use'); }
	return false;
}
function runtime(id, action, persist) {
	let ctx = cursor(), p = awg_proxy(ctx, id, action == 'start' || action == 'restart');
	if (action == 'start' || action == 'restart') {
		let result = network.run(action, id);
		if (p && p.autostart != '1' && persist != false) {
			ctx.set('podkopchik', p['.name'], 'autostart', '1');
			if (!ctx.commit('podkopchik')) awg.fail('storage');
		}
		return result;
	}
	if (action == 'stop') {
		let result = network.run('stop', id);
		if (p && p.autostart != '0' && persist != false) {
			ctx.set('podkopchik', p['.name'], 'autostart', '0');
			if (!ctx.commit('podkopchik')) awg.fail('storage');
		}
		return result;
	}
	if (action != 'check') return network.run(action, id);
	let profile = db.run('profile', { id: id });
	let probe = {
		url: p?.probe_url || '',
		address: p?.probe_address || (index(profile.parsed.interface.Address || '', '.') < 0 ? '2606:4700:4700::1111' : '1.1.1.1'),
		timeout: p?.probe_timeout || ctx.get('podkopchik', 'main', 'timeout') || '10'
	};
	return network.run(action, id, probe);
}
function auto_group(ctx) {
	let mains = [], backups = [], seen = {}, internal = [];
	for (let p in all(ctx)) {
		if (p.enabled == '0') continue;
		if (p.role == 'main') push(mains, p.tag);
		if (p.role == 'backup') {
			let priority = int(p.backup_priority);
			if (priority < 1 || priority > 3 || seen[priority]) awg.fail('roles');
			seen[priority] = true; push(backups, { tag: p.tag, priority: priority });
		}
	}
	if (length(mains) != 1 || length(backups) > 3) awg.fail('roles');
	sort(backups, function(a, b) { return a.priority - b.priority; });
	ctx.foreach('podkopchik', 'proxy_group', function(g) { if (g.tag == 'auto_proxy_group') push(internal, g['.name']); });
	let sid = internal[0] || ctx.add('podkopchik', 'proxy_group');
	for (let i = 1; i < length(internal); i++) ctx.delete('podkopchik', internal[i]);
	for (let field, value in { enabled: '1', name: 'Automatic proxy group', tag: 'auto_proxy_group',
		mode: 'strict_primary', primary: mains[0], auto_return: '1', failure_action: 'switch_to_backup' })
		ctx.set('podkopchik', sid, field, value);
	for (let field in [ 'manual_override_proxy', 'fixed_proxy', 'backup1', 'backup2', 'backup3' ])
		ctx.delete('podkopchik', sid, field);
	for (let i = 0; i < length(backups); i++) ctx.set('podkopchik', sid, 'backup' + (i + 1), backups[i].tag);
}
let apply_changes;
function assign(tag, role, priority) {
	if (!match(tag || '', /^[a-zA-Z_][a-zA-Z0-9_]{0,47}$/) ||
		index([ 'main', 'backup', 'rules_only', 'disabled' ], role) < 0) awg.fail('roles');
	let ctx = cursor(), selected = null, temporary = null, measurement = null;
	try {
	if (match(tag, /^awg_[a-f0-9]{32}$/)) selected = awg_proxy(ctx, substr(tag, 4), true);
	else for (let p in all(ctx)) if (p.tag == tag) selected = p;
	if (!selected) awg.fail('missing');
	if (selected.protocol == 'amneziawg' && role != 'disabled') {
		let profile = db.run('profile', { id: selected.awg_id });
		if (index(profile.parsed.interface.Address || '', '.') < 0 &&
			ctx.get('podkopchik', 'main', 'extended_interception') != '1') awg.fail('ipv6_requires_extension');
	}
	if (role == 'main' || role == 'backup') {
		if (selected.protocol == 'amneziawg') {
			let was_running = network.run('status', selected.awg_id).running;
			if (!was_running) temporary = selected.awg_id;
			network.run('start', selected.awg_id);
			measurement = runtime(selected.awg_id, 'check');
			if (measurement.status != 'up') {
				if (!was_running) try { network.run('stop', selected.awg_id); } catch (ignored) { }
				awg.fail('unhealthy');
			}
		}
		else {
			// Probe just the candidate, including a disabled saved VLESS, through
			// the existing isolated checker. Never wait for every backup probe.
			let result = json(shell([ '/usr/libexec/podkopchik/connection_check.sh', 'tag', tag ]));
			if (!result || result.status != 'up' || time() - result.checked_at >= 300) awg.fail('unhealthy');
			measurement = result;
		}
	}
	// Refresh after start/check, which may have committed autostart.
	ctx = cursor();
	if (match(tag, /^awg_[a-f0-9]{32}$/)) selected = awg_proxy(ctx, substr(tag, 4), true);
	else for (let p in all(ctx)) if (p.tag == tag) selected = p;
	if (selected.protocol == 'amneziawg' && role != 'disabled')
		ctx.set('podkopchik', selected['.name'], 'autostart', '1');
	if (role == 'disabled') {
		for (let type in [ 'domain_rule', 'ip_rule', 'lan_device' ])
			ctx.foreach('podkopchik', type, function(r) {
				if (r.enabled != '0' && r.target == tag) awg.fail('in_use');
			});
	}
	if (role == 'main')
		for (let p in all(ctx)) if (p.tag != tag && p.role == 'main')
			ctx.set('podkopchik', p['.name'], 'role', 'rules_only');
	ctx.set('podkopchik', selected['.name'], 'role', role);
	ctx.set('podkopchik', selected['.name'], 'enabled', role == 'disabled' ? '0' : '1');
	if (role == 'disabled' && selected.protocol == 'amneziawg')
		ctx.set('podkopchik', selected['.name'], 'autostart', '0');
	if (role == 'backup') {
		if (!match(priority || '', /^[1-3]$/)) awg.fail('roles');
		ctx.set('podkopchik', selected['.name'], 'backup_priority', priority);
	}
	else ctx.delete('podkopchik', selected['.name'], 'backup_priority');
	auto_group(ctx);
	let result = apply_changes(ctx, role == 'main' ? tag : null, measurement ? { tag: tag, value: measurement } : null);
	return result;
	} catch (e) {
		if (temporary) try { network.run('stop', temporary); } catch (ignored) { }
		die(e.message);
	}
}
apply_changes = function(ctx, main_tag, measurement) {
	let old = fs.readfile(UCI_FILE);
	if (!old) awg.fail('storage');
	if (!fs.mkdir(LOCK)) awg.fail('busy');
	let token = awg.nonce(), journal = { phase: 'prepared', pid: options.pid || int(split(fs.readfile('/proc/self/stat') || '', ' ')[0]),
		uci: old, active: fs.readfile(ACTIVE), state: fs.readfile(TMP + '/state.json') };
	if (!journal.pid) { fs.rmdir(LOCK); awg.fail('component'); }
	try {
		atomic(LOCK + '/connection-token', token);
		if (fs.lstat(TMP + '/health-check.lock')) awg.fail('busy');
		atomic(JOURNAL, sprintf('%J', journal));
	}
	catch (e) { remove_transaction(); die(e.message); }
	try {
		if (!ctx.commit('podkopchik')) awg.fail('storage');
		if (main_tag || measurement) {
			let state = json(journal.state || '{}');
			if (!state.groups) state.groups = {};
			if (main_tag) state.groups.auto_proxy_group = { active_proxy: main_tag, reason: 'manual_selection', last_switch_time: time() };
			if (measurement) {
				if (!state.proxies) state.proxies = {};
				let result = measurement.value;
				state.proxies[measurement.tag] = { status: 'up', checked_at: result.checked_at,
					last_success_at: result.checked_at, fail_count: 0, success_count: 0, last_error: '',
					latency_ms: result.latency_ms, external_ip: result.external_ip || '' };
			}
			atomic(TMP + '/state.json', sprintf('%J', state));
		}
		shell([ 'env', 'PODKOPCHIK_CONNECTION_APPLY=' + token, '/usr/bin/podkopchikctl', 'apply' ]);
		journal.phase = 'committed'; atomic(JOURNAL, sprintf('%J', journal));
		remove_transaction();
	}
	catch (e) {
		restore(journal);
		try { shell([ 'env', 'PODKOPCHIK_CONNECTION_APPLY=' + token, '/usr/bin/podkopchikctl', 'apply' ]); }
		catch (ignored) { awg.fail('rollback_failed'); }
		remove_transaction();
		awg.fail('apply_failed');
	}
	return {};
};
function list() {
	let result = db.run('list', {}), ctx = cursor(), connections = [];
	let health = json(fs.readfile(TMP + '/state.json') || '{}');
	let traffic = {};
	if (options.traffic) traffic = options.traffic();
	else {
		// Fixed command, selected binary owned by Podkopchik/OpenWrt. A missing
		// API is "unavailable", never fabricated zero-byte measurements.
		let p = fs.popen('. /usr/libexec/podkopchik/xray.sh; bin="$(xray_bin)"; [ -n "$bin" ] && "$bin" api statsquery --server=127.0.0.1:10085 --timeout=2 2>/dev/null', 'r');
		if (p) {
			let raw = p.read('all'), rc = p.close();
			if (rc == 0) try {
				for (let stat in json(raw).stat || []) {
					let parsed = match(stat.name, /^outbound>>>([a-z0-9_]+)>>>traffic>>>(uplink|downlink)$/);
					if (!parsed) continue;
					if (!traffic[parsed[1]]) traffic[parsed[1]] = {};
					traffic[parsed[1]][parsed[2]] = +stat.value;
				}
			} catch (e) { }
		}
	}
	for (let item in result.connections) {
		let p = awg_proxy(ctx, item.id, false);
		item.tag = net.resources(item.id).tag;
		item.role = p?.role || 'disabled'; item.priority = p?.backup_priority || '';
		item.probe = { url: p?.probe_url || '', address: p?.probe_address || '', timeout: p?.probe_timeout || '' };
		try { item.runtime = runtime(item.id, 'status'); }
		catch (e) { item.runtime = { status: 'unknown', reason: awg.error(e).code }; }
	}
	for (let p in all(ctx))
		push(connections, { tag: p.tag, name: p.name || p.tag, protocol: p.protocol || 'vless',
			role: p.role || (p.enabled == '0' ? 'disabled' : 'backup'), priority: p.backup_priority || '',
			health: health.proxies?.[p.tag] || { status: 'unknown' }, traffic: traffic[p.tag] || null });
	result.routing_connections = connections;
	result.extended_interception = ctx.get('podkopchik', 'main', 'extended_interception') == '1';
	return result;
}
function run(method, args) {
	fs.mkdir(TMP);
	let parent = fs.lstat(TMP);
	if (!parent || parent.type != 'directory' || parent.uid != OWNER || (parent.mode & 0o022)) awg.fail('storage');
	if (method != 'list' && fs.lstat(TMP + '/xray-update.lock')) awg.fail('busy');
	if (method != 'recover' && recovery_needed()) awg.fail('recovery_required');
	// Separate role/store operations from interface operations. Never hold the
	// interface lock while invoking apply, which reconciles interfaces itself.
	let lock = fs.open(TMP + '/awg-management.lock', 'a+', 0o600);
	if (!lock || !lock.lock('xn')) awg.fail('busy');
	try {
		let result;
		if (method == 'recover') {
			recover(function(token) { shell([ 'env', 'PODKOPCHIK_CONNECTION_APPLY=' + token, '/usr/bin/podkopchikctl', 'apply' ]); });
			result = {};
		}
		else if (method == 'list') result = list();
		else if (method == 'set_interception') {
			if (args.enabled != '0' && args.enabled != '1') awg.fail('request');
			let ctx = cursor();
			if (args.enabled == '0')
				for (let p in all(ctx)) if (p.protocol == 'amneziawg' && p.enabled != '0') {
					let profile = db.run('profile', { id: p.awg_id });
					if (index(profile.parsed.interface.Address || '', '.') < 0) awg.fail('ipv6_requires_extension');
				}
			ctx.set('podkopchik', 'main', 'extended_interception', args.enabled);
			result = apply_changes(ctx, null);
		}
		else if (method == 'assign') result = assign(args.tag, args.role, args.priority);
		else if (method == 'set_probe') {
			let settings = net.probe_settings(args), ctx = cursor(), p = awg_proxy(ctx, args.id, true);
			ctx.set('podkopchik', p['.name'], 'probe_url', settings.url);
			ctx.set('podkopchik', p['.name'], 'probe_address', settings.address);
			ctx.set('podkopchik', p['.name'], 'probe_timeout', settings.timeout);
			if (!ctx.commit('podkopchik')) awg.fail('storage');
			result = {};
		}
		else if (index([ 'start', 'stop', 'restart', 'check' ], method) >= 0) {
			result = { runtime: runtime(args.id, method) };
			if (method != 'check' && active_ref(net.resources(args.id).tag)) shell([ '/usr/bin/podkopchikctl', 'apply' ]);
		}
		else {
			if (method == 'delete' || method == 'replace') {
				let ctx = cursor(), p = awg_proxy(ctx, args.id, false);
				if (p && (p.enabled != '0' || active_ref(p.tag))) awg.fail('in_use');
				let current = runtime(args.id, 'status');
				if (current.running) awg.fail('in_use');
				if (method == 'delete') {
					network.run('remove', args.id);
					if (p) { ctx.delete('podkopchik', p['.name']); if (!ctx.commit('podkopchik')) awg.fail('storage'); }
				}
			}
			result = db.run(method, args);
			if ((method == 'rename' || method == 'replace') && result.connection) {
				let ctx = cursor(), p = awg_proxy(ctx, args.id, false);
				if (p) {
					if (!ctx.set('podkopchik', p['.name'], 'name', result.connection.name) || !ctx.commit('podkopchik')) awg.fail('storage');
				}
			}
		}
		lock.close(); return result;
	} catch (e) { lock.close(); die(e.message); }
}

return { run: run, runtime: runtime, recover: recover };
}
let instance = create();
instance.create = create;
return instance;
