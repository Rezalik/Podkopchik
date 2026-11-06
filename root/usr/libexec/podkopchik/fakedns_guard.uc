'use strict';

import * as fs from 'fs';
const awg = require('awg');
const TABLE = 'podkopchik_fake_guard';
const OWNER = 'podkopchik-fakedns-guard-v1';
// After the transparent local route, before every AWG policy table and main.
const PRIORITY = 10992;
const PROTOCOL = 187;

function valid_cidr(value, required) {
	if (type(value) != 'string') return false;
	let p = split(value, '/');
	return length(p) <= 2 && awg.ip(p[0]) && (length(p) == 1 ? !required :
		match(p[1], /^[0-9]{1,3}$/) && +p[1] <= (index(p[0], ':') < 0 ? 32 : 128));
}

function address_bytes(ip) {
	if (index(ip, ':') < 0) return map(split(ip, '.'), n => +n);
	if (index(ip, '.') >= 0) {
		let cut = rindex(ip, ':'), a = address_bytes(substr(ip, cut + 1));
		ip = substr(ip, 0, cut + 1) + sprintf('%x:%x', a[0] * 256 + a[1], a[2] * 256 + a[3]);
	}
	let sides = split(ip, '::'), left = sides[0] ? split(sides[0], ':') : [], right = sides[1] ? split(sides[1], ':') : [];
	if (length(sides) == 2) while (length(left) + length(right) < 8) push(left, '0');
	let bytes = [];
	for (let word in [...left, ...right]) { let n = hex(word); push(bytes, n >> 8, n & 255); }
	return bytes;
}

function canonical(value) {
	if (!valid_cidr(value, true)) die('invalid FakeDNS CIDR');
	let p = split(value, '/'), bytes = address_bytes(p[0]), bits = +p[1];
	if (!bits) die('a default route cannot be a FakeDNS pool');
	for (let i = 0; i < length(bytes); i++) {
		let n = min(8, max(0, bits - i * 8));
		bytes[i] &= n ? (255 << (8 - n)) & 255 : 0;
	}
	if (length(bytes) == 4) return join('.', bytes) + '/' + bits;
	let words = [];
	for (let i = 0; i < 16; i += 2) push(words, sprintf('%x', bytes[i] * 256 + bytes[i + 1]));
	return join(':', words) + '/' + bits;
}

function pools(config) {
	let raw = config?.fakedns;
	if (raw == null) return [];
	let list = type(raw) == 'array' ? raw : [raw], out = [];
	if (!length(list) || length(list) > 16) die('invalid FakeDNS pool list');
	for (let item in list) {
		let p = canonical(item?.ipPool);
		if (index(out, p) < 0) push(out, p);
	}
	return out;
}

function state(value) {
	if (!value || value.schema != 1 || type(value.pools) != 'array' || type(value.lans) != 'array' ||
		length(value.pools) > 16 || length(value.lans) > 8) die('invalid FakeDNS guard state');
	let out = { schema: 1, pools: [], lans: [], native_pools: [] };
	for (let entry in value.pools) {
		let p = canonical(entry);
		if (index(out.pools, p) < 0) push(out.pools, p);
	}
	for (let lan in value.lans) {
		if (!match(lan || '', /^[A-Za-z0-9_.-]{1,15}$/)) die('invalid FakeDNS guard LAN interface');
		if (index(out.lans, lan) < 0) push(out.lans, lan);
	}
	let native = value.native_pools ?? [];
	if (type(native) != 'array' || length(native) > 16) die('invalid native quarantine pool list');
	for (let entry in native) {
		let p = canonical(entry);
		if (index(out.pools, p) < 0) die('native quarantine pool is missing from the ledger');
		if (index(out.native_pools, p) < 0) push(out.native_pools, p);
	}
	return out;
}

function desired(previous, configs, lans, native) {
	let next = state(previous);
	function admit(p, is_native) {
		for (let used in next.pools) if ((index(next.native_pools, used) >= 0) != is_native && awg.overlap(p, used))
			die('legacy and native synthetic pools overlap');
		if (index(next.pools, p) < 0) push(next.pools, p);
		if (is_native && index(next.native_pools, p) < 0) push(next.native_pools, p);
	}
	for (let c in configs) for (let p in pools(c)) admit(p, false);
	if (native != null) for (let p in type(native) == 'array' ? native : [native])
		admit(canonical(p), true);
	if (length(next.pools)) for (let lan in lans) if (index(next.lans, lan) < 0) push(next.lans, lan);
	return state(next);
}

