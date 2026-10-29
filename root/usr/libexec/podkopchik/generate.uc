#!/usr/bin/env ucode
'use strict';

import { cursor } from 'uci';
import { readfile } from 'fs';

push(REQUIRE_SEARCH_PATH, '/usr/libexec/podkopchik/*.uc');
push(REQUIRE_SEARCH_PATH, './root/usr/libexec/podkopchik/*.uc');

const vless = require('vless');
const awg_net = require('awg_network');
const interception = require('interception');
const APP = 'podkopchik';
const STATE_FILE = '/tmp/podkopchik/state.json';
let state_file = STATE_FILE;

let ctx = cursor();
ctx.load(APP);

function opt(s, k, d) {
	return exists(s, k) ? s[k] : d;
}

function boolopt(s, k, d) {
	let v = opt(s, k, d ? '1' : '0');
	return v == '1' || v == 'true' || v == true;
}

function intopt(s, k, d) {
	let v = int(opt(s, k, d));
	return v == v ? v : d;
}

function require_value(v, name) {
	if (v == null || !length('' + v))
		die('missing required value: ' + name);

	return '' + v;
}

function first_section(type) {
	let found = null;

	ctx.foreach(APP, type, function(s) {
		found = s;
		return false;
	});

	return found;
}

function sections(type, enabled_only) {
	let out = [];

	ctx.foreach(APP, type, function(s) {
		if (!enabled_only || boolopt(s, 'enabled', true))
			push(out, s);
	});

	return out;
}

function proxy_tag(s, idx) {
	return vless.clean_tag(opt(s, 'tag', '') || opt(s, 'name', ''), 'proxy_' + idx);
}

function group_tag(s, idx) {
	return vless.clean_tag(opt(s, 'tag', '') || opt(s, 'name', ''), 'group_' + idx);
}

function collect_proxies(enabled_only, parse_links) {
	let list = [];
	let by_tag = {};
	let idx = 0;

	if (parse_links == null)
		parse_links = true;

	ctx.foreach(APP, 'proxy', function(s) {
		let tag = proxy_tag(s, idx++);

		if (enabled_only && !boolopt(s, 'enabled', true))
			return;

		let uri = opt(s, 'uri', '');
		let protocol = opt(s, 'protocol', 'vless');
		if (protocol != 'vless' && protocol != 'amneziawg') die('unsupported connection protocol');
		let parsed = parse_links && protocol == 'vless' ? vless.parse(uri) : null;
		let resource = protocol == 'amneziawg' ? awg_net.resources(opt(s, 'awg_id', '')) : null;
		if (resource && tag != resource.tag) die('AWG tag must match profile ID');

		let p = {
			section: s['.name'],
			name: opt(s, 'name', tag),
			tag: tag,
			uri: uri,
			parsed: parsed
		};

		p.protocol = protocol;
		p.resource = resource;
		if (by_tag[tag] || (protocol != 'amneziawg' && match(tag, /^awg_[a-f0-9]{32}$/))) die('duplicate or reserved connection tag');
		push(list, p);
		by_tag[tag] = p;
	});

	return { list: list, by_tag: by_tag };
}

function collect_groups() {
	let list = [];
	let by_tag = {};
	let idx = 0;

	ctx.foreach(APP, 'proxy_group', function(s) {
		if (!boolopt(s, 'enabled', true)) {
			idx++;
			return;
		}

		let tag = group_tag(s, idx++);
		let backups = [];

		for (let b in [ 'backup1', 'backup2', 'backup3' ])
			if (length(opt(s, b, '')))
				push(backups, opt(s, b, ''));

		let g = {
			section: s['.name'],
			name: opt(s, 'name', tag),
			tag: tag,
			mode: opt(s, 'mode', 'strict_primary'),
			primary: opt(s, 'primary', ''),
			fixed_proxy: opt(s, 'fixed_proxy', ''),
			backups: backups,
			auto_return: boolopt(s, 'auto_return', true),
			manual_override_proxy: opt(s, 'manual_override_proxy', ''),
			failure_action: opt(s, 'failure_action', 'warn_only')
		};

		push(list, g);
		by_tag[tag] = g;
	});

	return { list: list, by_tag: by_tag };
}

