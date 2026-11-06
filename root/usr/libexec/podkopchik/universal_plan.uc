'use strict';

// Pure planner: neither this module nor its fixtures acquire kernel resources.
// A caller must verify adapter ownership and transactional DNS before activation.
const awg = require('awg');
const network = require('awg_network');
const guard = require('fakedns_guard');
const pool_admission = require('native_pool');
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

function check_pool_inventory(pools, inventory, private_pool) {
	let issued = map(list(inventory?.issued, 'previous pool inventory', 64), network_value);
	let occupied = pool_admission.inventory(inventory, false);
	for (let p in pools) if (!pool_admission.allowed(p, private_pool) || pool_admission.overlaps(p, occupied))
		die('native synthetic pool overlaps inventory or is outside permitted ranges');
	return issued;
}

function compile(input) {
	let lan = input?.lan;
	if (type(lan) != 'string' || !match(lan, /^[A-Za-z0-9_.-]{1,15}$/) || lan == 'lo') die('invalid native LAN');
	let legacy_lans = list(input.legacy_lans ?? [], 'legacy LANs', 8);
	for (let name in legacy_lans)
		if (type(name) != 'string' || !match(name, /^[A-Za-z0-9_.-]{1,15}$/) || name == 'lo' || name == lan)
			die('legacy and native LAN interfaces must be separate');
	let adapters = {}, marks = {}, interfaces = {};
	for (let a in list(input.adapters, 'adapters', 32)) {
		let r;
		if (a?.type == 'amneziawg' && match(a.id || '', /^[a-f0-9]{32}$/)) {
			r = network.resources(a.id);
		}
		else if (a?.type == 'vless' && match(a.tag || '', /^[a-z][a-z0-9_]{0,63}$/) &&
			type(a.port) == 'int' && a.port >= 23000 && a.port <= 23031 && input.synthetic) {
			let slot = a.port - 23000;
			r = { tag: a.tag, port: a.port, mark: 67108864 + slot, delivery: 67109120 + slot,
				table: 43000 + slot, priority: 12000 + slot };
		}
		else die('unsupported native adapter');
		if (index(['direct', 'blocked', 'auto_proxy_group'], r.tag) >= 0 || adapters[r.tag] || marks[r.mark] ||
			(r.interface && interfaces[r.interface])) die('colliding native adapter resources');
		let sources = [];
		if (a.type == 'amneziawg' && input.synthetic) {
			for (let ip in list(a.source_ips, 'AWG source addresses', 32)) {
				if (type(ip) != 'string' || index(ip, '/') >= 0) die('invalid AWG source address');
				push(sources, split(pool_admission.prefix(ip), '/')[0]);
			}
			if ((a.ipv4 == true && !length(filter(sources, x => index(x, ':') < 0))) ||
				(a.ipv6 == true && !length(filter(sources, x => index(x, ':') >= 0)))) die('missing AWG source address family');
		}
		marks[r.mark] = true;
		if (r.interface) interfaces[r.interface] = true;
		adapters[r.tag] = { ...r, sources, pin: (length(keys(adapters)) + 1) * 16777216,
			type: a.type, usable: a.usable == true, ipv4: a.ipv4 == true, ipv6: a.ipv6 == true };
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
		let private_pool = input.synthetic.private_pool == null ? null : network_value(input.synthetic.private_pool);
		if (private_pool && !pool_admission.private_v4(private_pool)) die('private native pool requires an explicit RFC1918 /24');
		if (type(epoch) != 'string' || !match(epoch, /^[a-f0-9]{16}$/)) die('invalid native DNS generation');
		for (let prefix in list(input.synthetic.pools, 'synthetic pools', 2)) {
			let cidr = network_value(prefix), family = index(cidr, ':') < 0 ? '4' : '6';
			if (pools[family] || !pool_admission.allowed(cidr, private_pool))
				die('invalid native synthetic prefix');
			for (let x in [...fake, ...bypass]) if (awg.overlap(cidr, x)) die('native synthetic prefix overlaps an existing pool or bypass');
			pools[family] = cidr;
		}
		if (!length(keys(pools))) die('missing native synthetic prefix');
		if (private_pool && pools['4'] != private_pool) die('unused private native pool approval');
		for (let previous in check_pool_inventory(values(pools), input.synthetic.inventory, private_pool)) {
			if (index(fake, previous) < 0) push(fake, previous);
			for (let b in bypass) if (awg.overlap(previous, b)) die('native bypass overlaps a previously issued pool');
		}
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
		synthetic = { epoch, pools, dns, private_pool };
	}
	return { schema: 1, lan, legacy_lans, automatic: input.automatic, adapters, fake, bypass, domains, synthetic,
		clients: rules(input.clients, 'client policies'), ips: rules(input.ips, 'CIDR policies') };
}