function check_conflicts(pools, addresses, routes, exclusions) {
	let used = ['0.0.0.0/8', '127.0.0.0/8', '169.254.0.0/16', '224.0.0.0/4', '240.0.0.0/4',
		'::/128', '::1/128', 'fe80::/10', 'ff00::/8'];
	for (let link in addresses) for (let a in link.addr_info || [])
		if (a.local && a.prefixlen != null) push(used, a.local + '/' + a.prefixlen);
	for (let r in routes) {
		if (r.dst && r.dst != 'default' && r.dst != '0.0.0.0/0' && r.dst != '::/0') push(used, r.dst);
		if (r.gateway) push(used, r.gateway);
		if (r.prefsrc) push(used, r.prefsrc);
		for (let nh in r.nexthops || []) if (nh.gateway) push(used, nh.gateway);
	}
	for (let x in exclusions) push(used, x);
	for (let p in pools) for (let x in used) {
		if (!valid_cidr(x, false)) continue;
		if (index(x, '/') < 0) x += index(x, ':') >= 0 ? '/128' : '/32';
		if (awg.overlap(p, x)) die('FakeDNS pool overlaps a real local network, route, or explicit exclusion');
	}
}

function rule_pool(rule, family) {
	if (+rule.priority != PRIORITY) return null;
	for (let key in keys(rule)) if (index(['priority', 'src', 'dst', 'dstlen', 'action', 'protocol'], key) < 0)
		die('foreign rule at FakeDNS guard priority');
	if ((rule.src && rule.src != 'all') || (rule.action != 'blackhole' && +rule.action != 6) ||
		+rule.protocol != PROTOCOL || !rule.dst) die('foreign rule at FakeDNS guard priority');
	let p = canonical(rule.dst + (index(rule.dst, '/') >= 0 ? '' : '/' + (rule.dstlen || (family == '-4' ? 32 : 128))));
	if ((index(p, ':') >= 0) != (family == '-6')) die('invalid FakeDNS policy family');
	return p;
}

function batch(value, replace_existing) {
	let s = state(value), lines = [];
	if (replace_existing) push(lines, 'delete table inet ' + TABLE);
	push(lines, 'add table inet ' + TABLE + ' { comment "' + OWNER + '"; }');
	let allowed = ['lo', ...filter(s.lans, x => x != 'lo')];
	let interfaces = join(', ', map(allowed, x => '"' + x + '"'));
	// OUTPUT is after conntrack and destination NAT; FORWARD is after
	// prerouting DNAT and before SNAT. POSTROUTING sees the final addresses.
	let priorities = { output: -90, forward: -200, postrouting: 300 };
	for (let hook, priority in priorities)
		push(lines, 'add chain inet ' + TABLE + ' ' + hook + ' { type filter hook ' + hook +
			' priority ' + priority + '; policy accept; }');
	if (length(s.native_pools)) {
		push(lines, 'add chain inet ' + TABLE + ' native_original');
		// Positive match plus unconditional drop: interfaces without a link
		// kind must not accidentally pass a negated oifkind comparison.
		push(lines, 'add rule inet ' + TABLE + ' native_original ct status dnat meta oifkind "amneziawg" return');
		push(lines, 'add rule inet ' + TABLE + ' native_original counter drop');
	}
	for (let family in ['4', '6']) {
		let v6 = family == '6', proto = v6 ? 'ip6' : 'ip', name = 'fake' + family;
		let list = filter(s.pools, p => (index(p, ':') >= 0) == v6);
		if (!length(list)) continue;
		function add_set(name, entries) {
			if (!length(entries)) return false;
			push(lines, 'add set inet ' + TABLE + ' ' + name + ' { type ipv' + family + '_addr; flags interval; auto-merge; }');
			push(lines, 'add element inet ' + TABLE + ' ' + name + ' { ' + join(', ', entries) + ' }');
			return true;
		}
		add_set(name, list);
		let legacy = add_set('legacy' + family, filter(list, p => index(s.native_pools, p) < 0));
		let native = add_set('native' + family, filter(list, p => index(s.native_pools, p) >= 0));
		for (let hook in ['output', 'forward', 'postrouting']) {
			let base = 'add rule inet ' + TABLE + ' ' + hook + ' ' + proto;
			push(lines, base + ' daddr @' + name + ' counter drop');
			// Reverse DNAT restores a fake source only at postrouting. The
			// scoped client's dedicated veth is not a permanent LAN; its
			// own later hook still checks lease and classifier liveness.
			if (!v6 && native && hook == 'postrouting' && index(s.native_pools, '172.31.253.0/24') >= 0)
				push(lines, base + ' saddr 172.31.253.0/24 ip daddr 172.31.252.2 ' +
					'oifname "pv*" meta oifkind "veth" ct direction reply ct status dnat ct mark 0x504b0901 ' +
					'ct original ip saddr 172.31.252.2 ct original ip daddr @native4 counter return');
			push(lines, base + ' saddr @' + name + ' oifname != { ' + interfaces + ' } counter drop');
			let original = 'add rule inet ' + TABLE + ' ' + hook + ' meta nfproto ipv' + family +
				' ct direction original ct original ' + proto + ' daddr @';
			if (legacy) push(lines, original + 'legacy' + family + ' counter drop');
			if (native) push(lines, original + 'native' + family + (hook == 'output' ? ' counter drop' : ' jump native_original'));
		}
	}
	return join('\n', lines) + '\n';
}

