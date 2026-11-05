'use strict';

// Pure planner: neither this module nor its fixtures acquire kernel resources.
// A caller must verify adapter ownership and transactional DNS before activation.
const awg = require('awg');
const network = require('awg_network');
const guard = require('fakedns_guard');
const TABLE = 'podkopchik_native';

function list(value, label, limit) {
	if (type(value) != 'array' || length(value) > limit) die('invalid native ' + label);
	return value;
}

function network_value(value) {
	if (type(value) != 'string') die('invalid native address');
	return guard.canonical(index(value, '/') >= 0 ? value : value + (index(value, ':') >= 0 ? '/128' : '/32'));
}

function domain_value(value) {
	if (type(value) != 'string' || length(value) > 253 || !match(value, /^[a-z0-9-]+(\.[a-z0-9-]+)+$/)) die('invalid native domain');
	for (let label in split(value, '.')) if (length(label) > 63 || match(label, /(^-|-$)/)) die('invalid native domain label');
	return value;
}

function compile(input) {
	let lan = input?.lan;
	if (type(lan) != 'string' || !match(lan, /^[A-Za-z0-9_.-]{1,15}$/) || lan == 'lo') die('invalid native LAN');
	let adapters = {}, marks = {}, interfaces = {};
	for (let a in list(input.adapters, 'adapters', 32)) {
		if (a?.type != 'amneziawg' || !match(a.id || '', /^[a-f0-9]{32}$/))
			die('unsupported native adapter');
		let r = network.resources(a.id);
		if (adapters[r.tag] || marks[r.mark] || interfaces[r.interface]) die('colliding native adapter resources');
		marks[r.mark] = true; interfaces[r.interface] = true;
		adapters[r.tag] = { ...r, usable: a.usable == true, ipv4: a.ipv4 == true, ipv6: a.ipv6 == true };
	}
	// Runtime health/threshold/cooldown selection supplies resolved automatic
	// targets. The planner does not probe or treat unknown health as available.
	function target(tag) {
		if (tag == 'direct' || tag == 'blocked' || tag == 'auto_proxy_group' || adapters[tag]) return tag;
		die('unresolved native target');
	}
	if (input.automatic != 'blocked' && !adapters[input.automatic]) die('unresolved native automatic transport');
	let fake = map(list(input.fake_pools, 'fake pools', 16), network_value);
	let bypass = map(list(input.bypass, 'bypass', 512), network_value);
	for (let f in fake) for (let b in bypass) if (awg.overlap(f, b)) die('native bypass overlaps a FakeDNS pool');
	let domains = [];
	for (let row in list(input.domains, 'domain groups', 512)) {
		let names = map(list(row?.names, 'domain group', 4096), domain_value);
		if (!length(names)) die('empty native domain group');
		push(domains, { names, target: target(row.target), set: 'domain_' + length(domains) });
	}
	function rules(rows, label) {
		return map(list(rows, label, 512), row => ({ cidr: network_value(row?.cidr), target: target(row.target) }));
	}
	return { schema: 1, lan, automatic: input.automatic, adapters, fake, bypass, domains,
		clients: rules(input.clients, 'client policies'), ips: rules(input.ips, 'CIDR policies') };
}

function render(plan, switching) {
	let lines = switching ? [] : ['add table inet ' + TABLE + ' { comment "podkopchik-native-preview-v1"; }'];
	function chain(name, type, hook, priority) {
		push(lines, switching ? 'flush chain inet ' + TABLE + ' ' + name :
			'add chain inet ' + TABLE + ' ' + name + ' { type ' + type + ' hook ' + hook + ' priority ' + priority + '; policy accept; }');
	}
	chain('classify', 'filter', 'prerouting', -151);
	chain('egress_guard', 'filter', 'forward', -200);
	chain('nat', 'nat', 'postrouting', 99);
	function rule(chain, expression) { push(lines, 'add rule inet ' + TABLE + ' ' + chain + ' ' + expression); }
	function set(name, family, elements, timed) {
		if (switching) return;
		push(lines, 'add set inet ' + TABLE + ' ' + name + ' { type ipv' + family + '_addr; flags ' +
			(timed ? 'timeout; size 16384;' : 'interval; auto-merge;') + ' }');
		if (length(elements)) push(lines, 'add element inet ' + TABLE + ' ' + name + ' { ' + join(', ', elements) + ' }');
	}
	let lan = 'iifname "' + plan.lan + '" ';
	for (let family in ['4', '6']) {
		let v6 = family == '6', proto = v6 ? 'ip6' : 'ip';
		function of_family(x) { return (index(x, ':') >= 0) == v6; }
		function verdict(tag) {
			if (tag == 'direct') return 'return';
			if (tag == 'auto_proxy_group') tag = plan.automatic;
			let a = plan.adapters[tag];
			if (!a?.usable || !(v6 ? a.ipv6 : a.ipv4)) return 'counter drop';
			return 'meta mark set ' + a.mark + ' counter accept';
		}
		function classify(match, tag) { rule('classify', lan + match + ' ' + verdict(tag)); }
		set('fake' + family, family, filter(plan.fake, of_family), false);
		set('bypass' + family, family, filter(plan.bypass, of_family), false);
		set('quarantine' + family, family, [], false);
		set('ambiguous' + family, family, [], true);
		classify(proto + ' daddr @fake' + family, 'blocked');
		rule('classify', lan + 'meta nfproto ipv' + family + ' fib daddr type local return');
		classify(proto + ' daddr @bypass' + family, 'direct');
		for (let r in plan.clients) if (of_family(r.cidr)) classify(proto + ' saddr ' + r.cidr, r.target);
		classify(proto + ' daddr @ambiguous' + family, 'blocked');
		for (let row in plan.domains) {
			let name = row.set + '_' + family;
			set(name, family, [], true);
			classify(proto + ' daddr @' + name, row.target);
		}
		// A previously classified protected answer cannot go direct after its
		// lease expires. Only an independently verified DNS writer may populate it.
		classify(proto + ' daddr @quarantine' + family, 'blocked');
		for (let r in plan.ips) if (of_family(r.cidr)) classify(proto + ' daddr ' + r.cidr, r.target);
	}
	for (let _, a in plan.adapters) {
		let marked = lan + 'meta mark ' + a.mark;
		rule('egress_guard', marked + ' oifname != "' + a.interface + '" counter drop');
		rule('nat', marked + ' oifname "' + a.interface + '" masquerade');
	}
	return join('\n', lines) + '\n';
}

function batch(plan) { return render(plan, false); }

function switch_batch(previous, next) {
	function layout(p) {
		return { lan: p.lan, fake: p.fake, bypass: p.bypass, domains: p.domains, clients: p.clients, ips: p.ips,
			adapters: map(keys(p.adapters), tag => [tag, p.adapters[tag].interface, p.adapters[tag].mark]) };
	}
	// A health transition must keep every DNS set and its leases intact.
	if (sprintf('%J', layout(previous)) != sprintf('%J', layout(next))) die('native layout changed during selection');
	return render(next, true);
}

return { compile, batch, switch_batch };