function render(plan, switching) {
	let owner = plan.synthetic ? 'podkopchik-native-' + plan.synthetic.epoch : 'podkopchik-native-preview-v1';
	let lines = switching ? [] : ['add table inet ' + TABLE + ' { comment "' + owner + '"; }'];
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
	let xray = filter(values(plan.adapters), a => a.type == 'vless');
	if (length(xray)) {
		// TCP IP_TRANSPARENT sees the post-DNAT socket destination. The
		// original tuple remains available to the independent egress guard.
		chain('xray_ingress', 'filter', 'prerouting', -95);
		for (let a in xray) {
			let marked = lan + 'meta mark ' + a.mark;
			if (a.usable) rule('xray_ingress', marked + ' meta l4proto tcp tproxy to :' + a.port +
				' meta mark set ' + a.delivery + ' accept');
			rule('xray_ingress', marked + ' counter drop');
		}
	}
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
		if (a.type == 'vless') {
			rule('egress_guard', marked + ' counter drop');
			rule('egress_guard', lan + 'meta mark ' + a.delivery + ' counter drop');
			continue;
		}
		rule('egress_guard', marked + ' oifname != "' + a.interface + '" counter drop');
		rule('nat', marked + ' oifname "' + a.interface + '" masquerade');
	}
	return join('\n', lines) + '\n';
}

function batch(plan) { return render(plan, false); }

function dns_policy(plan, listen, upstream, excluded) {
	if (!plan.synthetic) die('native DNS requires synthetic mode');
	let result = { epoch: plan.synthetic.epoch, listen, upstream,
		pools: values(plan.synthetic.pools), retired_pools: plan.fake,
		exclusions: [...plan.fake, ...plan.bypass, ...map(excluded, network_value)],
		groups: map(plan.domains, g => ({ names: g.names, protected: g.target != 'direct' })) };
	if (plan.synthetic.private_pool) result.private_pool = plan.synthetic.private_pool;
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
	for (let _, a in plan.adapters) if (a.type == 'amneziawg')
		push(lines, 'iifname "' + plan.lan + '" oifname "' + a.interface + '" meta mark ' + a.mark +
			' ct state { new, established, related } counter accept comment "Podkopchik native marked tunnel"');
	return join('\n', lines) + '\n';
}

function xray_config(plan, outbounds) {
	let config = { log: { loglevel: 'warning' }, inbounds: [], outbounds: [{ tag: 'blocked', protocol: 'blackhole' }],
		routing: { domainStrategy: 'AsIs', rules: [] } };
	for (let a in values(plan.adapters)) if (a.type == 'vless') {
		let outbound = outbounds[a.tag];
		if (outbound?.protocol != 'vless' || outbound.tag != a.tag || outbound.proxySettings || outbound.streamSettings?.sockopt?.dialerProxy)
			die('invalid isolated VLESS outbound');
		let tag = 'native-in-' + a.port;
		push(config.inbounds, { tag, port: a.port, protocol: 'dokodemo-door', settings: { network: 'tcp', followRedirect: true },
			streamSettings: { sockopt: { tproxy: 'tproxy' } } });
		push(config.outbounds, outbound);
		push(config.routing.rules, { type: 'field', inboundTag: [tag], outboundTag: a.tag });
	}
	return config;
}

