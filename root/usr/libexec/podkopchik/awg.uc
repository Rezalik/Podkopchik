'use strict';

import * as native_fs from 'fs';

const MAX_CONFIG = 65536;
const MAX_REQUEST = MAX_CONFIG * 6 + 4096;

// Error codes and allowlisted field names only: never echo uploaded values.
function fail(code, line, field) {
	die(sprintf('%J', { awg_error: true, code: code, line: line || 0, field: field || '' }));
}

function error(e) {
	try {
		let detail = json(e.message);
		if (detail.awg_error) return detail;
	} catch (ignored) { }
	return { code: 'storage', line: 0, field: '' };
}

function uint(v, max) {
	return type(v) == 'string' && match(v, /^[0-9]+$/) && length(v) <= 10 && +v <= max;
}

function range(v, max) {
	let p = split(v, '-');
	return length(p) <= 2 && uint(p[0], max) &&
		(length(p) == 1 || (uint(p[1], max) && +p[0] <= +p[1]));
}

function ipv4(v) {
	let p = split(v, '.');
	if (length(p) != 4) return false;
	for (let x in p)
		if (!uint(x, 255) || (length(x) > 1 && substr(x, 0, 1) == '0')) return false;
	return true;
}

function ipv6(v) {
	if (!match(v, /^[0-9a-fA-F:.]+$/) || index(v, ':') < 0) return false;
	if (index(v, '.') >= 0) {
		let end = rindex(v, ':');
		if (!ipv4(substr(v, end + 1))) return false;
		v = substr(v, 0, end + 1) + '0:0';
	}
	let sides = split(v, '::');
	if (length(sides) > 2) return false;
	let count = 0;
	for (let side in sides) {
		if (!length(side)) continue;
		for (let x in split(side, ':')) {
			if (!match(x, /^[0-9a-fA-F]{1,4}$/)) return false;
			count++;
		}
	}
	return length(sides) == 2 ? count < 8 : count == 8;
}

function domain(v) {
	if (!length(v) || length(v) > 253 || match(v, /^[0-9.]+$/)) return false;
	for (let label in split(v, '.'))
		if (!match(label, /^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$/)) return false;
	return true;
}

function ip(v) { return ipv4(v) || ipv6(v); }

function ip_bytes(v) {
	if (ipv4(v)) return map(split(v, '.'), function(x) { return +x; });
	if (index(v, '.') >= 0) {
		let pos = rindex(v, ':'), bytes = ip_bytes(substr(v, pos + 1));
		v = substr(v, 0, pos + 1) + sprintf('%x:%x', bytes[0] * 256 + bytes[1], bytes[2] * 256 + bytes[3]);
	}
	let sides = split(v, '::'), left = length(sides[0]) ? split(sides[0], ':') : [];
	let right = length(sides) == 2 && length(sides[1]) ? split(sides[1], ':') : [];
	if (length(sides) == 2) while (length(left) + length(right) < 8) push(left, '0');
	let out = [];
	for (let word in [ ...left, ...right ]) { let n = hex(word); push(out, n >> 8, n & 255); }
	return out;
}

function overlap(a, b) {
	let x = split(a, '/'), y = split(b, '/'), bx = ip_bytes(x[0]), by = ip_bytes(y[0]);
	if (length(bx) != length(by)) return false;
	let bits = min(+x[1], +y[1]);
	for (let i = 0; bits > 0; i++, bits -= 8) {
		let mask = bits >= 8 ? 255 : (255 << (8 - bits)) & 255;
		if ((bx[i] & mask) != (by[i] & mask)) return false;
	}
	return true;
}

function cidr(v, required) {
	let p = split(v, '/');
	return length(p) <= 2 && ip(p[0]) &&
		(length(p) == 1 ? !required : uint(p[1], ipv4(p[0]) ? 32 : 128));
}

function key(v) {
	if (!match(v, /^[A-Za-z0-9+/]{43}=$/)) return false;
	let raw = b64dec(v);
	return raw != null && length(raw) == 32 && b64enc(raw) == v && v != 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
}

function endpoint(v) {
	let m = match(v, /^\[([0-9a-fA-F:.]+)\]:([0-9]+)$/);
	if (m) return ipv6(m[1]) && uint(m[2], 65535) && +m[2] > 0;
	m = match(v, /^([^:]+):([0-9]+)$/);
	return m && (ipv4(m[1]) || domain(m[1])) && uint(m[2], 65535) && +m[2] > 0;
}