function read_state() {
	let raw = readfile(state_file);

	if (!raw)
		return {};

	return json(raw);
}

function resolve_proxy(ref, proxies) {
	if (!ref)
		return null;

	ref = vless.clean_tag(ref, ref);

	return proxies.by_tag[ref] ? ref : null;
}

function default_group_proxy(g, proxies) {
	if (g.mode == 'fixed_proxy')
		return resolve_proxy(g.fixed_proxy, proxies);

	if (g.manual_override_proxy)
		return resolve_proxy(g.manual_override_proxy, proxies);

	return resolve_proxy(g.primary, proxies);
}

function resolve_target(ref, proxies, groups, state) {
	if (!ref || ref == 'direct')
		return 'direct';

	let clean = vless.clean_tag(ref, ref);

	if (proxies.by_tag[clean])
		return clean;

	if (groups.by_tag[clean]) {
		let group_state = state.groups ? state.groups[clean] : null;
		let active = group_state ? group_state.active_proxy : null;

		if (active == 'blocked') return 'blocked';
		let g = groups.by_tag[clean];
		let members = [ g.primary, g.fixed_proxy, g.manual_override_proxy ];
		for (let ref in g.backups) push(members, ref);
		if (active && proxies.by_tag[active] && index(members, active) >= 0)
			return active;

		active = default_group_proxy(groups.by_tag[clean], proxies);

		if (active)
			return active;
	}

	die('unknown routing target: ' + ref);
}

function vless_outbound(p) {
	if (p.protocol == 'amneziawg') {
		let r = p.resource, runtime = null;
		try { runtime = awg_net.controller().run('status', r.id); } catch (e) { }
		let alias = trim(readfile('/sys/class/net/' + r.interface + '/ifalias') || '');
		return awg_net.outbound(r, runtime && runtime.running && runtime.guarded && runtime.addresses_assigned && alias == r.alias, runtime?.addresses);
	}
	let x = p.parsed;
	let user = {
		id: x.uuid,
		encryption: 'none'
	};

	if (x.flow)
		user.flow = x.flow;

	let stream = {
		network: x.network,
		security: 'reality',
		realitySettings: {
			serverName: x.serverName,
			fingerprint: x.fingerprint,
			publicKey: x.publicKey,
			shortId: x.shortId
		}
	};

	if (x.network == 'tcp') {
		stream.tcpSettings = {};
	}
	else if (x.network == 'xhttp') {
		stream.xhttpSettings = {
			path: x.path || '/'
		};

		if (x.headerHost)
			stream.xhttpSettings.host = x.headerHost;
	}

	return {
		tag: p.tag,
		protocol: 'vless',
		settings: {
			vnext: [ {
				address: x.address,
				port: x.port,
				users: [ user ]
			} ]
		},
		streamSettings: stream
	};
}

function real_dns_target(proxies, groups, state) {
	let target = groups.by_tag.auto_proxy_group ?
		resolve_target('auto_proxy_group', proxies, groups, state) : proxies.list[0].tag;
	// An independent rules-only tunnel must not depend on a failed automatic
	// group merely to resolve a public hostname. Data routing stays unchanged.
	if (target == 'blocked')
		for (let p in proxies.list) {
			let health = state.proxies?.[p.tag];
			if (health?.status == 'up' && health.checked_at && time() - health.checked_at >= 0 &&
				time() - health.checked_at < 300) return p.tag;
		}
	return target;
}

function private_direct_rule(exclude_ipv4) {
	let ips = [
		'0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10',
		'127.0.0.0/8', '169.254.0.0/16', '172.16.0.0/12',
		'192.0.0.0/24', '192.0.2.0/24', '192.168.0.0/16',
		'198.18.0.0/15', '198.51.100.0/24', '203.0.113.0/24',
		'224.0.0.0/4', '240.0.0.0/4',
		'::1/128', 'fc00::/7', 'fe80::/10'
	];

	if (exclude_ipv4) {
		let filtered = [];

		for (let ip in ips)
			if (ip != exclude_ipv4)
				push(filtered, ip);

		ips = filtered;
	}

	return {
		type: 'field',
		ip: ips,
		outboundTag: 'direct'
	};
}