function dns_gate(plan, scoped) {
	if (!plan.synthetic) die('native DNS gate requires synthetic mode');
	let lines = ['add table inet ' + GATE + ' { comment "podkopchik-native-dns-' + plan.synthetic.epoch + '"; }'];
	function rule(chain, expression) { push(lines, 'add rule inet ' + GATE + ' ' + chain + ' ' + expression); }
	let lan = 'iifname "' + plan.lan + '" ', pin = 'ct mark & 0xff000000 ';
	// Reclassify every packet but never move an existing NAT tuple to a new adapter.
	push(lines, 'add chain inet ' + GATE + ' flow_pin { type filter hook prerouting priority -149; policy accept; }');
	for (let a in values(plan.adapters)) {
		let selected = lan + 'meta mark ' + a.mark + ' ';
		rule('flow_pin', selected + 'ct state new ' + pin + '0 ct mark set (ct mark & 0x00ffffff) | ' + a.pin);
		rule('flow_pin', selected + pin + a.pin + ' return');
		rule('flow_pin', selected + 'counter drop');
	}
	rule('flow_pin', lan + pin + '!= 0 counter drop');
	for (let hook in ['input', 'forward', 'output', 'postrouting'])
		push(lines, 'add chain inet ' + GATE + ' ' + hook + ' { type filter hook ' + hook + ' priority ' + (hook == 'postrouting' ? 300 : -10) + '; policy accept; }');
	let owners = {};
	for (let a in values(plan.adapters)) if (a.type == 'amneziawg')
		for (let addr in a.sources) push(owners[addr] ??= [], a.interface);
	// A late TCP reply can elicit a local RST without the original conntrack mark.
	// Never let a tunnel-source packet escape to a different egress via main.
	for (let addr, ifaces in (scoped ? {} : owners)) {
		let proto = index(addr, ':') < 0 ? 'ip' : 'ip6';
		let safe = join(', ', map(['lo', ...ifaces], n => '"' + n + '"'));
		for (let hook in ['output', 'postrouting'])
			rule(hook, proto + ' saddr ' + addr + ' oifname != { ' + safe + ' } counter drop');
	}
	push(lines, 'add chain inet ' + GATE + ' allowed');
	for (let _, a in plan.adapters) if (a.type == 'amneziawg')
		rule('allowed', lan + 'meta mark ' + a.mark + ' ' + pin + a.pin + ' oifname "' + a.interface + '" return');
	rule('allowed', 'counter drop');
	for (let a in values(plan.adapters)) if (a.type == 'vless') {
		rule('input', lan + 'meta mark ' + a.delivery + ' ' + pin + a.pin + ' meta l4proto tcp return');
		rule('input', 'tcp dport ' + a.port + ' counter drop');
	}
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
		let legacy = ['lo', ...plan.legacy_lans], lan_set = '{ ' + join(', ', map(legacy, x => '"' + x + '"')) + ' }';
		for (let hook in ['input', 'forward', 'output', 'postrouting']) {
			// Only the existing LAN may keep its old local transparent delivery.
			let scope = scoped ? lan : hook == 'input' ? 'iifname != ' + lan_set + ' ' : '';
			rule(hook, scope + proto + ' daddr ' + pool + ' counter drop');
			rule(hook, scope + 'meta nfproto ipv' + family + ' ct direction original ct original ' + proto + ' daddr ' + pool + ' counter drop');
		}
		if (!scoped) rule('postrouting', proto + ' saddr ' + pool + ' oifname != ' + lan_set + ' counter drop');
	}
	return join('\n', lines) + '\n';
}