function values(v, check) {
	let p = split(v, ',');
	for (let x in p) if (!check(trim(x))) return false;
	return length(p) > 0;
}

// CPS is data, not a command. Match the upstream 3.1 kernel tag vocabulary.
function cps(v) {
	let size = 0;
	while (length(v)) {
		let m = match(v, /^<(b|r|rc|rd) ([^<>]+)>|^<(c|t)>/);
		if (!m) return false;
		if (m[1] == 'b') {
			if (!match(m[2], /^0x([0-9a-fA-F]{2})+$/)) return false;
			size += (length(m[2]) - 2) / 2;
		}
		else if (m[1]) {
			if (!uint(m[2], 65535)) return false;
			size += +m[2];
		}
		else size += 4;
		if (size > 65507) return false;
		v = trim(substr(v, length(m[0])));
	}
	return size > 0;
}

const IF_KEYS = [ 'PrivateKey', 'ListenPort', 'FwMark', 'Address', 'DNS', 'MTU',
	'Jc', 'Jmin', 'Jmax', 'S1', 'S2', 'S3', 'S4', 'H1', 'H2', 'H3', 'H4',
	'I1', 'I2', 'I3', 'I4', 'I5', 'HeaderProtectionKey', 'ContentPaddingAddition',
	'RekeyAfterTime', 'RekeyTimeout', 'RejectAfterTime', 'KeepaliveTimeout',
	'MaxHandshakeAttempts', 'RandomTrailers', 'DisableCookies' ];
const PEER_KEYS = [ 'PublicKey', 'PresharedKey', 'Endpoint', 'AllowedIPs',
	'PersistentKeepalive', 'AdvancedSecurity' ];
const NEW_KEYS = [ 'HeaderProtectionKey', 'ContentPaddingAddition', 'RekeyAfterTime',
	'RekeyTimeout', 'RejectAfterTime', 'KeepaliveTimeout', 'MaxHandshakeAttempts',
	'RandomTrailers', 'DisableCookies' ];

function parse(text) {
	if (type(text) != 'string' || !length(text) || length(text) > MAX_CONFIG) fail('size');
	let iface = null, peers = [], current = null, lines = [], line_no = 0;
	for (let raw in split(text, '\n')) {
		line_no++;
		let line = trim(split(raw, '#', 2)[0]);
		if (!length(line)) continue;
		if (match(line, /[^\x20-\x7e\t]/)) fail('syntax', line_no);
		if (lc(line) == '[interface]') {
			if (iface || length(peers)) fail('section', line_no);
			iface = {}; current = iface; push(lines, '[Interface]'); continue;
		}
		if (lc(line) == '[peer]') {
			if (!iface) fail('section', line_no);
			current = {}; push(peers, current); push(lines, '\n[Peer]'); continue;
		}
		if (substr(line, 0, 1) == '[') fail('section', line_no);
		let pos = index(line, '=');
		if (!current || pos < 1) fail('syntax', line_no);
		let input_key = lc(trim(substr(line, 0, pos))), field = null;
		for (let candidate in (current == iface ? IF_KEYS : PEER_KEYS))
			if (lc(candidate) == input_key) field = candidate;
		if (!field) fail('unsupported', line_no);
		if (exists(current, field)) fail('duplicate', line_no, field);
		let v = trim(substr(line, pos + 1)), valid = false;
		if (field == 'PrivateKey' || field == 'PublicKey' || field == 'PresharedKey' || field == 'HeaderProtectionKey') valid = key(v);
		else if (field == 'Endpoint') valid = endpoint(v);
		else if (field == 'Address') valid = values(v, function(x) { return cidr(x, true); });
		else if (field == 'AllowedIPs') valid = values(v, function(x) { return cidr(x, false); });
		else if (field == 'DNS') valid = values(v, function(x) { return ip(x) || domain(x); });
		else if (field == 'MTU') valid = uint(v, 65535) && +v >= 576;
		else if (field == 'FwMark') valid = v == 'off' || uint(v, 4294967295) || !!match(v, /^0x[0-9a-fA-F]{1,8}$/);
		else if (field == 'RandomTrailers' || field == 'DisableCookies' || field == 'AdvancedSecurity') valid = !!match(v, /^(on|off|0|1)$/i);
		else if (match(field, /^I[1-5]$/)) valid = cps(v);
		else if (match(field, /^H[1-4]$/)) valid = range(v, 4294967295);
		else if (index(NEW_KEYS, field) >= 0 || field == 'PersistentKeepalive') valid = range(v, 65535);
		else valid = uint(v, 65535);
		if (!valid) fail('value', line_no, field);
		current[field] = v;
		push(lines, field + ' = ' + v);
	}
	if (!iface || !exists(iface, 'PrivateKey')) fail('private_key');
	if (!length(peers)) fail('peer');
	let endpoints = [];
	for (let peer in peers) {
		for (let field in [ 'PublicKey', 'Endpoint', 'AllowedIPs' ])
			if (!exists(peer, field)) fail('required', 0, field);
		if (lc(peer.AdvancedSecurity || '') == 'off' || peer.AdvancedSecurity == '0') fail('security');
		push(endpoints, peer.Endpoint);
	}
	let marker = false;
	for (let field in NEW_KEYS) if (exists(iface, field)) marker = true;
	if (!marker) fail('not_awg31');
	if (iface.HeaderProtectionKey)
		for (let field in [ 'S1', 'S2', 'S3', 'S4' ])
			if (!exists(iface, field) || +iface[field] < 12) fail('padding', 0, field);
	if (iface.Jmin && iface.Jmax && +iface.Jmin > +iface.Jmax) fail('range', 0, 'Jmin');
	let headers = [];
	for (let i = 1; i <= 4; i++) {
		let p = split(iface['H' + i] || '' + i, '-');
		let h = [ +p[0], +(p[1] || p[0]) ];
		for (let old in headers) if (h[0] <= old[1] && old[0] <= h[1]) fail('headers');
		push(headers, h);
	}
	return { config: join('\n', lines) + '\n', endpoints: endpoints, peer_count: length(peers),
		interface: iface, peers: peers };
}

