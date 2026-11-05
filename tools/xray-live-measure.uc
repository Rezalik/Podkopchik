'use strict';
// Operator-only, address-free measurements; never installed as application code.
const fs = require('fs');
function words(s) { return split(trim(s || ''), /[ \t\r\n]+/); }
function read(p) { return fs.readfile(p) || ''; }
if (trim(read('/tmp/sysinfo/board_name')) != 'xiaomi,redmi-router-ax6000-stock') die('wrong board\n');
let pids = [];
for (let p in fs.lsdir('/proc') || []) {
	if (!match(p, /^[0-9]+$/)) continue;
	let a = split(read('/proc/' + p + '/cmdline'), '\x00'), i = index(a, '-config');
	if (i >= 0 && a[i + 1] == '/etc/podkopchik/config.json' && index(a, 'run') >= 0 &&
		match(fs.readlink('/proc/' + p + '/exe') || '', /\/xray$/)) push(pids, p);
}
if (length(pids) != 1) die('expected one main Xray\n');
let pid = pids[0], base = '/proc/' + pid, fds = fs.lsdir(base + '/fd') || [], sockets = {}, inodes = {};
let types = { tcp: 0, udp: 0, unix: 0, file: 0, pipe: 0, anon_inode: 0, other: 0, raced: 0 };
let states = {}, udp = [];
for (let table in ['tcp', 'tcp6', 'udp', 'udp6', 'unix']) {
	let rows = split(read(base + '/net/' + table), '\n');
	for (let i = 1; i < length(rows); i++) {
		let w = words(rows[i]), n = table == 'unix' ? w[6] : w[9];
		if (n && n != '0') sockets[n] = { kind: substr(table, 0, 3) == 'tcp' ? 'tcp' : table == 'unix' ? 'unix' : 'udp', state: w[3] };
	}
}
for (let fd in fds) {
	let path = base + '/fd/' + fd, target = fs.readlink(path), m = match(target || '', /^socket:\[([0-9]+)\]$/);
	if (!target) types.raced++;
	else if (m) {
		let s = sockets[m[1]];
		if (!s) types.other++;
		else {
			types[s.kind]++;
			if (s.kind == 'tcp') states[s.state] = (states[s.state] || 0) + 1;
			if (s.kind == 'udp' && !inodes[m[1]]) push(udp, m[1]);
		}
		inodes[m[1]] = true;
	}
	else if (index(target, 'pipe:[') == 0) types.pipe++;
	else if (index(target, 'anon_inode:') == 0) types.anon_inode++;
	else if (fs.stat(path)?.type == 'file') types.file++;
	else types.other++;
}
let memory = {}, system = {};
for (let line in split(read(base + '/status'), '\n')) {
	let w = words(line), key = replace(w[0] || '', /:$/, '');
	if (index(['VmRSS', 'VmHWM', 'VmSize', 'Threads'], key) >= 0) memory[key] = +w[1];
}
for (let line in split(read('/proc/meminfo'), '\n')) {
	let w = words(line), key = replace(w[0] || '', /:$/, '');
	if (index(['MemAvailable', 'MemFree'], key) >= 0) system[key] = +w[1];
}
let stat = words(replace(read(base + '/stat'), /^[0-9]+ [(].*[)] /, ''));
let cpu = words(split(read('/proc/stat'), '\n')[0]), ticks = 0;
for (let i = 1; i <= 8; i++) ticks += +cpu[i];
let limits = match(read(base + '/limits'), /Max open files[ \t]+([0-9]+)[ \t]+([0-9]+)/);
let awg_traffic = { rx_bytes: 0, tx_bytes: 0, rx_packets: 0, tx_packets: 0 };
for (let device in fs.lsdir('/sys/class/net') || []) {
	if (!match(device, /^paw[a-f0-9]{12}$/)) continue;
	for (let key in keys(awg_traffic)) awg_traffic[key] += +trim(read('/sys/class/net/' + device + '/statistics/' + key));
}
printf('%J\n', {
	schema: 'podkopchik-xray-pilot-v1', epoch: time(), pid: +pid,
	router_uptime_seconds: +words(read('/proc/uptime'))[0], start_ticks: +stat[19],
	fd: length(fds), fd_at_end: length(fs.lsdir(base + '/fd') || []), types: types,
	tcp_state_hex: states, udp_inodes: udp, memory_kib: memory, system_kib: system,
	cpu_ticks: +stat[11] + +stat[12], system_cpu_ticks: ticks,
	conntrack: +trim(read('/proc/sys/net/netfilter/nf_conntrack_count')),
	conntrack_max: +trim(read('/proc/sys/net/netfilter/nf_conntrack_max')),
	fd_limit: limits ? +limits[1] : null,
	awg_traffic_totals: awg_traffic,
	limitations: ['Non-atomic procfs sample; only owned socket inodes are classified.',
		'TIME_WAIT normally has no process FD. CPU requires two samples of the same PID/start ticks.']
});