function quote(s) { return "'" + replace('' + s, "'", "'\\''") + "'"; }
function execute(args) {
	let p = fs.popen(join(' ', map(args, quote)) + ' 2>/dev/null', 'r');
	if (!p) die('FakeDNS guard command unavailable');
	let output = p.read('all'), rc = p.close();
	if (rc != 0) die('FakeDNS guard kernel operation failed: ' + args[0] + ' ' + args[1]);
	return output;
}

function cli(args) {
	let cmd = args[0], candidate = args[1], conf = getenv('PODKOPCHIK_CONFIG_DIR') || '/etc/podkopchik';
	let tmp = getenv('PODKOPCHIK_TMP_DIR') || '/tmp/podkopchik';
	let trial = getenv('PODKOPCHIK_GUARD_TRIAL_DIR');
	let ip = getenv('PODKOPCHIK_IP') || 'ip', nft = getenv('PODKOPCHIK_NFT') || 'nft';
	// This ledger must not be rewound by a working-config or Stage4 rollback.
	let path = getenv('PODKOPCHIK_CONFIG_DIR') ? conf + '/fakedns-guard.json' : '/etc/podkopchik-fakedns-guard.json';
	let lock, scratch;
	let owner = +trim(execute(['id', '-u']));
	function private_file(path) {
		let s = fs.lstat(path);
		if (s && (s.type != 'file' || s.uid != owner || s.nlink != 1 || (s.mode & 0o077)))
			die('unsafe FakeDNS guard state file');
		return s;
	}
	function save(path, data) {
		if (fs.lstat(path + '.new')) { private_file(path + '.new'); fs.unlink(path + '.new'); }
		let f = fs.open(path + '.new', 'wx', 0o600);
		if (!f || f.write(data) != length(data) || !f.flush() || !f.close() || !fs.rename(path + '.new', path))
			die('cannot persist FakeDNS guard state');
	}
	function config(path, strict) {
		if (!strict && !fs.lstat(path)) return {};
		let data = fs.readfile(path);
		if (!data) die('cannot read FakeDNS configuration');
		try { return json(data); }
		catch (e) { die('invalid FakeDNS configuration JSON'); }
	}
	function kernel(previous) {
		let table = false, rules = {};
		for (let row in json(execute([nft, '-j', 'list', 'tables'])).nftables || []) if (row.table?.family == 'inet' && row.table?.name == TABLE) {
			if (!length(previous.pools) || row.table.comment != OWNER) die('foreign FakeDNS guard table');
			table = true;
		}
		for (let family in ['-4', '-6']) for (let rule in json(execute([ip, '-N', family, '-j', 'rule', 'show']))) {
			let p = rule_pool(rule, family);
			if (!p) continue;
			if (index(previous.pools, p) < 0 || rules[p]) die('foreign or duplicate FakeDNS guard rule');
			rules[p] = family;
		}
		return { table: table, rules: rules };
	}
	function complete_table(expected) {
		let rows = json(execute([nft, '-j', 'list', 'table', 'inet', TABLE])).nftables || [];
		for (let name, priority in { output: -90, forward: -200, postrouting: 300 }) {
			let chain = filter(rows, row => row.chain?.name == name)[0]?.chain;
			if (chain?.hook != name || chain.prio != priority || chain.policy != 'accept') return false;
		}
		let source = split(batch(expected, false), '\n');
		for (let type in ['rule', 'set', 'chain']) {
			let prefix = 'add ' + type + ' inet ' + TABLE + ' ';
			if (length(filter(rows, row => row[type])) != length(filter(source, line => index(line, prefix) == 0)))
				return false;
		}
		return true;
	}
	function work() {
		if (index(['sync', 'status', 'release', 'register-native', 'preview-native', 'rollback-first-install'], cmd) < 0)
			die('invalid FakeDNS guard action');
		// LuCI diagnostics must neither initialize the guard nor write flash.
		if (cmd != 'status') {
			execute(['mkdir', '-p', conf, tmp]);
			let lockpath = tmp + '/fakedns-guard.lock';
			private_file(lockpath);
			lock = fs.open(lockpath, 'a+', 0o600);
			if (!lock || !lock.lock('x')) die('cannot lock FakeDNS guard');
		}
		let previous = private_file(path) ? state(json(fs.readfile(path))) : { schema: 1, pools: [], lans: [] };
		let uci = require('uci').cursor(), lan = uci.get('podkopchik', 'main', 'lan_ifname') || 'br-lan';
		let configs = [config(conf + '/config.json', false)], lans = [lan];
		let pointer = trim(fs.readfile(conf + '/working-state.name') || '');
		if (match(pointer, /^\.working-[A-Za-z0-9_-]+$/)) {
			configs = [ ...configs, config(conf + '/' + pointer + '/config.json', false) ];
			let old = trim(fs.readfile(conf + '/' + pointer + '/lan') || '');
			if (old) push(lans, old);
		}
		let native;
		if (cmd == 'rollback-first-install') {
			// Only the scoped deployment watchdog uses this path, after
			// proving the ledger, table and priority were absent at baseline.
			if (!trial || candidate != '172.31.253.0/24' || length(previous.pools) &&
				(length(previous.pools) != 2 || index(previous.pools, '198.18.0.0/15') < 0 ||
				 length(previous.native_pools) != 1 || previous.native_pools[0] != candidate))
				die('refusing to roll back a different FakeDNS ledger');
			let live = kernel(previous);
			if (live.table) execute([nft, 'delete', 'table', 'inet', TABLE]);
			for (let pool, family in live.rules) execute([ip, family, 'rule', 'del', 'blackhole', 'to', pool,
				'priority', PRIORITY, 'protocol', PROTOCOL]);
			if (private_file(path) && !fs.unlink(path)) die('cannot remove trial FakeDNS guard ledger');
			if (private_file(path + '.new') && !fs.unlink(path + '.new')) die('cannot remove unfinished trial ledger');
			return;
		}
		if (cmd == 'register-native' || cmd == 'preview-native') {
			// An explicit operator step after native pool admission; never
			// assume an RFC1918 block is free or reserve it on normal Apply.
			native = canonical(candidate);
			let admission = require('native_pool');
			if (!admission.allowed(native, native)) die('invalid native quarantine pool');
			uci.foreach('firewall', 'defaults', s => {
				if (s.flow_offloading == '1' || s.flow_offloading_hw == '1')
					die('flow offloading must be disabled before native quarantine registration');
			});
			for (let row in json(execute([nft, '-j', 'list', 'ruleset'])).nftables || [])
				if (row.flowtable) die('a live flowtable prevents native quarantine registration');
		}
		else if (candidate) push(configs, config(candidate, true));
		let next = desired(previous, configs, lans, native);
		if (!length(next.pools) && cmd != 'release') { if (cmd == 'status') print('state=inactive\n'); return; }
		let live = kernel(previous);
		if (cmd == 'status') {
			let active = live.table && length(keys(live.rules)) == length(next.pools) && complete_table(next);
			printf('state=%s\npools=%s\nnative_pools=%s\n', active ? 'active' : 'incomplete', join(' ', next.pools), join(' ', next.native_pools));
			return;
		}
		if (cmd == 'release') {
			// Called only during explicit uninstall, after interception was removed.
			for (let row in json(execute([nft, '-j', 'list', 'tables'])).nftables || [])
				if (row.table?.family == 'inet' && row.table?.name == 'podkopchik') die('stop Podkopchik interception before releasing its FakeDNS guard');
			if (live.table) execute([nft, 'delete', 'table', 'inet', TABLE]);
			for (let pool, family in live.rules) execute([ip, family, 'rule', 'del', 'blackhole', 'to', pool, 'priority', PRIORITY, 'protocol', PROTOCOL]);
			fs.unlink(path);
			return;
		}
		let exclusions = split(trim(getenv('PODKOPCHIK_GUARD_EXCLUSIONS') || ''), /[ \t]+/);
		uci.foreach('podkopchik', 'bypass_rule', s => { if (s.enabled != '0' && s.host) push(exclusions, s.host); });
		for (let line in split(fs.readfile(tmp + '/proxy_bypass.env', 65536) || '', '\n')) {
			let m = match(line, /^proxy_bypass[46]=(.*)$/);
			if (m) exclusions = [...exclusions, ...split(trim(m[1]), /[ \t]+/)];
		}
		for (let c in configs) for (let o in c?.outbounds || [])
			if (o.protocol == 'vless') for (let server in o.settings?.vnext || []) push(exclusions, server.address);
		if (native != null) for (let family in ['-4', '-6'])
			for (let r in json(execute([ip, '-N', family, '-j', 'rule', 'show'])))
				if (+r.priority != PRIORITY) for (let p in [r.src, r.dst])
					if (p && index(['all', 'default', '0.0.0.0/0', '::/0'], p) < 0) push(exclusions, p);
		check_conflicts(next.pools, json(execute([ip, '-j', 'address', 'show'])),
			[...json(execute([ip, '-4', '-j', 'route', 'show', 'table', 'all'])),
			 ...json(execute([ip, '-6', '-j', 'route', 'show', 'table', 'all']))], exclusions);
		scratch = trim(execute(['mktemp', tmp + '/fakedns-guard.XXXXXX']));
		let rules = batch(next, live.table);
		if (fs.writefile(scratch, rules) != length(rules)) die('cannot stage FakeDNS nftables rules');
		execute([nft, '-c', '-f', scratch]);
		if (cmd == 'preview-native') {
			if (length(next.pools) != 2 || index(next.pools, '198.18.0.0/15') < 0 ||
				length(next.native_pools) != 1 || next.native_pools[0] != '172.31.253.0/24')
				die('unexpected FakeDNS WAN Guard trial pools');
			print('preview=ok\n');
			return;
		}
		// Publish the union before acquiring rules. Interruption cannot lose an
		// already-issued pool, even when the new runtime transaction fails.
		if (sprintf('%J', next) != sprintf('%J', previous)) save(path, sprintf('%J\n', next));
		for (let p in next.pools) if (!live.rules[p]) execute([ip, index(p, ':') < 0 ? '-4' : '-6',
			'rule', 'add', 'blackhole', 'to', p, 'priority', PRIORITY, 'protocol', PROTOCOL]);
		execute([nft, '-f', scratch]);
	}
	let error = null;
	try { work(); } catch (e) { error = e.message; }
	if (scratch) fs.unlink(scratch);
	if (lock) lock.close();
	if (error) die('podkopchik FakeDNS guard: ' + error + '\n');
}

return { canonical: canonical, pools: pools, desired: desired, check_conflicts: check_conflicts,
	rule_pool: rule_pool, batch: batch, cli: cli };
