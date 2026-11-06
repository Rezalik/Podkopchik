'use strict';

const awg = require('awg');
const guard = require('fakedns_guard');
const ranges = { '4': ['198.18.0.0/15', '100.64.0.0/10'], '6': ['2001:2::/48', 'fd00::/8'] };

function bounded(value, limit) {
	if (type(value) != 'array' || length(value) > limit) die('incomplete or oversized native pool inventory');
	return value;
}

function prefix(raw) {
	if (type(raw) != 'string' || match(raw, /^::ffff:/i)) die('invalid native network prefix');
	let cidr = guard.canonical(index(raw, '/') >= 0 ? raw : raw + (index(raw, ':') >= 0 ? '/128' : '/32'));
	if (match(cidr, /^0:0:0:0:0:ffff:/)) die('mapped IPv4 inventory must use a native IPv4 address');
	return cidr;
}

function family(cidr) { return index(cidr, ':') < 0 ? '4' : '6'; }

function capacity(cidr) {
	let host = (family(cidr) == '4' ? 32 : 128) - +split(cidr, '/')[1];
	return host < 3 ? 0 : host >= 17 ? 65536 : (1 << host) - 2;
}

function allowed(cidr) {
	let bits = +split(cidr, '/')[1];
	return capacity(cidr) && length(filter(ranges[family(cidr)], x => bits >= +split(x, '/')[1] && awg.overlap(cidr, x)));
}

function inventory(value, strict) {
	let occupied = {};
	function add(raw) { occupied[prefix(raw)] = true; }
	function selector(raw) {
		if (index(['default', 'all', '0.0.0.0/0', '::/0'], raw) < 0) add(raw);
	}
	let links = bounded(value?.addresses, 512), routes = bounded(value?.routes, 8192);
	if (!length(links) || !length(routes)) die('empty native network inventory');
	for (let link in links) for (let a in bounded(link?.addr_info ?? [], 512)) {
		if (type(a?.local) != 'string' || type(a.prefixlen) != 'int') die('invalid inventory interface address');
		add(a.local + '/' + a.prefixlen);
	}
	for (let r in routes) {
		if (type(r?.dst) != 'string') die('invalid inventory route');
		selector(r.dst);
		if (r.gateway != null) add(r.gateway);
		if (r.prefsrc != null) add(r.prefsrc);
		if (r.via != null) add(r.via?.addr);
		for (let nh in bounded(r.nexthops ?? [], 64)) {
			if (nh?.gateway != null) add(nh.gateway);
			if (nh?.via != null) add(nh.via?.addr);
		}
	}
	for (let r in bounded(strict ? value.rules : value.rules ?? [], 8192)) {
		if (type(r) != 'object' || type(r.priority) != 'int') die('invalid inventory policy rule');
		for (let v in [r.src, r.dst]) if (v != null) selector(v);
	}
	for (let p in bounded(value.issued, 64)) add(p);
	for (let p in bounded(strict ? value.endpoints : value.endpoints ?? [], 512)) add(p);
	for (let p in bounded(strict ? value.exclusions : value.exclusions ?? [], 512)) add(p);
	return keys(occupied);
}

function overlaps(cidr, occupied) {
	return length(filter(occupied, p => awg.overlap(cidr, p))) != 0;
}

function select(candidates, snapshot, required) {
	let occupied = inventory(snapshot, true), result = {};
	if (type(required) != 'object' || !length(keys(required))) die('missing native pool capacity requirements');
	for (let f, size in required) if (!ranges[f] || type(size) != 'int' || size < 1 || size > 65536)
		die('invalid native pool capacity requirement');
	for (let item in bounded(candidates, 256)) {
		let cidr = prefix(item), f = family(cidr);
		if (!allowed(cidr)) die('candidate outside permitted native pool ranges');
		if (!result[f] && required[f] && capacity(cidr) >= required[f] && !overlaps(cidr, occupied))
			result[f] = { cidr, capacity: capacity(cidr) };
	}
	for (let f in keys(required)) if (!result[f]) die('no approved non-overlapping native pool with required capacity');
	return result;
}

return { inventory, prefix, family, allowed, capacity, overlaps, select };