function source_value(ip) {
	if (index(ip, '/') >= 0)
		return ip;

	if (index(ip, ':') >= 0)
		return ip + '/128';

	return ip + '/32';
}

function domain_separator(ch) {
	return ch == ' ' || ch == "\n" || ch == "\r" || ch == "\t" || ch == ',' || ch == ';';
}

function add_domain_value(out, seen, domain) {
	domain = trim(lc('' + domain));

	if (length(domain) && !seen[domain]) {
		seen[domain] = true;
		push(out, domain);
	}
}

function add_scalar_domains(out, seen, value) {
	let text = '' + value;
	let token = '';

	for (let i = 0; i < length(text); i++) {
		let ch = substr(text, i, 1);

		if (domain_separator(ch)) {
			add_domain_value(out, seen, token);
			token = '';
		}
		else {
			token = token + ch;
		}
	}

	add_domain_value(out, seen, token);
}

function domain_values(s) {
	let value = opt(s, 'domain', []);
	let out = [];
	let seen = {};

	if (type(value) == 'array') {
		for (let domain in value)
			if (domain != null)
				add_domain_value(out, seen, domain);
	}
	else if (value != null) {
		add_scalar_domains(out, seen, value);
	}

	return out;
}

function is_ipv4_value(value) {
	return match(value, /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/);
}

function is_ipv6_value(value) {
	return index(value, ':') >= 0 && match(value, /^[0-9a-f:]+(\/[0-9]+)?$/);
}

function is_bypass_ip_value(value) {
	return is_ipv4_value(value) || is_ipv6_value(value);
}

function valid_bypass_domain(value) {
	return match(value, /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/);
}

function bypass_domain_values() {
	let out = [];
	let seen = {};

	for (let r in sections('bypass_rule', true)) {
		let value = trim(lc(opt(r, 'host', '')));

		if (!length(value))
			continue;

		if (substr(value, length(value) - 1, 1) == '.')
			value = substr(value, 0, length(value) - 1);

		if (is_bypass_ip_value(value))
			continue;

		if (index(value, '://') >= 0 || index(value, '/') >= 0 || index(value, ':') >= 0)
			die('invalid bypass entry: enter only domain, IP, or CIDR without scheme, path, or port');

		if (!valid_bypass_domain(value))
			die('invalid bypass domain: ' + value);

		add_domain_value(out, seen, value);
	}

	return out;
}

function transparent_inbound(main, fakedns_enabled) {
	let dest_override = [ 'http', 'tls', 'quic' ];

	if (fakedns_enabled)
		push(dest_override, 'fakedns');

	return {
		tag: 'transparent',
		port: intopt(main, 'transparent_port', 12345),
		protocol: 'dokodemo-door',
		settings: {
			network: 'tcp,udp',
			followRedirect: true
		},
		streamSettings: {
			sockopt: {
				tproxy: 'tproxy'
			}
		},
		sniffing: {
			enabled: true,
			destOverride: dest_override,
			routeOnly: false
		}
	};
}

function fakedns_inbound(main) {
	let default_listen = boolopt(main, 'fakedns_hijack_dns', false) ? '0.0.0.0' : '127.0.0.1';
	let listen = opt(main, 'fakedns_listen', '') || default_listen;

	return {
		tag: 'dns-in',
		listen: listen,
		port: intopt(main, 'fakedns_port', 1053),
		protocol: 'dokodemo-door',
		settings: {
			network: 'tcp,udp',
			address: '8.8.8.8',
			port: 53
		}
	};
}

