'use strict';

import * as fs from 'fs';

// A single private journal serializes verify, confirm and timeout decisions.
// Callers own snapshot validation, health checks and actual restoration.
const action = ARGV[0], dir = ARGV[1];
const meta = fs.lstat(dir || '');
if (!meta || meta.type != 'directory' || meta.uid != 0 || (meta.mode & 0o077))
	die('trial directory is not private and root-owned\n');
const path = dir + '/trial.json';
const lock = fs.open(dir + '/trial.lock', 'a+', 0o600);
if (!lock || !lock.lock('x')) die('cannot acquire trial lock\n');

const boot = trim(fs.readfile('/proc/sys/kernel/random/boot_id') || '');
const raw = split(fs.readfile('/proc/uptime') || '', '.')[0];
if (!match(boot, /^[a-f0-9-]{36}$/) || !match(raw, /^[0-9]+$/)) die('cannot read boot identity and clock\n');
const now = +raw;
function save(state) {
	const temp = path + '.new';
	if (fs.lstat(temp) && !fs.unlink(temp)) die('cannot clear unfinished journal write\n');
	const f = fs.open(temp, 'wx', 0o600);
	const data = sprintf('%J\n', state);
	if (!f || f.write(data) != length(data) || !f.flush() || !f.close() || !fs.rename(temp, path) || system(['sync']) != 0)
		die('cannot persist trial journal\n');
}

if (action == 'arm') {
	const timeout = ARGV[2];
	if (fs.lstat(path) || !match(timeout || '', /^[0-9]{1,4}$/) || +timeout < 5 || +timeout > 3600)
		die('trial already armed or invalid timeout\n');
	save({ schema: 1, boot, deadline: now + +timeout, state: 'armed' });
	return;
}

const s = json(fs.readfile(path) || '{}');
if (s.schema != 1 || !match(s.boot || '', /^[a-f0-9-]{36}$/) || type(s.deadline) != 'int' ||
	index(['armed', 'verified', 'confirmed', 'rollback', 'restored'], s.state) < 0)
	die('invalid trial journal\n');
const expired = s.boot != boot || now >= s.deadline;
if (action == 'poll') {
	if (expired && index(['armed', 'verified'], s.state) >= 0) {
		s.state = 'rollback'; save(s);
	}
	print((index(['armed', 'verified'], s.state) >= 0 ? 'waiting' : s.state) + '\n');
}
else if (action == 'verify' && s.state == 'armed' && !expired) { s.state = 'verified'; save(s); }
else if (action == 'confirm' && s.state == 'verified' && !expired) { s.state = 'confirmed'; save(s); }
else if (action == 'abort' && index(['armed', 'verified'], s.state) >= 0) { s.state = 'rollback'; save(s); }
else if (action == 'restored' && s.state == 'rollback') { s.state = 'restored'; save(s); }
else die('trial transition refused\n');
