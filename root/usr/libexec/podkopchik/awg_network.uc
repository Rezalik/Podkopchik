'use strict';

import * as fs from 'fs';
const awg = require('awg');

// Audited against AX6000's rules (local/10991/main/default). Every start still
// checks the live namespace. Never take over a matching foreign table/device.
function resources(id) {
	if (!match(id || '', /^[a-f0-9]{32}$/)) awg.fail('id');
	let slot = hex(substr(id, 0, 4)) % 8192;
	return { id: id, tag: 'awg_' + id, interface: 'paw' + substr(id, 0, 12),
		table: 42000 + slot, priority: 20000 + slot, mark: 536870912 + 42000 + slot,
		alias: 'podkopchik-awg:' + id };
}

function quote(value) { return "'" + replace('' + value, "'", "'\\''") + "'"; }
function unreachable(route) { return route.type == 'unreachable' || +route.type == 7; }

function outbound(r, usable, addresses) {
	if (!usable) return { tag: r.tag, protocol: 'blackhole' };
	return { tag: r.tag, protocol: 'freedom', streamSettings: {
		sockopt: { interface: r.interface, mark: r.mark, domainStrategy:
			addresses && index(addresses, '.') < 0 ? 'ForceIPv6' :
			addresses && index(addresses, ':') < 0 ? 'ForceIPv4' : 'ForceIP' }
	} };
}

function block_active(config) {
	for (let out in config.outbounds || [])
		if (out.protocol == 'freedom' && match(out.tag || '', /^awg_[a-f0-9]{32}$/)) {
			delete out.streamSettings; delete out.settings; out.protocol = 'blackhole';
		}
	return config;
}

function probe_settings(value) {
	value = value || {};
	let url = value.url || 'https://one.one.one.one/cdn-cgi/trace';
	let m = match(url, /^https:\/\/([^/]+)(\/[A-Za-z0-9/?&=_.%+-]*)?$/);
	let address = value.address || '1.1.1.1', timeout = '' + (value.timeout || '10');
	if (!m || !awg.domain(m[1]) || !awg.ip(address) || !match(timeout, /^[0-9]+$/) || +timeout < 1 || +timeout > 30)
		awg.fail('probe_settings');
	return { url: url, host: m[1], address: address, timeout: timeout };
}

function execute(args) {
	// iproute2 otherwise renders protocol 186 as "bgp" (or a local alias),
	// making numeric ownership checks depend on /etc/iproute2/rt_protos.
	if (args[0] == 'ip' && index(args, '-j') >= 0) args = [ 'ip', '-N', ...slice(args, 1) ];
	let command = [];
	for (let arg in args) push(command, quote(arg));
	// Commands and values are generated/allowlisted; private values go only
	// through a root-only setconf file, never argv, logs or shell evaluation.
	let p = fs.popen(join(' ', command) + ' 2>/dev/null', 'r');
	if (!p) awg.fail('component');
	let out = p.read('all'), rc = p.close();
	if (rc != 0) awg.fail('network');
	return out;
}