function build_config() {
	let main = first_section('settings') || {};
	let proxies = collect_proxies(true, true);
	let groups = collect_groups();
	let state = read_state();
	let fakedns_enabled = boolopt(main, 'fakedns_enabled', false);
	let ipv6 = interception.settings(main).ipv6;
	let inbounds = [ transparent_inbound(main, fakedns_enabled) ];
	let rules = [];
	let outbounds = [
		{ tag: 'direct', protocol: 'freedom' },
		{ tag: 'blocked', protocol: 'blackhole' }
	];

	if (fakedns_enabled) {
		push(inbounds, fakedns_inbound(main));
		push(outbounds, {
			tag: 'dns-out',
			protocol: 'dns'
		});
		push(rules, {
			type: 'field',
			inboundTag: [ 'dns-in' ],
			outboundTag: 'dns-out'
		});
	}

	push(rules, private_direct_rule(fakedns_enabled ? opt(main, 'fakedns_pool_v4', '198.18.0.0/15') : ''));

	let bypass_domains = bypass_domain_values();
	if (length(bypass_domains)) {
		let domains = [];

		for (let domain in bypass_domains)
			push(domains, 'domain:' + require_value(domain, 'bypass domain'));

		push(rules, {
			type: 'field',
			domain: domains,
			outboundTag: 'direct'
		});
	}

	for (let p in proxies.list)
		push(outbounds, vless_outbound(p));

	let has_awg = false;
	for (let p in proxies.list) if (p.protocol == 'amneziawg') has_awg = true;
	if (has_awg) {
		let dns_target = real_dns_target(proxies, groups, state);
		// Xray skips FakeDNS for real target lookups. The real DNS transport
		// is routed through a connection, without a localhost/WAN fallback.
		unshift(rules, { type: 'field', inboundTag: [ 'awg-resolver' ], outboundTag: dns_target });
	}

	for (let d in sections('lan_device', true)) {
		let mode = opt(d, 'mode', 'rules_only');

		if (mode == 'direct') {
			push(rules, {
				type: 'field',
				source: [ source_value(require_value(opt(d, 'source_ip', ''), 'LAN source IP')) ],
				outboundTag: 'direct'
			});
		}
		else if (mode == 'full_proxy') {
			push(rules, {
				type: 'field',
				source: [ source_value(require_value(opt(d, 'source_ip', ''), 'LAN source IP')) ],
				outboundTag: resolve_target(opt(d, 'target', ''), proxies, groups, state)
			});
		}
	}

	for (let d in sections('domain_rule', true)) {
		let domains = domain_values(d);
		let target = resolve_target(opt(d, 'target', ''), proxies, groups, state);

		if (!length(domains))
			die('missing required value: domain');

		for (let domain in domains)
			push(rules, {
				type: 'field',
				domain: [ 'domain:' + require_value(domain, 'domain') ],
				outboundTag: target
			});
	}

	for (let r in sections('ip_rule', true)) {
		push(rules, {
			type: 'field',
			ip: [ require_value(opt(r, 'cidr', ''), 'CIDR') ],
			outboundTag: resolve_target(opt(r, 'target', ''), proxies, groups, state)
		});
	}

	let config = {
		log: {
			loglevel: opt(main, 'loglevel', 'warning')
		},
		inbounds: inbounds,
		outbounds: outbounds,
		routing: {
			domainStrategy: 'AsIs',
			rules: rules
		}
	};

	if (fakedns_enabled) {
		config.dns = {
			queryStrategy: ipv6 ? 'UseIP' : 'UseIPv4',
			servers: [ 'fakedns' ]
		};
		config.fakedns = {
			ipPool: opt(main, 'fakedns_pool_v4', '198.18.0.0/15'),
			poolSize: intopt(main, 'fakedns_pool_size', 65535)
		};
		if (ipv6) config.fakedns = [
			config.fakedns, { ipPool: '2001:2::/48', poolSize: intopt(main, 'fakedns_pool_size', 65535) }
		];
	}

	if (has_awg) {
		if (intopt(main, 'transparent_port', 12345) == 10085 ||
			(fakedns_enabled && intopt(main, 'fakedns_port', 1053) == 10085))
			die('port 10085 is reserved for local Podkopchik statistics');
		if (!config.dns) config.dns = { queryStrategy: 'UseIP', servers: [] };
		config.dns.tag = 'awg-resolver';
		if (ipv6) config.dns.queryStrategy = 'UseIP';
		let dns_ref = real_dns_target(proxies, groups, state);
		let dns_proxy = proxies.by_tag[dns_ref], ipv6_resolver = false;
		if (dns_proxy?.protocol == 'amneziawg') {
			let r = dns_proxy.resource, runtime = null;
			try { runtime = json(readfile('/tmp/podkopchik/awg/' + r.id + '.json') || '{}'); } catch (e) { }
			ipv6_resolver = runtime?.addresses && index(runtime.addresses, '.') < 0;
		}
		push(config.dns.servers, ipv6_resolver ? 'tcp://[2606:4700:4700::1111]' : 'tcp://1.1.1.1');
		config.stats = {};
		config.policy = { system: { statsOutboundUplink: true, statsOutboundDownlink: true } };
		config.api = { tag: 'podkopchik-api', services: [ 'StatsService' ] };
		push(config.inbounds, { tag: 'podkopchik-api-in', listen: '127.0.0.1', port: 10085,
			protocol: 'dokodemo-door', settings: { address: '127.0.0.1', network: 'tcp' } });
		unshift(config.routing.rules, { type: 'field', inboundTag: [ 'podkopchik-api-in' ], outboundTag: 'podkopchik-api' });
	}
	return config;
}

