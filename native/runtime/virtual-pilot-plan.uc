'use strict';

// Render only. The caller owns admission of live routes, fw4 and the watchdog.
import { readfile } from 'fs';
const pool = require('native_pool');
const guard = require('fakedns_guard');
const mode = ARGV[0], file = ARGV[1];
const p = json(readfile(file || '', 262145) || '{}');
const client = '172.31.252.2', gateway = '172.31.252.1', subnet = '172.31.252.0/30';
const synthetic = '172.31.253.0/24', mark = '0x504b0901', routeTable = 48181, priority = 11581;
const table = 'inet pkc_virtual_guard';
const hooks = [
	['source', 'filter', 'prerouting', -307], ['dns', 'nat', 'prerouting', -163],
	['classify', 'filter', 'prerouting', -151], ['translate', 'nat', 'prerouting', -104],
	['input', 'filter', 'input', -13], ['forward', 'filter', 'forward', -13],
	['nat', 'nat', 'postrouting', 98], ['egress', 'filter', 'postrouting', 301],
];
if (!match(p.epoch || '', /^[0-9a-f]{16}$/) || !match(p.awg || '', /^paw[0-9a-f]{12}$/) ||
	!match(p.wan || '', /^[a-zA-Z0-9_.-]{1,15}$/) || index(['lo', 'br-lan', p.awg], p.wan) >= 0)
	die('invalid virtual pilot interfaces');
const port = 'pv' + substr(p.epoch, 0, 12), owner = 'pkc-virtual-' + p.epoch;
if (p.wan == port) die('conflicting virtual pilot interface');
const set = 's_' + p.epoch;
// An already registered, owned blackhole for this exact pool is not a real
// network overlap. The arm script separately checks the live guard.
if (type(p.inventory?.rules) != 'array') die('missing pilot policy rules');
const occupied = pool.inventory({ ...p.inventory, rules: filter(p.inventory.rules, r =>
	r.priority != 10992 || index(r.dst || '', ':') >= 0 || guard.rule_pool(r, '-4') != synthetic) }, true);
if (!length(filter(p.inventory.addresses, l => l.ifname == p.awg && length(filter(l.addr_info, a => a.family == 'inet')))) ||
	!length(filter(p.inventory.routes, r => r.dst == 'default' && (!r.table || r.table == 'main' || +r.table == 254) && r.dev == p.wan)))
	die('pilot requires an existing IPv4 AWG interface and the actual WAN');
if (type(p.nft_chains) != 'array' || length(p.nft_chains) > 1024) die('missing firewall hook inventory');
for (let c in p.nft_chains) if (index(['ip', 'inet'], c.family) >= 0 && c.hook &&
	length(filter(hooks, h => h[2] == c.hook && h[3] == c.prio))) die('virtual nft hook priority is occupied');
if (length(filter(p.nft_chains, c => c.family == 'inet' && c.table == 'fw4' &&
	index(['input', 'forward'], c.name) >= 0 && c.hook == c.name && c.type == 'filter' && c.prio >= 0)) != 2)
	die('missing expected firewall4 base chains');
if (pool.overlaps(synthetic, occupied) || pool.overlaps(subnet, occupied)) die('virtual pilot networks overlap inventory');
for (let r in p.inventory.rules) if (r.priority == priority || +r.table == routeTable || r.iif == port || r.oif == port ||
	(r.fwmark != null && ((+r.fwmark ^ +mark) & +(r.fwmask ?? 0xffffffff)) == 0)) die('virtual policy resources conflict');
for (let r in p.inventory.routes) if (+r.table == routeTable) die('virtual route table is occupied');
const direct = split(pool.prefix(p.direct), '/')[0];
if (direct != p.direct || pool.family(direct) != '4' || pool.overlaps(pool.prefix(direct), [...occupied, synthetic, subnet]))
	die('invalid direct test destination');
if (!match(p.protected || '', /^[a-z0-9-]+(\.[a-z0-9-]+)+$/) || length(p.protected) > 253 ||
	!match(p.upstream || '', /^127\.0\.0\.1:[0-9]{1,5}$/) || +split(p.upstream, ':')[1] < 1 || +split(p.upstream, ':')[1] > 65535)
	die('invalid pilot DNS inputs');
const names = [p.protected];
if (p.udp != null) {
	let echo = pool.prefix(p.udp);
	if (pool.family(echo) != '4' || echo != p.udp + '/32' ||
		pool.overlaps(echo, [...occupied, synthetic, subnet, pool.prefix(direct)]) ||
		type(p.udp_port) != 'int' || p.udp_port < 1024 || p.udp_port > 65535)
		die('invalid controlled UDP echo endpoint');
	push(names, 'echo.pkc.invalid');
}
if (p.window != null && (type(p.window) != 'array' || length(p.window) != 2 ||
	type(p.window[0]) != 'int' || type(p.window[1]) != 'int' ||
	p.window[0] < 3 || p.window[0] > p.window[1] - 3 || p.window[1] > 254))
	die('invalid or insufficient reserved pilot address window');
if (p.udp != null && p.window == null) die('controlled pilot requires a fresh address window');