function canary_guard(plan) {
	if (!plan.synthetic?.dns) die('canary requires managed DNS');
	let table = 'inet ' + GATE, lan = 'iifname "' + plan.lan + '"';
	let lines = ['add chain ' + table + ' canary { type filter hook forward priority -12; policy accept; }'];
	for (let a in values(plan.adapters)) if (a.type == 'amneziawg')
		push(lines, 'add rule ' + table + ' canary ' + lan + ' meta mark ' + a.mark + ' ct mark & 0xff000000 ' + a.pin + ' oifname "' + a.interface + '" return');
	push(lines, 'add rule ' + table + ' canary ' + lan + ' counter drop');
	return join('\n', lines) + '\n';
}

function canary_reply_guard(plan) {
	// Same table as the per-group timed lease sets. Recheck reply packets
	// after DNAT and before fw4's general established/related allow.
	let table = 'inet ' + TABLE, dst = 'oifname "' + plan.lan + '" ';
	let lines = ['add chain ' + table + ' canary_reply { type filter hook forward priority -11; policy accept; }'];
	let reply = dst + 'ip daddr 172.31.252.2 ct direction reply ct state established ct status dnat ct original ip saddr 172.31.252.2 ';
	for (let i = 0; i < length(plan.domains); i++) if (plan.domains[i].target != 'direct') {
		let lease = 'ct original ip daddr @s_' + plan.synthetic.epoch + '_g' + i + '_4 ';
		for (let a in values(plan.adapters)) if (a.type == 'amneziawg' && a.ipv4)
			push(lines, 'add rule ' + table + ' canary_reply ' + reply + lease + 'iifname "' + a.interface +
				'" ct mark & 0xff000000 ' + a.pin + ' return');
	}
	push(lines, 'add rule ' + table + ' canary_reply ' + dst + 'counter drop');
	return join('\n', lines) + '\n';
}

function dns_edge(plan) {
	let dns = plan.synthetic?.dns;
	if (!dns) die('no managed LAN DNS in native plan');
	// Install only after the standalone pool guard and prior resolver are ready.
	let lines = ['add chain inet ' + GATE + ' dns_lan { type nat hook prerouting priority -155; policy accept; }'];
	function rule(chain, expression) { push(lines, 'add rule inet ' + GATE + ' ' + chain + ' ' + expression); }
	let lan = 'iifname "' + plan.lan + '" ', transport = 'meta l4proto { tcp, udp } ';
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
	// These filter chains stay in place if the NAT redirect is lost.
	rule('dns_input', lan + transport + 'th dport 53 counter drop');
	rule('dns_forward', lan + transport + 'th dport 53 counter drop');
	rule('dns_forward', lan + transport + 'ct direction original ct original proto-dst 53 counter drop');
	return join('\n', lines) + '\n';
}

function dns_release(plan) {
	if (!plan.synthetic?.dns) die('no managed LAN DNS in native plan');
	// The caller must check table ownership and restore the prior resolver.
	return join('\n', map(['dns_lan', 'dns_input', 'dns_forward'], c => 'destroy chain inet ' + GATE + ' ' + c)) + '\n';
}

function switch_batch(previous, next) {
	function layout(p) {
		return { lan: p.lan, legacy_lans: p.legacy_lans, fake: p.fake, bypass: p.bypass, domains: p.domains, clients: p.clients, ips: p.ips, synthetic: p.synthetic,
			adapters: map(keys(p.adapters), tag => [tag, p.adapters[tag].type, p.adapters[tag].interface, p.adapters[tag].mark, p.adapters[tag].port, p.adapters[tag].sources]) };
	}
	// A health transition must keep every DNS set and its leases intact.
	if (sprintf('%J', layout(previous)) != sprintf('%J', layout(next))) die('native layout changed during selection');
	return render(next, true);
}

return { compile, batch, switch_batch, check_pool_inventory, dns_policy, dns_gate, dns_edge, dns_release, fw4_forward, canary_guard, canary_reply_guard, xray_config };
