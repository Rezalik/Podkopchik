'use strict';

import * as fs from 'fs';
const awg = require('awg');
const root = ARGV[0] + '/awg';
const owner = fs.stat(ARGV[0]).uid;
const db = awg.store(root, owner);
let tests = 0;
function check(value, label) {
	if (!value) die('FAIL: ' + label);
	tests++;
}
// Deterministic synthetic bytes, not keys belonging to any server or user.
let bytes = '';
for (let i = 1; i <= 32; i++) bytes += chr(i);
const synthetic = b64enc(bytes);
const base = '[Interface]\nPrivateKey = ' + synthetic + '\n' +
	'Address = 10.66.0.2/32, fd00::2/128\nDNS = 1.1.1.1, resolver.example\n' +
	'MTU = 1280\nListenPort = 0\nFwMark = off\n' +
	'Jc = 3\nJmin = 40\nJmax = 100\nS1 = 12\nS2 = 12\nS3 = 12\nS4 = 12\n' +
	'H1 = 10-20\nH2 = 21-30\nH3 = 31-40\nH4 = 41-50\n' +
	'HeaderProtectionKey = ' + synthetic + '\nContentPaddingAddition = 0-4\n' +
	'RekeyAfterTime = 100-120\nRekeyTimeout = 4-8\nRejectAfterTime = 180\n' +
	'KeepaliveTimeout = 8-12\nMaxHandshakeAttempts = 10-20\nRandomTrailers = on\nDisableCookies = 1\n' +
	'I1 = <b 0x1234><r 4><rc 4><rd 4><c><t>\n' +
	'I2 = <r 4>\nI3 = <rc 4>\nI4 = <rd 4>\nI5 = <t>\n' +
	'[Peer]\nPublicKey = ' + synthetic + '\nPresharedKey = ' + synthetic + '\n' +
	'Endpoint = vpn.example:51820\nAllowedIPs = 0.0.0.0/0, ::/0\n' +
	'PersistentKeepalive = 20-25\nAdvancedSecurity = on\n';

function rejects(text, code, label) {
	let caught = null;
	try { awg.parse(text); } catch (e) { caught = awg.error(e); }
	check(caught && caught.code == code, label);
	check(index(sprintf('%J', caught), synthetic) < 0, label + ' redaction');
}
function denies(method, args, code, label) {
	let caught = null;
	try { db.run(method, args); } catch (e) { caught = awg.error(e); }
	check(caught && caught.code == code, label);
}