function health_config(outbound, port) {
	let config = {
		log: { loglevel: 'warning' },
		inbounds: [ {
			tag: 'health-in', listen: '127.0.0.1', port: int(port),
			protocol: 'socks', settings: { auth: 'noauth', udp: false }
		} ],
		outbounds: [ outbound, { tag: 'direct', protocol: 'freedom' } ],
		routing: {
			domainStrategy: 'AsIs',
			rules: [ { type: 'field', inboundTag: [ 'health-in' ], outboundTag: outbound.tag } ]
		}
	};
	if (outbound.protocol == 'freedom')
		config.dns = { tag: 'health-in', queryStrategy: 'UseIP', servers: [
			outbound.streamSettings?.sockopt?.domainStrategy == 'ForceIPv6' ? 'tcp://[2606:4700:4700::1111]' : 'tcp://1.1.1.1'
		] };
	return config;
}

function build_health_config(tag, port) {
	let proxies = collect_proxies(true, true);
	let p = proxies.by_tag[vless.clean_tag(tag, tag)];

	if (!p)
		die('unknown proxy for health check: ' + tag);

	return health_config(vless_outbound(p), port);
}

function load_results(path) {
	let results = {};
	let raw = readfile(path);

	if (!raw)
		return results;

	for (let line in split(raw, '\n')) {
		if (!length(line))
			continue;

		let cols = split(line, '\t');
		if (length(cols) >= 2)
			results[cols[0]] = {
				status: cols[1],
				message: length(cols) > 2 ? cols[2] : '',
				latency_ms: length(cols) > 3 && length(cols[3]) ? int(cols[3]) : null,
				external_ip: length(cols) > 4 ? cols[4] : '',
				checked_at: length(cols) > 5 ? int(cols[5]) : time()
			};
	}

	return results;
}

function status_after_probe(tag, result, prev, fail_threshold, restore_threshold) {
	prev = prev || {};
	let status = prev.status || 'unknown';
	let fail_count = int(prev.fail_count || 0);
	let success_count = int(prev.success_count || 0);
	let last_error = prev.last_error || '';

	if (!result || result.status == 'unknown' || !result.checked_at ||
		time() - result.checked_at < 0 || time() - result.checked_at >= 300) {
		return {
			status: 'unknown',
			fail_count: 0,
			success_count: 0,
			last_error: result ? (result.message || 'probe result unavailable or expired') : 'no probe result recorded'
		};
	}

	if (result.status == 'up') {
		success_count++;
		fail_count = 0;
		last_error = '';

		if (success_count >= restore_threshold)
			status = 'up';
	}
	else {
		fail_count++;
		success_count = 0;
		last_error = result.message || 'probe failed';

		if (fail_count >= fail_threshold)
			status = 'down';
	}

	return {
		status: status,
		fail_count: fail_count,
		success_count: success_count,
		last_error: last_error
	};
}