if (mode == 'dns') {
	print(sprintf('%J\n', { epoch: p.epoch, virtual: true, listen: gateway + ':24053', upstream: p.upstream,
		...(p.window == null ? {} : { virtual_window: p.window }),
		pools: [synthetic], private_pool: synthetic, retired_pools: map(p.inventory.issued, pool.prefix),
		exclusions: [pool.prefix(direct), ...occupied],
		groups: [{ names, protected: true }] }));
}
else if (mode == 'resources') {
	printf('%J\n', { port, owner, mark, route_table: routeTable, priority, device: p.awg });
}
else if (mode == 'nft') {
	let lines = ['create table ' + table + ' { comment "' + owner + '"; }'];
	function chain(name, type, hook, prio) {
		push(lines, 'add chain ' + table + ' ' + name + ' { type ' + type + ' hook ' + hook + ' priority ' + prio + '; policy accept; }');
	}
	function rule(chain, expression) { push(lines, 'add rule ' + table + ' ' + chain + ' ' + expression); }
	const iface = 'iifname "' + port + '" ', src = iface + 'ip saddr ' + client + ' ';
	const flow = iface + 'meta nfproto ipv4 ct direction original ct original ip saddr ' + client + ' ';
	const awg = 'oifname "' + p.awg + '" ', wan = 'oifname "' + p.wan + '" ';
	const authorized = 'meta mark ' + mark + ' ct mark ' + mark + ' ct status dnat ';
	const protected = flow + 'ct original ip daddr @' + set + '_g0_4 ' + authorized + awg;
	const directFlow = flow + 'ct original ip daddr ' + direct + ' ip daddr ' + direct + ' meta l4proto { tcp, udp } th dport != 53 ' + wan;
	const dns = src + 'ip daddr ' + gateway + ' meta l4proto { tcp, udp } th dport 24053 ct status dnat ct original proto-dst 53 ';
	const ret = 'oifname "' + port + '" ip daddr ' + client + ' ct direction reply ct original ip saddr ' + client + ' ct state established ';
	const awgRet = ret + 'iifname "' + p.awg + '" ct status dnat ct mark ' + mark + ' ';
	const protectedRet = awgRet + 'ct original ip saddr @' + set + '_live4 ct original ip daddr @' + set + '_g0_4 ';
	const directRet = ret + 'iifname "' + p.wan + '" ct original ip daddr ' + direct + ' ';
	const proto = 'meta l4proto { tcp, udp } ';
	for (let row in hooks) chain(row[0], row[1], row[2], row[3]);
	push(lines, 'add map ' + table + ' ' + set + '_m4 { type ipv4_addr : ipv4_addr; flags timeout; size 254; }');
	for (let row in [[set + '_g0_4', 254], [set + '_live4', 1]])
		push(lines, 'add set ' + table + ' ' + row[0] + ' { type ipv4_addr; flags timeout; size ' + row[1] + '; }');
	// Interface-only negative guards reject spoofed/IPv6 input before conntrack.
	rule('source', iface + 'meta nfproto != ipv4 counter drop');
	rule('source', iface + 'ip saddr != ' + client + ' counter drop');
	rule('dns', src + proto + 'th dport 53 dnat ip to ' + gateway + ':24053');
	rule('classify', src + 'ip saddr @' + set + '_live4 ip daddr @' + set + '_g0_4 ' + proto +
		'ct mark set ' + mark + ' meta mark set ' + mark + ' counter accept');
	rule('classify', src + 'ip daddr { ' + synthetic + ', 198.18.0.0/15 } counter drop');
	rule('translate', src + 'meta mark ' + mark + ' ip daddr ' + synthetic + ' dnat ip to ip daddr map @' + set + '_m4');
	rule('input', dns + 'counter return');
	rule('input', src + 'counter drop');
	// Recheck original tuples after DNAT and again after source NAT. A missing
	// route, map or mark can never authorize protected forwarding via WAN.
	for (let hook in ['forward', 'egress']) {
		rule(hook, flow + proto + 'ct original proto-dst 53 counter drop');
		rule(hook, flow + 'ip daddr { ' + synthetic + ', 198.18.0.0/15 } counter drop');
		rule(hook, protected + 'counter return');
		rule(hook, directFlow + 'counter return');
		rule(hook, flow + 'counter drop');
		rule(hook, protectedRet + 'counter return');
		rule(hook, directRet + 'counter return');
		if (hook == 'egress')
			rule(hook, ret + 'ct status dnat ' + proto + 'ct original proto-dst 53 ct reply ip saddr ' +
				gateway + ' ct reply proto-src 24053 counter return');
		rule(hook, 'oifname "' + port + '" counter drop');
	}
	rule('forward', src + 'counter drop');
	rule('nat', src + authorized + awg + 'masquerade');
	rule('nat', src + 'ip daddr ' + direct + ' ' + proto + wan + 'masquerade');
	// Do not reload or replace firewall4. Every inserted allow is either from
	// the exact virtual sender, or a tracked reply back to that same sender.
	const forwardPilot = flow + 'ct original ip daddr ' + synthetic + ' ' + authorized + awg;
	for (let row in [['input', dns], ['forward', forwardPilot], ['forward', directFlow],
		['forward', awgRet + 'ct original ip daddr ' + synthetic + ' '], ['forward', directRet]])
		push(lines, 'insert rule inet fw4 ' + row[0] + ' ' + row[1] + 'counter accept comment "' + owner + '"');
	print(join('\n', lines) + '\n');
}
else die('invalid virtual pilot plan operation');