function valid_id(id) { return type(id) == 'string' && !!match(id, /^[a-f0-9]{32}$/); }

function name(value) {
	if (type(value) != 'string') fail('name');
	value = trim(value);
	if (!length(value) || length(value) > 128 || match(value, /[[:cntrl:]]/)) fail('name');
	return value;
}

function random_id() {
	let f = native_fs.open('/dev/urandom', 'r'), bytes = f ? f.read(16) : null;
	if (f) f.close();
	if (bytes == null || length(bytes) != 16) fail('storage');
	let id = '';
	for (let i = 0; i < 16; i++) id += sprintf('%02x', ord(bytes, i));
	return id;
}

// The RPC entry point always supplies the fixed root and uid 0. Alternate roots
// exist only for isolated local tests, never as RPC parameters or environment.
function store(root, owner, filesystem) {
	const fs = filesystem || native_fs;
	function safe(path, kind, private) {
		let s = fs.lstat(path);
		if (!s || s.type != kind || s.uid != owner ||
			(kind == 'file' && s.nlink != 1) || (s.mode & (private ? 0o077 : 0o022))) fail('storage');
		return s;
	}
	function prepare() {
		let parent = fs.dirname(root);
		safe(parent, 'directory', false);
		// mkdtemp creates a private directory; renaming publishes it without a
		// mkdir/chmod window. A racing creator is handled by the final check.
		if (!fs.lstat(root)) {
			let tmp = fs.mkdtemp(parent + '/.awg-XXXXXX');
			if (!tmp) fail('storage');
			if (!fs.rename(tmp, root)) fs.rmdir(tmp);
		}
		safe(root, 'directory', true);
	}
	function read(path, max) {
		let s = safe(path, 'file', true);
		if (s.size > max) fail('storage');
		let text = fs.readfile(path, max + 1);
		if (text == null || length(text) > max) fail('storage');
		return text;
	}
	function load(id) {
		if (!valid_id(id)) fail('id');
		if (!fs.lstat(root + '/' + id + '.json')) fail('missing');
		let meta;
		try { meta = json(read(root + '/' + id + '.json', 4096)); }
		catch (e) { fail('storage'); }
		if (meta.id != id || !valid_id(meta.revision) || type(meta.name) != 'string') fail('storage');
		return meta;
	}
	function conf_path(meta) { return root + '/' + meta.id + '.' + meta.revision + '.conf'; }
	function atomic(path, text) {
		let tmp = root + '/.write-' + random_id();
		let f = fs.open(tmp, 'wx', 0o600);
		if (!f) fail('storage');
		let wrote = f.write(text), flushed = f.flush(), closed = f.close();
		if (wrote != length(text) || !flushed || !closed || !fs.rename(tmp, path)) {
			fs.unlink(tmp); fail('storage');
		}
	}
	function public_meta(meta, validation) {
		return { id: meta.id, name: meta.name, protocol: 'AmneziaWG 3.1',
			created_at: meta.created_at, updated_at: meta.updated_at,
			checked_at: meta.checked_at, status: validation ? 'valid' : 'invalid',
			endpoints: validation ? validation.endpoints : [],
			peer_count: validation ? validation.peer_count : 0 };
	}
	function dispatch(method, args) {
		// Internal caller only; never present in the RPC method allowlist.
		if (method == 'profile') {
			let meta = load(args.id);
			return { meta: meta, parsed: parse(read(conf_path(meta), MAX_CONFIG)) };
		}
		if (method == 'list') {
			let result = [];
			for (let file in (fs.lsdir(root) || [])) {
				if (!match(file, /^[a-f0-9]{32}\.json$/)) continue;
				let meta = load(substr(file, 0, 32)), checked = null;
				try { checked = parse(read(conf_path(meta), MAX_CONFIG)); } catch (e) { }
				push(result, public_meta(meta, checked));
			}
			return { connections: result };
		}
		if (method == 'import' || method == 'replace') {
			let display_name = name(args.name), parsed = parse(args.config), old = null;
			if (method == 'replace') old = load(args.id);
			let meta = { id: old ? old.id : random_id(), revision: random_id(), name: display_name,
				created_at: old ? old.created_at : time(), updated_at: time(), checked_at: time(), status: 'valid' };
			if (!old && fs.lstat(root + '/' + meta.id + '.json')) fail('storage');
			let path = conf_path(meta);
			atomic(path, parsed.config);
			try { atomic(root + '/' + meta.id + '.json', sprintf('%J', meta)); }
			catch (e) { fs.unlink(path); die(e.message); }
			// Metadata rename is the commit point. An interruption can leave only
			// a root-only orphan revision, never a partially replaced connection.
			if (old) fs.unlink(conf_path(old));
			return { connection: public_meta(meta, parsed) };
		}
		let meta = load(args.id);
		if (method == 'delete') {
			if (!fs.unlink(root + '/' + meta.id + '.json')) fail('storage');
			for (let file in (fs.lsdir(root) || []))
				if (substr(file, 0, 33) == meta.id + '.' && match(file, /^[a-f0-9]{32}\.[a-f0-9]{32}\.conf$/))
					if (!fs.unlink(root + '/' + file)) fail('storage');
			return {};
		}
		if (method == 'rename') {
			meta.name = name(args.name); meta.updated_at = time();
			let checked = null;
			try { checked = parse(read(conf_path(meta), MAX_CONFIG)); } catch (e) { }
			atomic(root + '/' + meta.id + '.json', sprintf('%J', meta));
			return { connection: public_meta(meta, checked) };
		}
		if (method != 'validate') fail('request');
		meta.checked_at = time();
		let parsed;
		try { parsed = parse(read(conf_path(meta), MAX_CONFIG)); }
		catch (e) {
			meta.status = 'invalid'; meta.validation_error = error(e);
			atomic(root + '/' + meta.id + '.json', sprintf('%J', meta));
			die(e.message);
		}
		meta.status = 'valid'; delete meta.validation_error;
		atomic(root + '/' + meta.id + '.json', sprintf('%J', meta));
		return { connection: public_meta(meta, parsed) };
	}
	return {
		run: function(method, args) {
			prepare();
			let path = root + '/.lock';
			if (fs.lstat(path)) safe(path, 'file', true);
			let lock = fs.open(path, 'a+', 0o600);
			if (!lock) fail('storage');
			if (!lock.lock('xn')) { lock.close(); fail('busy'); }
			try {
				let result = dispatch(method, args);
				lock.close(); return result;
			}
			catch (e) { lock.close(); die(e.message); }
		}
	};
}

return { parse: parse, store: store, fail: fail, error: error, ip: ip, nonce: random_id,
	domain: domain, overlap: overlap, max_config: MAX_CONFIG, max_request: MAX_REQUEST };