function freshly_up(p) {
	return p && p.status == 'up' && p.probe_status == 'up' && p.checked_at &&
		time() - p.checked_at >= 0 && time() - p.checked_at < 300;
}

function choose_first_up(refs, proxies_state) {
	for (let ref in refs) {
		let tag = ref ? vless.clean_tag(ref, ref) : null;
		if (!tag)
			continue;
		if (freshly_up(proxies_state[tag]))
			return tag;
	}

	return null;
}

function choose_group(g, proxies_state, prev_state, cooldown) {
	let previous = prev_state || {};
	let active = previous.active_proxy || null;
	let reason = 'configured_default';

	if (g.mode == 'fixed_proxy') {
		let fixed = g.fixed_proxy ? vless.clean_tag(g.fixed_proxy, g.fixed_proxy) : null;
		active = fixed;

		if (fixed && g.failure_action == 'switch_to_backup' && proxies_state[fixed] && proxies_state[fixed].status == 'down') {
			let backup = choose_first_up(g.backups, proxies_state);
			if (backup) {
				active = backup;
				reason = 'fixed_proxy_failed_switched_to_backup';
			}
			else {
				reason = 'fixed_proxy_failed_no_healthy_backup';
			}
		}
		else if (fixed && proxies_state[fixed] && proxies_state[fixed].status == 'down') {
			reason = 'fixed_proxy_down_warn_only';
		}
	}
	else {
		if (g.manual_override_proxy) {
			active = vless.clean_tag(g.manual_override_proxy, g.manual_override_proxy);
			reason = 'manual_override';
		}
		else {
			let primary = g.primary ? vless.clean_tag(g.primary, g.primary) : null;
			let primary_status = proxies_state[primary] ? proxies_state[primary].status : 'unknown';

			if (primary && freshly_up(proxies_state[primary]) && (g.auto_return || !active || active == primary)) {
				active = primary;
				reason = 'primary_healthy';
			}
			else if (primary && primary_status == 'up') {
				active = active || primary;
				reason = 'primary_healthy_auto_return_disabled';
			}
			else if (primary && primary_status == 'down') {
				let backup = choose_first_up(g.backups, proxies_state);
				if (backup) {
					active = backup;
					reason = 'primary_down_switched_to_backup';
				}
				else {
					active = 'blocked';
					reason = 'primary_down_no_healthy_backup';
				}
			}
			else {
				active = active || primary;
				reason = 'primary_unknown_keep_current';
				if (active && proxies_state[active]?.status == 'down') {
					active = choose_first_up(g.backups, proxies_state) || 'blocked';
					reason = active == 'blocked' ? 'no_healthy_connection' : 'current_down_switched_to_backup';
				}
			}
		}
	}
	if (g.mode != 'fixed_proxy' && !g.manual_override_proxy && proxies_state[active]?.status == 'down') {
		active = choose_first_up([ g.primary, ...g.backups ], proxies_state) || 'blocked';
		reason = active == 'blocked' ? 'no_healthy_connection' : 'current_down_switched_to_backup';
	}
	// Only delay a preference change while the current path is freshly healthy.
	// Never postpone escaping a failed path or blocking all-down traffic.
	let elapsed = time() - (previous.last_switch_time || 0);
	if (active != previous.active_proxy && freshly_up(proxies_state[previous.active_proxy]) &&
		active != 'blocked' && elapsed >= 0 && elapsed < cooldown) {
		active = previous.active_proxy;
		reason = 'switch_cooldown_keep_healthy';
	}

	return {
		active_proxy: active,
		reason: reason,
		last_switch_time: active != previous.active_proxy ? time() : (previous.last_switch_time || 0)
	};
}

