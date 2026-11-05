'use strict';
// One-off AX6000 operator pilot. Not installed by Podkopchik or exposed to LuCI.
const fs = require('fs');
const mode = ARGV[0], dir = ARGV[1];
if (!match(dir || '', /^\/root\/podkopchik-xray-pilot-[A-Za-z0-9-]+$/)) die('invalid pilot directory\n');
if (trim(fs.readfile('/tmp/sysinfo/board_name') || '') != 'xiaomi,redmi-router-ax6000-stock') die('wrong board\n');
let st = fs.lstat(dir);
if (!st || st.type != 'directory' || st.uid != 0 || (st.mode & 0o077)) die('unsafe directory\n');
const temp = '/tmp/' + substr(dir, 6);
const core = '/usr/libexec/podkopchik-core';
const helper = '/usr/libexec/podkopchik/xray.sh';
function quote(s) { return "'" + replace('' + s, "'", "'\\''") + "'"; }
function run(cmd) {
	let p = fs.popen(cmd + ' 2>/dev/null', 'r');
	if (!p) die('cannot execute diagnostic\n');
	let out = p.read('all'), rc = p.close();
	if (rc != 0) die('pilot command failed: ' + cmd + '\n');
	return out;
}
function write(path, text) {
	let f = fs.open(path + '.new', 'w', 0o600);
	if (!f || f.write(text) != length(text) || !f.flush() || !f.close() || !fs.rename(path + '.new', path)) die('write failed\n');
}
function load() { return json(fs.readfile(dir + '/state.json')); }
function save(s) { write(dir + '/state.json', sprintf('%J\n', s)); }
function hash(path) { return split(trim(run('sha256sum ' + quote(path))), ' ')[0]; }
function pause(n) { run('sleep ' + n); }
function validate_staging() {
	let parent = fs.lstat(temp);
	if (!parent || parent.type != 'directory' || parent.uid != 0 || (parent.mode & 0o077)) die('unsafe RAM staging\n');
	for (let name in ['xray', 'xray.sh']) {
		let f = fs.lstat(temp + '/' + name);
		if (!f || f.type != 'file' || f.uid != 0 || f.nlink != 1 || (f.mode & 0o022)) die('unsafe staged file\n');
	}
}
function main() {
	let found = [];
	for (let p in fs.lsdir('/proc') || []) {
		if (!match(p, /^[0-9]+$/)) continue;
		let a = split(fs.readfile('/proc/' + p + '/cmdline') || '', '\x00'), i = index(a, '-config');
		if (i >= 0 && a[i + 1] == '/etc/podkopchik/config.json' && index(a, 'run') >= 0 &&
			match(fs.readlink('/proc/' + p + '/exe') || '', /\/xray$/)) push(found, p);
	}
	return length(found) == 1 ? found[0] : null;
}
function instance(binary) {
	return { name: 'podkopchik', instances: { xray: {
		command: [binary, 'run', '-config', '/etc/podkopchik/config.json'],
		term_timeout: 5, limits: { nofile: '16384 16384' },
		respawn: ['3600', '5', '5'], stdout: true, stderr: true
	} } };
}
function service(action, value) { run('ubus call service ' + action + ' ' + quote(sprintf('%J', value))); }
function snapshot(s, label) {
	let text = run('ucode ' + quote(dir + '/measure.uc')), m = json(text);
	if (!m.pid || m.fd_limit != 16384) die('invalid resource sample\n');
	write(dir + '/sample-' + m.epoch + '-' + label + '.json', text);
	return m;
}
function unlock_runtime() {
	for (let name in ['config-apply.lock', 'health-check.lock']) {
		let path = '/tmp/podkopchik/' + name;
		if (trim(fs.readfile(path + '/pilot-owner') || '') != dir) continue;
		fs.unlink(path + '/pid'); fs.unlink(path + '/pilot-owner'); fs.rmdir(path);
	}
}
function lock_runtime() {
	for (let name in ['config-apply.lock', 'health-check.lock']) {
		let path = '/tmp/podkopchik/' + name;
		if (!fs.mkdir(path, 0o700)) { unlock_runtime(); die('apply or health busy; retry later\n'); }
		write(path + '/pilot-owner', dir + '\n');
		if (name == 'health-check.lock') write(path + '/pid', split(fs.readfile('/proc/self/stat'), ' ')[0] + '\n');
	}
}
function cleanup_observer() {
	if (!fs.lstat(dir + '/observe.owner')) return;
	let data = json(run('nft -j list table inet podkopchik_udp_pilot_audit')), owned = false;
	for (let row in data.nftables || []) if (row.table?.comment == substr(dir, 6)) owned = true;
	if (!owned) die('observer table ownership mismatch\n');
	run('nft delete table inet podkopchik_udp_pilot_audit');
	fs.unlink(dir + '/observe.owner');
}
function observer_counters() {
	let d = json(run('nft -j list table inet podkopchik_udp_pilot_audit')), result = {}, owned = false;
	for (let row in d.nftables || []) {
		if (row.table?.comment == substr(dir, 6)) owned = true;
		if (row.rule?.comment) for (let e in row.rule.expr || []) if (e.counter) result[row.rule.comment] = e.counter;
	}
	if (!owned) die('observer table ownership mismatch\n');
	return result;
}
function restore() {
	// Do not replay old UCI, profiles, routes, DNS or nft state over live intent.
	let s = load();
	if (s.phase == 'rolled_back') return;
	if (hash('/usr/bin/xray') != s.original_sha) die('original package executable changed; manual recovery required\n');
	write(helper, fs.readfile(dir + '/helper.original'));
	fs.chmod(helper, 0o755);
	if (s.selector_present) write(core + '/selected', fs.readfile(dir + '/selector.original'));
	else fs.unlink(core + '/selected');
	if (trim(run('uci -q get podkopchik.main.routing_enabled')) == '1') {
		run('/usr/bin/xray run -test -config /etc/podkopchik/config.json');
		service('add', instance('/usr/bin/xray'));
		let ready = false;
		for (let i = 0; i < 20; i++) {
			pause(1); let p = main();
			if (p && fs.readlink('/proc/' + p + '/exe') == '/usr/bin/xray') { ready = true; break; }
		}
		if (!ready) die('old core failed to restart\n');
	}
	else service('delete', {name: 'podkopchik', instance: 'xray'});
	s.phase = 'rolled_back'; s.restored_at = time(); save(s);
	unlock_runtime();
	if (fs.lstat(core + '/xray') && hash(core + '/xray') == s.candidate_sha) fs.unlink(core + '/xray');
	fs.rmdir(core);
	cleanup_observer();
}
function lock() {
	let f = fs.open(dir + '/action.lock', 'a+', 0o600);
	if (!f || !f.lock('xn')) return null;
	return f;
}
if (mode == 'prepare') {
	if (fs.lstat(dir + '/state.json')) die('already prepared\n');
	validate_staging();
	if (fs.lstat(temp + '/xray.original')) die('original backup already exists\n');
	let managed = fs.lstat(core);
	if (managed && (managed.type != 'directory' || managed.uid != 0 || (managed.mode & 0o022))) die('unsafe managed-core directory\n');
	if (trim(run('uci -q get podkopchik.main.routing_enabled')) != '1') die('routing must already be enabled\n');
	let pid = main();
	if (!pid || fs.readlink('/proc/' + pid + '/exe') != '/usr/bin/xray') die('package main required\n');
	if (fs.lstat(core + '/xray') || fs.lstat(core + '/previous')) die('existing managed core must be reviewed separately\n');
	if (fs.lstat(core + '/selected') && trim(fs.readfile(core + '/selected')) != 'package') die('non-package selection\n');
	let s = { phase: 'prepared', original_pid: +pid, original_sha: hash('/usr/bin/xray'),
		candidate_sha: hash(temp + '/xray'), armed_at: time(), switch_deadline: time() + 600,
		observation_seconds: 21600, final_deadline: time() + 28800,
		selector_present: !!fs.lstat(core + '/selected') };
	if (s.candidate_sha != 'f8ba3bf3c5023817ad0cd413e1f44324d5a9c9d7aba806663e9ed63b418858c8') die('unexpected candidate\n');
	write(dir + '/helper.original', fs.readfile(helper));
	if (s.selector_present) write(dir + '/selector.original', fs.readfile(core + '/selected'));
	// Keep the original package untouched; retain an additional copy in RAM.
	// A hard link on overlayfs could unexpectedly copy up a lower-layer file.
	run('cp /usr/bin/xray ' + quote(temp + '/xray.original'));
	if (hash(temp + '/xray.original') != s.original_sha) die('original binary backup mismatch\n');
	run('tar -czf ' + quote(dir + '/config-backup.tar.gz') + ' -C / etc/config/podkopchik etc/podkopchik etc/config/network etc/config/wireless etc/config/firewall etc/config/dropbear etc/init.d/podkopchik usr/libexec/podkopchik/xray.sh');
	fs.chmod(dir + '/config-backup.tar.gz', 0o600);
	let commands = { nft: 'nft -s list table inet podkopchik', rules4: 'ip -4 rule show', rules6: 'ip -6 rule show',
		routes4: 'ip -4 route show table all', routes6: 'ip -6 route show table all',
		default4: 'ip -4 route show default', default6: 'ip -6 route show default' };
	for (let key, cmd in commands) write(dir + '/' + key + '.before', run(cmd));
	s.config_sha = hash('/etc/podkopchik/config.json'); s.uci_sha = hash('/etc/config/podkopchik');
	save(s); snapshot(s, 'before');
	print('prepared; backup and samples remain root-only\n');
}
else if (mode == 'arm') {
	let s = load(); if (s.phase != 'prepared') die('invalid phase\n');
	service('set', { name: 'podkopchik-xray-pilot-watch', instances: { watch: {
		command: ['ucode', dir + '/pilot.uc', 'watch', dir],
		respawn: ['3600', '1', '3'], stdout: false, stderr: false
	} } });
	print('independent watchdog armed\n');
}
else if (mode == 'promote') {
	let held = lock(); if (!held) die('pilot action busy\n');
	let s = load(); if (s.phase != 'prepared' || time() >= s.switch_deadline) die('invalid promotion phase\n');
	let services = json(run("ubus call service list '{\"name\":\"podkopchik-xray-pilot-watch\"}'"));
	if (!services['podkopchik-xray-pilot-watch']?.instances?.watch?.running) die('watchdog absent\n');
	try {
		validate_staging();
		run(quote(temp + '/xray') + ' run -test -config /etc/podkopchik/config.json');
		if (hash(temp + '/xray') != s.candidate_sha) die('candidate changed\n');
		if (hash(temp + '/xray.sh') != '45944d702062856e3938852b8cb5bc918cb12711b13372d13fd84579365d16e3') die('unexpected selector helper\n');
		lock_runtime();
		fs.mkdir(core, 0o755);
		// Keep an incompressible rollback reserve while probing UBIFS compression.
		// A staging failure cannot affect the running package binary or selector.
		run('dd if=/dev/urandom of=' + quote(dir + '/space.reserve') + ' bs=1048576 count=8');
		run('cp ' + quote(temp + '/xray') + ' ' + quote(core + '/xray.pilot-new'));
		fs.unlink(dir + '/space.reserve');
		let free = +split(trim(run("df -Pk /overlay | tail -1")), /[ \t]+/)[3];
		if (free < 8192 || hash(core + '/xray.pilot-new') != s.candidate_sha) die('insufficient flash reserve or bad staged binary\n');
		fs.chmod(core + '/xray.pilot-new', 0o755);
		if (!fs.rename(core + '/xray.pilot-new', core + '/xray')) die('cannot promote core\n');
		write(helper, fs.readfile(temp + '/xray.sh')); fs.chmod(helper, 0o755);
		write(core + '/selected', 'local\n');
		s.phase = 'switching'; s.switched_at = time(); save(s);
		service('add', instance(core + '/xray'));
		let ready = false;
		for (let i = 0; i < 30; i++) { pause(1); let p = main(); if (p && fs.readlink('/proc/' + p + '/exe') == core + '/xray') { ready = true; break; } }
		if (!ready) die('candidate main not ready\n');
		run('sh /usr/libexec/podkopchik/routing_safety.sh ready');
		s.phase = 'trial'; s.started_at = time(); s.current_pid = +main(); save(s); snapshot(s, 'started');
		unlock_runtime();
		print('candidate running; six-hour observation pending\n');
	}
	catch (e) { fs.unlink(dir + '/space.reserve'); fs.unlink(core + '/xray.pilot-new'); s.failure = 'promotion failed'; save(s); restore(); die('promotion failed; stock restoration requested\n'); }
	held.close();
}
else if (mode == 'rollback') {
	let held = lock(); if (!held) die('pilot action busy\n'); restore(); held.close();
	print('stock executable restored; settings/routing were not replayed\n');
}
else if (mode == 'observe') {
	let held = lock(); if (!held) die('pilot action busy\n');
	if (load().phase != 'trial') die('trial required\n');
	let p = fs.popen('nft list table inet podkopchik_udp_pilot_audit 2>/dev/null', 'r');
	p.read('all'); if (p.close() == 0) die('observer table already exists\n');
	let c = json(fs.readfile('/etc/podkopchik/config.json'));
	let defaults = json(run('ip -4 -j route show default')), wan = defaults?.[0]?.dev;
	let lan = trim(run('uci -q get podkopchik.main.lan_ifname'));
	if (!match(wan || '', /^[A-Za-z0-9_.-]+$/) || !match(lan, /^[A-Za-z0-9_.-]+$/)) die('invalid observer interface\n');
	let text = 'add table inet podkopchik_udp_pilot_audit { comment "' + substr(dir, 6) + '"; }\n';
	text += 'add chain inet podkopchik_udp_pilot_audit output { type filter hook output priority -5; policy accept; }\n';
	text += 'add chain inet podkopchik_udp_pilot_audit forward { type filter hook forward priority -5; policy accept; }\n';
	text += 'add chain inet podkopchik_udp_pilot_audit prerouting { type filter hook prerouting priority -301; policy accept; }\n';
	text += 'add chain inet podkopchik_udp_pilot_audit postrouting { type filter hook postrouting priority 300; policy accept; }\n';
	text += 'add rule inet podkopchik_udp_pilot_audit prerouting iifname "' + lan + '" ip daddr 198.18.0.0/15 meta l4proto tcp counter comment "fake_tcp_from_lan"\n';
	text += 'add rule inet podkopchik_udp_pilot_audit forward iifname "' + lan + '" oifname "' + wan + '" ip daddr 198.18.0.0/15 counter comment "fake_forwarded_to_wan"\n';
	for (let proto in ['tcp', 'udp', 'icmp']) text += 'add rule inet podkopchik_udp_pilot_audit postrouting oifname "' + wan + '" ip daddr 198.18.0.0/15 meta l4proto ' + proto + ' counter comment "fake_' + proto + '_post_wan"\n';
	let n = 0;
	for (let o in c.outbounds || []) if (o.protocol == 'freedom' && match(o.tag || '', /^awg_/)) {
		let opt = o.streamSettings.sockopt;
		if (!match(opt.interface || '', /^paw[a-f0-9]{12}$/) || !opt.mark) die('invalid AWG observer target\n');
		text += 'add rule inet podkopchik_udp_pilot_audit output meta mark ' + opt.mark + ' oifname "' + wan + '" counter comment "protected_mark_to_wan_' + n + '"\n';
		text += 'add rule inet podkopchik_udp_pilot_audit postrouting meta mark ' + opt.mark + ' oifname "' + wan + '" counter comment "protected_mark_post_wan_' + n + '"\n';
		text += 'add rule inet podkopchik_udp_pilot_audit output meta mark ' + opt.mark + ' oifname "' + opt.interface + '" meta l4proto tcp counter comment "protected_tcp_to_awg_' + n + '"\n';
		text += 'add rule inet podkopchik_udp_pilot_audit output meta mark ' + opt.mark + ' oifname "' + opt.interface + '" meta l4proto udp counter comment "protected_udp_to_awg_' + n + '"\n';
		n++;
	}
	write(dir + '/observe.nft', text);
	run('nft -c -f ' + quote(dir + '/observe.nft'));
	write(dir + '/observe.owner', substr(dir, 6) + '\n');
	run('nft -f ' + quote(dir + '/observe.nft'));
	held.close(); print('counter-only observer active; no verdict/mark/route modifications\n');
}
else if (mode == 'observe-status') {
	printf('%J\n', observer_counters());
}
else if (mode == 'watch') {
	let last_sample = 0, misses = 0, dns_failures = 0, last_dns = 0;
	while (true) {
		let s = load();
		if (s.phase == 'selftest') {
			if (time() >= s.final_deadline) { write(dir + '/fixture', fs.readfile(dir + '/fixture.original')); s.phase = 'rolled_back'; save(s); }
			pause(1); continue;
		}
		if (index(['rolled_back', 'accepted'], s.phase) >= 0) { pause(30); continue; }
		let reason = null, p = main();
		if (time() >= s.final_deadline) reason = 'unaccepted trial deadline';
		if (s.phase == 'prepared' && time() >= s.switch_deadline) reason = 'promotion deadline';
		if (s.phase == 'trial' || (s.phase == 'switching' && time() > s.switched_at + 45)) {
			if (!p || fs.readlink('/proc/' + p + '/exe') != core + '/xray') misses++; else misses = 0;
			if (misses >= 2) reason = 'candidate main absent or unexpectedly replaced';
			if (p && length(fs.lsdir('/proc/' + p + '/fd') || []) >= 14000) reason = 'FD safety threshold';
			if (time() - last_dns >= 60) {
				try { let a = run('nslookup -timeout=2 -retry=1 -port=1053 x.com 127.0.0.1'); if (!match(a, /198\.(18|19)\./)) dns_failures++; else dns_failures = 0; }
				catch (e) { dns_failures++; }
				last_dns = time(); if (dns_failures >= 3) reason = 'repeated FakeDNS failure';
				if (fs.lstat(dir + '/observe.owner')) {
					try {
						for (let name, c in observer_counters()) if (c.packets > 0 &&
							(name == 'fake_tcp_post_wan' || name == 'fake_udp_post_wan' || index(name, 'protected_mark_post_wan_') == 0)) reason = 'WAN boundary counter failure';
					}
					catch (e) { reason = 'observer validation failure'; }
				}
			}
			if (s.phase == 'trial' && time() - last_sample >= 300) {
				try { let m = snapshot(s, 'watch'); if (m.system_kib.MemAvailable < 24576) reason = 'low RAM'; }
				catch (e) { reason = 'resource measurement failed'; }
				last_sample = time();
				if (time() - s.started_at >= s.observation_seconds && !s.observation_complete_at) { s.observation_complete_at = time(); save(s); }
			}
		}
		if (reason || fs.lstat(dir + '/recover-now')) {
			let held = lock();
			if (held) { s = load(); s.failure = reason || 'operator recovery'; save(s); try { restore(); } catch (e) { write(dir + '/restore-failed', 'independent recovery needs attention\n'); } held.close(); }
		}
		pause(10);
	}
}
else if (mode == 'accept') {
	let held = lock(); if (!held) die('pilot action busy\n'); let s = load();
	if (s.phase != 'trial' || !s.observation_complete_at || fs.lstat(dir + '/recover-now')) die('observation not complete\n');
	cleanup_observer();
	s.phase = 'accepted'; s.accepted_at = time(); save(s); held.close();
	service('delete', {name: 'podkopchik-xray-pilot-watch'});
}
else if (mode == 'status') {
	let s = load(); printf('%J\n', s);
}
else die('usage: prepare|arm|promote|watch|rollback|observe|observe-status|accept|status PRIVATE_DIR\n');
