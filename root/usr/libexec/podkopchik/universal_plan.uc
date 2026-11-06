'use strict';

// Pure planner: neither this module nor its fixtures acquire kernel resources.
// A caller must verify adapter ownership and transactional DNS before activation.
const awg = require('awg');
const network = require('awg_network');
const guard = require('fakedns_guard');
const TABLE = 'podkopchik_native';
const GATE = 'podkopchik_native_gate';

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
	let synthetic = null;
	if (input.synthetic != null) {
		let epoch = input.synthetic.epoch, pools = {};
		if (type(epoch) != 'string' || !match(epoch, /^[a-f0-9]{16}$/)) die('invalid native DNS generation');
		for (let prefix in list(input.synthetic.pools, 'synthetic pools', 2)) {
			let cidr = network_value(prefix), family = index(cidr, ':') < 0 ? '4' : '6';
			let allowed = family == '4' ? ['198.18.0.0/15', '100.64.0.0/10'] : ['2001:2::/48', 'fd00::/8'];
			let bits = +split(cidr, '/')[1];
			if (pools[family] || bits > (family == '4' ? 29 : 125) ||
				!length(filter(allowed, p => bits >= +split(p, '/')[1] && awg.overlap(cidr, p))))
				die('invalid native synthetic prefix');
			for (let x in [...fake, ...bypass]) if (awg.overlap(cidr, x)) die('native synthetic prefix overlaps an existing pool or bypass');
			pools[family] = cidr;
		}
		if (!length(keys(pools))) die('missing native synthetic prefix');
		let dns = null;
		if (input.synthetic.dns != null) {
			let port = input.synthetic.dns.port, ipv4 = input.synthetic.dns.ipv4, ipv6 = input.synthetic.dns.ipv6;
			if (type(port) != 'int' || port < 1024 || port > 65535 || (!ipv4 && !ipv6)) die('invalid LAN DNS listener');
			let endpoints = {};
			for (let family, ip in { '4': ipv4, '6': ipv6 }) if (ip) {
				if (type(ip) != 'string' || index(ip, '/') >= 0 || (index(ip, ':') >= 0) != (family == '6'))
					die('invalid LAN DNS address family');
				let host = network_value(ip);
				guard.check_conflicts([host], [], [], [...fake, ...values(pools)]);
				endpoints[family] = split(host, '/')[0];
			}
			dns = { port, endpoints };
		}
		synthetic = { epoch, pools, dns };
	}
	return { schema: 1, lan, automatic: input.automatic, adapters, fake, bypass, domains, synthetic,
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
	if (plan.synthetic) chain('synth_nat', 'nat', 'prerouting', -105);
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
		if (!plan.synthetic) {
			set('quarantine' + family, family, [], false);
			set('ambiguous' + family, family, [], true);
		}
		classify(proto + ' daddr @fake' + family, 'blocked');
		let pool = plan.synthetic?.pools[family];
		if (pool) {
			let prefix = 's_' + plan.synthetic.epoch, map = prefix + '_m' + family;
			let overrides = 'synth_clients' + family;
			push(lines, (switching ? 'flush' : 'add') + ' chain inet ' + TABLE + ' ' + overrides);
			for (let r in plan.clients) if (of_family(r.cidr))
				rule(overrides, proto + ' saddr ' + r.cidr + ' ' + verdict(r.target == 'direct' ? 'blocked' : r.target));
			if (!switching) push(lines, 'add map inet ' + TABLE + ' ' + map + ' { type ipv' + family + '_addr : ipv' + family + '_addr; flags timeout; size 65536; }');
			for (let i = 0; i < length(plan.domains); i++) {
				let row = plan.domains[i];
				if (row.target == 'direct') continue;
				let name = prefix + '_g' + i + '_' + family;
				set(name, family, [], true);
				let match = proto + ' daddr @' + name;
				rule('classify', lan + match + ' jump ' + overrides);
				classify(match, row.target);
			}
			classify(proto + ' daddr ' + pool, 'blocked');
			rule('synth_nat', lan + proto + ' daddr ' + pool + ' dnat ' + proto + ' to ' + proto + ' daddr map @' + map);
		}
		rule('classify', lan + 'meta nfproto ipv' + family + ' fib daddr type local return');
		classify(proto + ' daddr @bypass' + family, 'direct');
		for (let r in plan.clients) if (of_family(r.cidr)) classify(proto + ' saddr ' + r.cidr, r.target);
		if (!plan.synthetic) {
			classify(proto + ' daddr @ambiguous' + family, 'blocked');
			for (let row in plan.domains) {
				let name = row.set + '_' + family;
				set(name, family, [], true);
				classify(proto + ' daddr @' + name, row.target);
			}
			// A formerly protected address cannot go direct after its lease expires.
			classify(proto + ' daddr @quarantine' + family, 'blocked');
		}
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

function dns_policy(plan, listen, upstream, excluded) {
	if (!plan.synthetic) die('native DNS requires synthetic mode');
	let result = { epoch: plan.synthetic.epoch, listen, upstream,
		pools: values(plan.synthetic.pools), exclusions: [...plan.fake, ...plan.bypass, ...map(excluded, network_value)],
		groups: map(plan.domains, g => ({ names: g.names, protected: g.target != 'direct' })) };
	let dns = plan.synthetic.dns;
	if (dns) {
		let v4 = dns.endpoints['4'], v6 = dns.endpoints['6'];
		result.listen = v4 ? v4 + ':' + dns.port : '[' + v6 + ']:' + dns.port;
		if (v4 && v6) result.listen6 = '[' + v6 + ']:' + dns.port;
	}
	return result;
}

function fw4_forward(plan) {
	if (!plan.synthetic) die('native firewall4 forwarding requires synthetic mode');
	let lines = [];
	for (let _, a in plan.adapters)
		push(lines, 'iifname "' + plan.lan + '" oifname "' + a.interface + '" meta mark ' + a.mark +
			' ct state { new, established, related } counter accept comment "Podkopchik native marked tunnel"');
	return join('\n', lines) + '\n';
}

function dns_gate(plan) {
	if (!plan.synthetic) die('native DNS gate requires synthetic mode');
	let lines = ['add table inet ' + GATE + ' { comment "podkopchik-native-dns-' + plan.synthetic.epoch + '"; }'];
	function rule(chain, expression) { push(lines, 'add rule inet ' + GATE + ' ' + chain + ' ' + expression); }
	for (let hook in ['input', 'forward', 'output', 'postrouting'])
		push(lines, 'add chain inet ' + GATE + ' ' + hook + ' { type filter hook ' + hook + ' priority ' + (hook == 'postrouting' ? 300 : -10) + '; policy accept; }');
	push(lines, 'add chain inet ' + GATE + ' allowed');
	for (let _, a in plan.adapters)
		rule('allowed', 'iifname "' + plan.lan + '" meta mark ' + a.mark + ' oifname "' + a.interface + '" return');
	rule('allowed', 'counter drop');
	for (let family, pool in plan.synthetic.pools) {
		let proto = family == '4' ? 'ip' : 'ip6';
		for (let hook in ['input', 'forward', 'output', 'postrouting']) {
			rule(hook, proto + ' daddr ' + pool + ' counter drop');
			rule(hook, 'meta nfproto ipv' + family + ' ct direction original ct original ' + proto + ' daddr ' + pool +
				(hook == 'forward' || hook == 'postrouting' ? ' jump allowed' : ' counter drop'));
		}
		rule('postrouting', proto + ' saddr ' + pool + ' oifname != { "lo", "' + plan.lan + '" } counter drop');
	}
	for (let pool in plan.fake) {
		let family = index(pool, ':') < 0 ? '4' : '6', proto = family == '4' ? 'ip' : 'ip6';
		for (let hook in ['input', 'forward', 'output', 'postrouting']) {
			rule(hook, proto + ' daddr ' + pool + ' counter drop');
			rule(hook, 'meta nfproto ipv' + family + ' ct direction original ct original ' + proto + ' daddr ' + pool + ' counter drop');
		}
		rule('postrouting', proto + ' saddr ' + pool + ' oifname != { "lo", "' + plan.lan + '" } counter drop');
	}
	let dns = plan.synthetic.dns;
	if (dns) {
		let lan = 'iifname "' + plan.lan + '" ', transport = 'meta l4proto { tcp, udp } ';
		// Before classification: even a client forced to a down adapter can
		// reach the local DNS listener. Original-destination checks are at filter hooks.
		push(lines, 'add chain inet ' + GATE + ' dns_lan { type nat hook prerouting priority -155; policy accept; }');
		for (let hook in ['input', 'forward'])
			push(lines, 'add chain inet ' + GATE + ' dns_' + hook + ' { type filter hook ' + hook + ' priority -11; policy accept; }');
		for (let family, addr in dns.endpoints) {
			let proto = family == '4' ? 'ip' : 'ip6';
			let target = (family == '4' ? addr : '[' + addr + ']') + ':' + dns.port;
			rule('dns_lan', lan + 'meta nfproto ipv' + family + ' ' + transport + 'th dport 53 dnat ' + proto + ' to ' + target);
			let socket = proto + ' daddr ' + addr + ' ' + transport + 'th dport ' + dns.port;
			rule('dns_input', lan + socket + ' ct status dnat ct direction original ct original proto-dst 53 return');
			rule('dns_input', socket + ' counter drop');
		}
		// These remain effective if the NAT chain fails or is removed. Do not
		// silently send client queries to stock dnsmasq or a WAN resolver.
		rule('dns_input', lan + transport + 'th dport 53 counter drop');
		rule('dns_forward', lan + transport + 'th dport 53 counter drop');
		rule('dns_forward', lan + transport + 'ct direction original ct original proto-dst 53 counter drop');
	}
	return join('\n', lines) + '\n';
}

function dns_release(plan) {
	if (!plan.synthetic?.dns) die('no managed LAN DNS in native plan');
	// The caller must check table ownership and restore the prior resolver.
	return join('\n', map(['dns_lan', 'dns_input', 'dns_forward'], c => 'delete chain inet ' + GATE + ' ' + c)) + '\n';
}

function switch_batch(previous, next) {
	function layout(p) {
		return { lan: p.lan, fake: p.fake, bypass: p.bypass, domains: p.domains, clients: p.clients, ips: p.ips, synthetic: p.synthetic,
			adapters: map(keys(p.adapters), tag => [tag, p.adapters[tag].interface, p.adapters[tag].mark]) };
	}
	// A health transition must keep every DNS set and its leases intact.
	if (sprintf('%J', layout(previous)) != sprintf('%J', layout(next))) die('native layout changed during selection');
	return render(next, true);
}

return { compile, batch, switch_batch, dns_policy, dns_gate, dns_release, fw4_forward };