function build_state(results_path) {
	let main = first_section('settings') || {};
	let proxies = collect_proxies(true, false);
	let groups = collect_groups();
	let old = read_state();
	let results = load_results(results_path);
	let proxy_state = {};
	let group_state = {};
	let events = [];
	let fail_threshold = max(2, intopt(main, 'fail_threshold', 3));
	let restore_threshold = max(2, intopt(main, 'restore_threshold', 2));
	let cooldown = max(0, min(3600, intopt(main, 'switch_cooldown', 60)));

	for (let p in proxies.list) {
		proxy_state[p.tag] = status_after_probe(
			p.tag,
			results[p.tag],
			old.proxies ? old.proxies[p.tag] : null,
			fail_threshold,
			restore_threshold
		);
		let result = results[p.tag];
		proxy_state[p.tag].checked_at = result ? result.checked_at : null;
		proxy_state[p.tag].probe_status = result ? result.status : 'unknown';
		proxy_state[p.tag].valid_for = 300;
		proxy_state[p.tag].latency_ms = result && result.status == 'up' ? result.latency_ms : null;
		proxy_state[p.tag].external_ip = result && result.status == 'up' ? result.external_ip : '';
		proxy_state[p.tag].protocol = p.protocol;
		proxy_state[p.tag].last_success_at = result && result.status == 'up' ? result.checked_at :
			(old.proxies?.[p.tag]?.last_success_at || null);
	}

	for (let g in groups.list) {
		let previous = old.groups ? old.groups[g.tag] : null;
		group_state[g.tag] = choose_group(g, proxy_state, previous, cooldown);

		// After reboot state is empty, but startup config already uses the
		// configured default. A first check selecting backup/blocked must apply
		// that decision too, not just record it and wait for another switch.
		let from = previous ? previous.active_proxy : default_group_proxy(g, proxies);
		if (from != group_state[g.tag].active_proxy) {
			push(events, 'group ' + g.tag + ' switched from ' + (from || 'none') + ' to ' + (group_state[g.tag].active_proxy || 'none') + ': ' + group_state[g.tag].reason);
		}
	}

	return {
		version: '0.1.0-beta',
		updated_at: time(),
		proxies: proxy_state,
		groups: group_state,
		events: events
	};
}

let mode = length(ARGV) ? ARGV[0] : 'config';
let obj;

if (mode == 'health') {
	obj = build_health_config(ARGV[1], ARGV[2] || 20800);
}
else if (mode == 'probe-uri') {
	let uri = getenv('PODKOPCHIK_PROBE_URI') || '';
	if (length(uri) > 16384)
		die('VLESS URI is too long');
	obj = health_config(vless_outbound({ tag: 'probe', parsed: vless.parse(uri) }), 20999);
}
else if (mode == 'probe-primary') {
	let primary = null;
	ctx.foreach(APP, 'proxy', function(s) {
		if (opt(s, 'role', '') == 'main' && boolopt(s, 'enabled', true)) {
			if (primary != null)
				die('select exactly one main proxy');
			primary = s;
		}
	});
	if (primary == null)
		die('select one main proxy');
	let p = collect_proxies(true, true).by_tag[proxy_tag(primary, 0)];
	obj = health_config(vless_outbound(p), 20999);
}
else if (mode == 'probe-tag') {
	let selected = null, idx = 0;
	ctx.foreach(APP, 'proxy', function(p) {
		if (proxy_tag(p, idx++) == vless.clean_tag(ARGV[1], ARGV[1])) {
			if (selected || opt(p, 'protocol', 'vless') != 'vless') die('unknown VLESS connection');
			selected = p;
		}
	});
	if (!selected) die('unknown VLESS connection');
	obj = health_config(vless_outbound({ tag: 'probe', parsed: vless.parse(opt(selected, 'uri', '')) }), 20999);
}
else if (mode == 'state') {
	if (ARGV[2]) state_file = ARGV[2];
	obj = build_state(ARGV[1]);
}
else if (mode == 'config-state') {
	state_file = ARGV[1] || STATE_FILE;
	obj = build_config();
}
else {
	obj = build_config();
}

printf('%J\n', obj);