function controller(options) {
	options = options || {};
	const root = options.root || '/tmp/podkopchik/awg';
	const store = options.store || awg.store('/etc/podkopchik/awg', 0);
	const run = options.run || execute;
	const now = options.now || time;
	function file(id) { return root + '/' + resources(id).id + '.json'; }
	function state(id) {
		let s = fs.lstat(file(id));
		if (!s) return null;
		if (s.type != 'file' || s.uid != (options.owner || 0) || (s.mode & 0o077)) awg.fail('storage');
		let value = json(fs.readfile(file(id)));
		let r = resources(id);
		if (value.id != id || value.interface != r.interface || +value.table != r.table || +value.mark != r.mark)
			awg.fail('storage');
		return value;
	}
	function save(id, value) {
		let tmp = file(id) + '.new';
		fs.unlink(tmp);
		let f = fs.open(tmp, 'wx', 0o600), text = sprintf('%J', value);
		if (!f) awg.fail('storage');
		let wrote = f.write(text), flushed = f.flush(), closed = f.close();
		if (wrote != length(text) || !flushed || !closed || !fs.rename(tmp, file(id))) {
			fs.unlink(tmp); awg.fail('storage');
		}
	}
	function device(r, pending_index) {
		let links = json(run([ 'ip', '-d', '-j', 'link', 'show' ]));
		for (let link in links)
			if (link.ifname == r.interface) {
				if (link.linkinfo?.info_kind != 'amneziawg' ||
					(link.ifalias != r.alias && !(pending_index && +link.ifindex == +pending_index && !link.ifalias))) awg.fail('conflict');
				return link;
			}
		return null;
	}
	function rules(r, family, owned) {
		let list = json(run([ 'ip', family, '-j', 'rule', 'show' ]));
		for (let rule in list) {
			let mark = type(rule.fwmark) == 'string' ? hex(replace(rule.fwmark, '0x', '')) : (rule.fwmark || 0);
			let mask = rule.fwmask == null ? 4294967295 :
				(type(rule.fwmask) == 'string' ? hex(replace(rule.fwmask, '0x', '')) : rule.fwmask);
			let match_mark = rule.fwmark != null && (mark & mask) == (r.mark & mask);
			if (+rule.priority == r.priority || match_mark || rule.oif == r.interface) {
				for (let key in keys(rule))
					if (index([ 'priority', 'src', 'fwmark', 'fwmask', 'oif', 'oif_detached', 'table', 'protocol' ], key) < 0) awg.fail('conflict');
				if (!owned || +rule.priority != r.priority || +rule.table != r.table || +rule.protocol != 186 ||
					(rule.src && rule.src != 'all') ||
					!((mark == r.mark && mask == 4294967295 && !rule.oif) ||
					(rule.oif == r.interface && rule.fwmark == null))) awg.fail('conflict');
			}
		}
	}
	function routes(r, family, owned) {
		// "table all" succeeds even when the private table does not exist.
		let list = json(run([ 'ip', family, '-j', 'route', 'show', 'table', 'all' ]));
		for (let route in list)
			if (+route.table == r.table) {
				if (!owned || +route.protocol != 186 ||
					!((unreachable(route) && (!route.dst || route.dst == 'default') && +route.metric == 42760) ||
					(route.dev == r.interface && +route.metric == 100))) awg.fail('conflict');
			}
	}
	function inspect(r, owned, pending_index) {
		device(r, pending_index);
		for (let family in [ '-4', '-6' ]) { rules(r, family, owned); routes(r, family, owned); }
	}
	function guard(r) {
		// These terminal routes must survive stop/removal of the interface.
		// Otherwise a failed bind/empty lookup could fall through to WAN.
		for (let family in [ '-4', '-6' ]) {
			run([ 'ip', family, 'route', 'replace', 'unreachable', 'default', 'metric', '42760', 'proto', '186', 'table', r.table ]);
			let existing = json(run([ 'ip', family, '-j', 'rule', 'show' ])), have_mark = false, have_oif = false;
			for (let rule in existing) if (+rule.priority == r.priority) {
				if (rule.fwmark != null) have_mark = true;
				if (rule.oif == r.interface) have_oif = true;
			}
			if (!have_mark) run([ 'ip', family, 'rule', 'add', 'priority', r.priority, 'fwmark', r.mark, 'table', r.table, 'protocol', '186' ]);
			if (!have_oif) run([ 'ip', family, 'rule', 'add', 'priority', r.priority, 'oif', r.interface, 'table', r.table, 'protocol', '186' ]);
		}
	}
	function guarded(r) {
		for (let family in [ '-4', '-6' ]) {
			let mark = false, oif = false, terminal = false;
			for (let rule in json(run([ 'ip', family, '-j', 'rule', 'show' ]))) {
				if (+rule.priority != r.priority || +rule.table != r.table || +rule.protocol != 186) continue;
				if (rule.fwmark != null) mark = true;
				if (rule.oif == r.interface) oif = true;
			}
			for (let route in json(run([ 'ip', family, '-j', 'route', 'show', 'table', 'all' ])))
				if (+route.table == r.table && +route.protocol == 186 && unreachable(route) &&
					(!route.dst || route.dst == 'default') && +route.metric == 42760) terminal = true;
			if (!mark || !oif || !terminal) return false;
		}
		return true;
	}
	function stop(id, remove_guard) {
		let r = resources(id), previous = state(id);
		if (!previous) {
			if (device(r)) awg.fail('conflict');
			return { running: false, guarded: false };
		}
		inspect(r, true, previous.created_index);
		if (device(r, previous.created_index)) run([ 'ip', 'link', 'delete', 'dev', r.interface ]);
		// Kernel removes interface routes. Delete only exact terminal routes and
		// exact rules after the caller proves no active Xray reference remains.
		if (remove_guard) {
			for (let family in [ '-4', '-6' ]) {
				for (let rule in json(run([ 'ip', family, '-j', 'rule', 'show' ])))
					if (+rule.priority == r.priority && +rule.table == r.table) {
						if (rule.fwmark != null) run([ 'ip', family, 'rule', 'del', 'priority', r.priority, 'fwmark', r.mark, 'table', r.table, 'protocol', '186' ]);
						else run([ 'ip', family, 'rule', 'del', 'priority', r.priority, 'oif', r.interface, 'table', r.table, 'protocol', '186' ]);
					}
				for (let route in json(run([ 'ip', family, '-j', 'route', 'show', 'table', 'all' ])))
					if (+route.table == r.table && unreachable(route) && +route.protocol == 186 && +route.metric == 42760)
						run([ 'ip', family, 'route', 'del', 'unreachable', 'default', 'metric', '42760', 'proto', '186', 'table', r.table ]);
			}
			for (let suffix in [ '.json', '.check.json', '.setconf', '.https' ]) fs.unlink(root + '/' + id + suffix);
			return { running: false, guarded: false };
		}
		guard(r);
		previous.running = false; previous.guarded = true; previous.status = 'down';
		previous.reason = 'stopped'; previous.updated_at = now(); save(id, previous);
		return previous;
	}
	function start(id) {
		let r = resources(id), profile = store.run('profile', { id: id }), old = state(id);
		let live = device(r, old?.created_index);
		if (old && old.running && live && index(live.flags || [], 'UP') >= 0 &&
			old.revision == profile.meta.revision) {
			inspect(r, true);
			if (!guarded(r)) guard(r);
			return old;
		}
		if (old && live) stop(id, false);
		inspect(r, !!old);
		let count = 0;
		for (let link in json(run([ 'ip', '-d', '-j', 'link', 'show' ])))
			if (link.linkinfo?.info_kind == 'amneziawg' && match(link.ifalias || '', /^podkopchik-awg:[a-f0-9]{32}$/)) count++;
		if (count >= 10) awg.fail('limit');
		if (!match(run([ 'awg', '--version' ]), /v3\.1\./)) awg.fail('component');
		if (trim(run([ 'sysctl', '-n', 'net.ipv4.conf.all.rp_filter' ])) != '0') awg.fail('rpf');
		run([ 'modprobe', 'amneziawg' ]);
		let iface = profile.parsed.interface;
		if (!iface.Address) awg.fail('address');
		// Reject prefixes that intersect LAN/WAN/another tunnel before assigning
		// any local IP. noprefixroute alone does not prevent duplicate addresses.
		for (let link in json(run([ 'ip', '-j', 'address', 'show' ])))
			if (link.ifname != r.interface)
				for (let address in link.addr_info || [])
					for (let requested in split(iface.Address, ','))
						if (awg.overlap(trim(requested), address.local + '/' + address.prefixlen)) awg.fail('address_conflict');
		let plan = { id: id, revision: profile.meta.revision, interface: r.interface, table: r.table, mark: r.mark, addresses: iface.Address,
			running: false, guarded: true, status: 'unknown', reason: 'not_checked', updated_at: now() };
		// Persist ownership before the first mutation, so an interrupted start
		// can be reconciled. A second inspect under the global lock is mandatory.
		save(id, plan);
		let config_path = root + '/' + id + '.setconf';
		try {
			// A killed setconf operation may leave its private temporary file. The
			// global lock and validated ownership record make this exact path safe.
			let stale = fs.lstat(config_path);
			if (stale && (stale.type != 'file' || stale.uid != (options.owner || 0) || (stale.mode & 0o077))) awg.fail('storage');
			if (stale) fs.unlink(config_path);
			guard(r);
			run([ 'ip', 'link', 'add', 'dev', r.interface, 'type', 'amneziawg' ]);
			for (let link in json(run([ 'ip', '-d', '-j', 'link', 'show' ])))
				if (link.ifname == r.interface && link.linkinfo?.info_kind == 'amneziawg') plan.created_index = link.ifindex;
			if (!plan.created_index) awg.fail('network');
			save(id, plan);
			// The AWG newlink implementation on the tested kernel discards an
			// alias supplied with "link add". Set and verify it separately.
			run([ 'ip', 'link', 'set', 'dev', r.interface, 'alias', r.alias ]);
			if (!device(r)) awg.fail('conflict');
			let lines = [];
			for (let line in split(profile.parsed.config, '\n')) {
				let field = trim(split(line, '=', 2)[0]);
				if (index([ 'Address', 'DNS', 'MTU', 'FwMark' ], field) < 0) push(lines, line);
			}
			let f = fs.open(config_path, 'wx', 0o600);
			if (!f) awg.fail('storage');
			let text = join('\n', lines), wrote = f.write(text), flushed = f.flush(), closed = f.close();
			if (wrote != length(text) || !flushed || !closed) awg.fail('storage');
			run([ 'awg', 'setconf', r.interface, config_path ]);
			fs.unlink(config_path);
			run([ 'awg', 'set', r.interface, 'fwmark', '0' ]);
			run([ 'ip', 'link', 'set', 'dev', r.interface, 'addrgenmode', 'none' ]);
			run([ 'ip', 'link', 'set', 'dev', r.interface, 'mtu', iface.MTU || '1280' ]);
			// noprefixroute prevents connected routes appearing in main.
			for (let address in split(iface.Address, ','))
				run([ 'ip', index(address, ':') >= 0 ? '-6' : '-4', 'address', 'add', trim(address),
					'dev', r.interface, 'noprefixroute' ]);
			run([ 'ip', 'link', 'set', 'dev', r.interface, 'up' ]);
			let seen = {};
			for (let peer in profile.parsed.peers)
				for (let value in split(peer.AllowedIPs, ',')) {
					let cidr = trim(value);
					if (seen[cidr]) continue;
					seen[cidr] = true;
					run([ 'ip', index(cidr, ':') >= 0 ? '-6' : '-4', 'route', 'add', cidr,
						'dev', r.interface, 'metric', '100', 'proto', '186', 'table', r.table ]);
				}
			plan.running = true; plan.reason = 'not_checked'; save(id, plan);
			return plan;
		}
		catch (e) {
			fs.unlink(config_path);
			try { stop(id, false); } catch (ignored) { }
			awg.fail('network');
		}
	}
	function park(id) {
		let r = resources(id), old = state(id);
		if (old) return stop(id, false);
		inspect(r, false);
		let value = { id: id, interface: r.interface, mark: r.mark, table: r.table,
			running: false, guarded: false, status: 'down', reason: 'stopped', updated_at: now() };
		save(id, value);
		guard(r);
		value.guarded = true; save(id, value); return value;
	}
	function status(id) {
		let r = resources(id), value = state(id);
		if (!value) {
			let raw = fs.readfile(root + '/' + id + '.check.json');
			if (raw) {
				let cached = json(raw);
				cached.running = false; cached.guarded = false;
				cached.status = now() - cached.checked_at < 300 ? 'down' : 'unknown';
				return cached;
			}
			return { running: false, status: 'unknown', reason: 'stopped', guarded: false };
		}
		let link = device(r);
		value.running = !!link && index(link.flags || [], 'UP') >= 0;
		if (!value.running) { value.status = 'down'; value.reason = 'stopped'; return value; }
		inspect(r, true);
		value.guarded = guarded(r);
		if (!value.guarded) { value.status = 'down'; value.reason = 'conflict'; return value; }
		let assigned = [];
		for (let link in json(run([ 'ip', '-j', 'address', 'show' ])))
			if (link.ifname == r.interface) assigned = link.addr_info || [];
		value.addresses_assigned = true;
		for (let requested in split(value.addresses || '', ',')) {
			let pieces = split(trim(requested), '/'), bits = index(pieces[0], ':') >= 0 ? 128 : 32, found = false;
			for (let address in assigned)
				if (+pieces[1] == +address.prefixlen && awg.overlap(pieces[0] + '/' + bits, address.local + '/' + bits)) found = true;
			if (!found) value.addresses_assigned = false;
		}
		if (!value.addresses_assigned) { value.status = 'down'; value.reason = 'address_missing'; return value; }
		let handshake = 0, rx = 0, tx = 0;
		for (let line in split(run([ 'awg', 'show', r.interface, 'latest-handshakes' ]), '\n')) {
			let cols = split(trim(line), /[ \t]+/);
			if (length(cols) == 2 && +cols[1] > handshake) handshake = +cols[1];
		}
		for (let line in split(run([ 'awg', 'show', r.interface, 'transfer' ]), '\n')) {
			let cols = split(trim(line), /[ \t]+/);
			if (length(cols) == 3) { rx += +cols[1]; tx += +cols[2]; }
		}
		value.handshake_at = handshake; value.handshake_age = handshake ? now() - handshake : null;
		value.rx_bytes = rx; value.tx_bytes = tx;
		if (!value.checked_at || now() - value.checked_at >= 300 || !handshake ||
			value.handshake_age < 0) value.status = 'unknown';
		return value;
	}
	function check(id, probe, persist) {
		let r = resources(id), value = status(id);
		if (!value.running || !value.guarded || !value.addresses_assigned) {
			value.status = 'down'; value.reason = !value.running ? 'stopped' : (!value.guarded ? 'conflict' : 'address_missing');
			value.checked_at = now(); value.valid_for = 300;
			return value;
		}
		let body = root + '/' + id + '.https', external = '', elapsed = null, ok = false;
		probe = probe_settings(probe || { address: index(value.addresses || '', '.') < 0 ? '2606:4700:4700::1111' : '1.1.1.1' });
		// Literal --resolve bypasses OS DNS. oif rule + terminal routes guarantee
		// this check cannot accidentally succeed through the router WAN.
		try {
			let ipv6_only = index(probe.address, ':') >= 0;
			let out = run([ 'curl', ipv6_only ? '-6' : '-4', '--noproxy', '*', '--proto', '=https', '-fsS',
				'--connect-timeout', probe.timeout, '--max-time', probe.timeout, '--max-filesize', '4096',
				'--interface', 'if!' + r.interface, '--resolve',
				probe.host + ':443:' + (ipv6_only ? '[' + probe.address + ']' : probe.address),
				probe.url, '-w', '%{time_total}', '-o', body ]);
			if (match(trim(out), /^[0-9]+(\.[0-9]+)?$/)) elapsed = int(+trim(out) * 1000);
			for (let line in split(fs.readfile(body, 4097) || '', '\n'))
				if (substr(line, 0, 3) == 'ip=' && awg.ip(substr(line, 3))) external = substr(line, 3);
			value = status(id);
			// A verified HTTPS response bound to this interface is the live test;
			// AWG 3.1 profiles can legitimately customize handshake timers.
			ok = elapsed != null && value.handshake_at > 0 && value.handshake_age >= 0;
		} catch (e) { }
		fs.unlink(body);
		value.checked_at = now(); value.valid_for = 300;
		value.status = ok ? 'up' : 'down'; value.reason = ok ? '' : 'https_or_handshake';
		value.latency_ms = ok ? elapsed : null; value.external_ip = ok ? external : '';
		if (ok) value.last_success_at = now();
		if (persist != false) save(id, value);
		return value;
	}
	function locked(method, id, probe) {
		// /tmp/podkopchik is installed root-only by the service; reject symlinks.
		let parent = fs.lstat(fs.dirname(root));
		if (!parent || parent.type != 'directory' || parent.uid != (options.owner || 0) || (parent.mode & 0o022)) awg.fail('storage');
		if (!fs.lstat(root)) {
			let tmp = fs.mkdtemp(fs.dirname(root) + '/.awg-XXXXXX');
			if (!tmp || !fs.rename(tmp, root)) awg.fail('storage');
		}
		let s = fs.lstat(root);
		if (s.type != 'directory' || s.uid != (options.owner || 0) || (s.mode & 0o077)) awg.fail('storage');
		let lock = fs.open(root + '/.lock', 'a+', 0o600);
		if (!lock || !lock.lock('xn')) awg.fail('busy');
		try {
			let result;
			if (method == 'start') result = start(id);
			else if (method == 'park') result = park(id);
			else if (method == 'stop') result = stop(id, false);
			else if (method == 'remove') result = stop(id, true);
			else if (method == 'restart') { stop(id, false); result = start(id); }
			else if (method == 'check') {
				result = check(id, probe);
				// A diagnostic record is not an ownership record.
				let f = fs.open(root + '/' + resources(id).id + '.check.json', 'w', 0o600);
				if (!f) awg.fail('storage');
				f.write(sprintf('%J', result)); f.close();
			}
			else if (method == 'status') result = status(id);
			else if (method == 'check_ipv6') {
				if (!require('interception').profile_ipv6(store.run('profile', { id: id }).parsed)) awg.fail('ipv6_unsupported');
				let live = status(id), route = false;
				for (let item in json(run([ 'ip', '-6', '-j', 'route', 'show', 'table', 'all' ])))
					if (+item.table == resources(id).table && item.dev == resources(id).interface &&
						(item.dst == 'default' || item.dst == '::/0') && +item.protocol == 186 && +item.metric == 100 && !unreachable(item)) route = true;
				if (!live.running || !live.addresses_assigned || !route) awg.fail('ipv6_route');
				result = check(id, { address: '2606:4700:4700::1111' }, false);
			}
			else awg.fail('request');
			lock.close(); return result;
		} catch (e) { lock.close(); die(e.message); }
	}
	return { run: locked };
}

return { resources: resources, controller: controller, outbound: outbound, block_active: block_active, probe_settings: probe_settings };