let parsed = awg.parse(base);
check(parsed.peer_count == 1 && parsed.endpoints[0] == 'vpn.example:51820', 'valid full 3.1 profile');
check(awg.parse(replace(base, '\n', '\r\n')).peer_count == 1, 'CRLF');
check(awg.parse(replace(base, 'vpn.example:51820', '[2001:db8::1]:443')).peer_count == 1, 'IPv6 endpoint');
check(awg.parse(replace(base, 'vpn.example:51820', '203.0.113.1:443')).peer_count == 1, 'IPv4 endpoint');
check(awg.parse(replace(base, 'fd00::2/128', '::ffff:192.0.2.1/128')).peer_count == 1, 'IPv4-mapped IPv6');
check(awg.parse(base + '[Peer]\nPublicKey = ' + synthetic + '\nEndpoint = backup.example:1\nAllowedIPs = 192.0.2.0/24\n').peer_count == 2, 'multiple peers');
rejects(replace(base, 'PrivateKey = ' + synthetic, 'PrivateKey = invalid'), 'value', 'invalid private key');
rejects(replace(base, synthetic, 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='), 'value', 'zero key');
rejects(split(base, '[Peer]')[0], 'peer', 'missing peer');
rejects(replace(base, 'Endpoint = vpn.example:51820', 'Endpoint = https://vpn.example:51820/path'), 'value', 'invalid endpoint');
rejects(replace(base, 'Endpoint = vpn.example:51820', 'Endpoint = [2001:::1]:443'), 'value', 'invalid IPv6');
rejects(replace(base, 'Endpoint = vpn.example:51820', 'Endpoint = 999.1.1.1:443'), 'value', 'invalid numeric host');
rejects(replace(base, 'AllowedIPs = 0.0.0.0/0, ::/0', 'AllowedIPs = 1.2.3.4/33'), 'value', 'invalid CIDR');
rejects(replace(base, 'PersistentKeepalive = 20-25', 'PersistentKeepalive = 25-20'), 'value', 'invalid keepalive range');
rejects(replace(base, 'S1 = 12', 'S1 = 11'), 'padding', 'header nonce padding');
rejects(replace(base, 'H2 = 21-30', 'H2 = 15-30'), 'headers', 'overlapping headers');
rejects(replace(base, 'Jmin = 40', 'Jmin = 101'), 'range', 'junk range');
rejects(replace(base, 'I1 = <b 0x1234><r 4><rc 4><rd 4><c><t>', 'I1 = <r 65535>'), 'value', 'oversized CPS');
rejects(replace(base, 'I2 = <r 4>', 'I2 = <shell id>'), 'value', 'unknown CPS tag');
rejects(base + '[Unexpected]\n', 'section', 'unexpected section');
rejects(base + 'PublicKey = ' + synthetic + '\n', 'duplicate', 'duplicate field');
for (let directive in [ 'PreUp = touch /tmp/forbidden', 'PostUp = $(id)', 'PreDown = `id`',
	'PostDown = reboot', 'Table = auto', 'SaveConfig = true', 'Include = /etc/shadow', 'Unknown = x' ])
	rejects(replace(base, '[Peer]', directive + '\n[Peer]'), 'unsupported', 'unsafe/unknown directive');
rejects(replace(base, 'PrivateKey = ' + synthetic, 'PrivateKey = /root/key'), 'value', 'key file path');
rejects(replace(base, 'vpn.example:51820', 'vpn.example:51820;id'), 'value', 'command injection');
rejects(replace(base, 'I2 = <r 4>', 'I2 = $(id)'), 'value', 'CPS command injection');
rejects(replace(base, 'AdvancedSecurity = on', 'AdvancedSecurity = OFF'), 'security', 'case insensitive security disable');
rejects(sprintf('%065537s', ''), 'size', 'size limit');
rejects('[Interface]\nPrivateKey = ' + synthetic + '\n[Peer]\nPublicKey = ' + synthetic +
	'\nEndpoint = vpn.example:51820\nAllowedIPs = 0.0.0.0/0\n', 'not_awg31', 'plain WG is not labelled 3.1');

let a = db.run('import', { name: 'Duplicate name', config: base }).connection;
let b = db.run('import', { name: 'Duplicate name', config: base }).connection;
check(a.id != b.id && length(db.run('list', {}).connections) == 2, 'multiple imports and duplicate names');
check(a.status == 'valid' && a.protocol == 'AmneziaWG 3.1', 'configuration-only status');
check(index(sprintf('%J', db.run('list', {})), synthetic) < 0, 'list never exposes keys');
for (let file in fs.lsdir(root)) {
	let s = fs.lstat(root + '/' + file);
	check((s.mode & 0o777) == 0o600 && s.uid == owner, 'private file permissions');
	if (match(file, /\.json$/)) check(index(fs.readfile(root + '/' + file), synthetic) < 0, 'metadata has no keys');
}
check((fs.stat(root).mode & 0o777) == 0o700, 'private directory');
let old_meta = fs.readfile(root + '/' + a.id + '.json');
denies('replace', { id: a.id, name: 'bad', config: base + 'Unknown = 1\n' }, 'unsupported', 'invalid replacement blocked');
check(fs.readfile(root + '/' + a.id + '.json') == old_meta, 'failed replacement preserves metadata');
denies('delete', { id: '../escape' }, 'id', 'path traversal');
denies('rename', { id: a.id + ';reboot', name: 'x' }, 'id', 'ID command injection');
check(db.run('rename', { id: a.id, name: 'Renamed' }).connection.name == 'Renamed', 'rename');
let renamed = json(fs.readfile(root + '/' + a.id + '.json'));
check(renamed.revision == json(old_meta).revision, 'rename preserves config revision');
check(db.run('validate', { id: a.id }).connection.status == 'valid', 'repeat validation');
let replaced = db.run('replace', { id: a.id, name: 'Replaced', config: replace(base, 'vpn.example:51820', 'new.example:443') }).connection;
check(replaced.id == a.id && replaced.endpoints[0] == 'new.example:443', 'replace preserves ID and changes config');
check(!fs.lstat(root + '/' + a.id + '.' + renamed.revision + '.conf'), 'old revision removed');

// Native flock must release on close; it cannot leave a stale PID lock.
let lock = fs.open(root + '/.lock', 'a+', 0o600);
check(lock.lock('xn'), 'acquire lock');
denies('import', { name: 'busy', config: base }, 'busy', 'concurrent operation blocked');
lock.close();
check(db.run('validate', { id: a.id }).connection.status == 'valid', 'lock releases');

// Inject a metadata rename failure at the real filesystem boundary.
let fault_fs = {};
for (let k, v in fs) fault_fs[k] = v;
fault_fs.rename = function(from, to) { return to == root + '/' + a.id + '.json' ? null : fs.rename(from, to); };
let before = fs.readfile(root + '/' + a.id + '.json');
let commit_error = null;
try { awg.store(root, owner, fault_fs).run('replace', { id: a.id, name: 'failed', config: base }); }
catch (e) { commit_error = awg.error(e); }
check(commit_error && commit_error.code == 'storage', 'atomic commit failure');
check(fs.readfile(root + '/' + a.id + '.json') == before, 'atomic failure keeps old metadata');
check(db.run('validate', { id: a.id }).connection.status == 'valid', 'atomic failure keeps working config');
let meta = json(before), path = root + '/' + a.id + '.' + meta.revision + '.conf';
let original = fs.readfile(path);
fs.unlink(path); fs.symlink('/etc/passwd', path);
denies('validate', { id: a.id }, 'storage', 'symlink config rejected');
fs.unlink(path);
let f = fs.open(path, 'wx', 0o600); f.write(original); f.close();
check(db.run('validate', { id: a.id }).connection.status == 'valid', 'restore isolated test config');
fs.chmod(path, 0o644);
denies('validate', { id: a.id }, 'storage', 'world-readable config refused');
let invalid_meta = json(fs.readfile(root + '/' + a.id + '.json'));
check(invalid_meta.status == 'invalid' && invalid_meta.validation_error.code == 'storage', 'failed revalidation result persisted');
fs.chmod(path, 0o600);
let owner_error = null;
try { awg.store(root, owner + 1).run('list', {}); } catch (e) { owner_error = awg.error(e); }
check(owner_error && owner_error.code == 'storage', 'wrong owner refused');
db.run('delete', { id: a.id });
let remaining = db.run('list', {}).connections;
check(length(remaining) == 1 && remaining[0].id == b.id, 'delete affects only selected connection');
for (let file in fs.lsdir(root)) check(index(file, a.id) < 0, 'deleted connection files removed');
check(db.run('validate', { id: b.id }).connection.status == 'valid', 'other connection unaffected');

printf('AWG native parser/storage smoke OK (%d assertions; synthetic data only)\n', tests);
