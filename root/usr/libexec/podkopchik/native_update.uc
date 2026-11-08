// Admission checks run from the installed version, before extracting new code.
import { open, popen, readfile, lstat } from 'fs';

function fail(message) { die('Native update: ' + message + '\n'); }
function field(block, offset, size) { return replace(substr(block, offset, size), /\x00.*$/, ''); }
function octal(block, offset, size) {
	let value = trim(field(block, offset, size));
	if (!match(value, /^[0-7]+$/)) fail('invalid tar numeric field');
	return int(value, 8);
}
function exact(stream, size) {
	let result = '';
	while (length(result) < size) {
		let part = stream.read(size - length(result));
		if (!length(part)) fail('truncated archive');
		result += part;
	}
	return result;
}
function archive(file) {
	if (!match(file, /^\/tmp\/podkopchik-native-update\.[A-Za-z0-9]+\/package.tar.gz$/)) fail('invalid staging path');
	let stream = popen('gzip -dc ' + file, 'r'), names = {}, canonical = {}, bytes = 0, count = 0, manifest = '';
	if (!stream) fail('cannot read archive');
	while (true) {
		let h = exact(stream, 512);
		if (replace(h, /\x00/g, '') == '') {
			if (exact(stream, 512) != h) fail('invalid tar terminator');
			// No concatenated archive or hidden payload after the terminator.
			let tail;
			while (length(tail = stream.read(512))) {
				bytes += length(tail);
				if (bytes > 25165824 || replace(tail, /\x00/g, '') != '') fail('unexpected archive trailer');
			}
			if (stream.close() != 0) fail('gzip verification failed');
			break;
		}
		if (++count > 1024) fail('too many archive entries');
		let sum = 0;
		for (let i = 0; i < 512; i++) sum += i >= 148 && i < 156 ? 32 : ord(h, i);
		if (sum != octal(h, 148, 8)) fail('tar checksum mismatch');
		let name = field(h, 0, 100), prefix = field(h, 345, 155), kind = substr(h, 156, 1);
		if (prefix != '') name = prefix + '/' + name;
		if (!match(name, /^\.\/[A-Za-z0-9_.\/-]*$/) || index(split(name, '/'), '..') >= 0 || index(split(substr(name, 2), '/'), '.') >= 0 || index(name, '//') >= 0 || names[name]) fail('unsafe or duplicate tar path: ' + substr(name, 0, 160));
		let key = replace(name, /\/$/, '');
		if (canonical[key]) fail('file/directory alias in archive');
		canonical[key] = true;
		names[name] = kind != '5' ? 'file' : 'directory';
		if (substr(h, 257, 5) != 'ustar' || index(['0', '\x00', '5'], kind) < 0 || field(h, 157, 100) != '') fail('unsupported tar member');
		let mode = octal(h, 100, 8), size = octal(h, 124, 12);
		if (octal(h, 108, 8) != 0 || octal(h, 116, 8) != 0 || (mode & 0o7022)) fail('unsafe tar ownership or mode');
		if ((kind == '5' && (size != 0 || substr(name, -1) != '/')) || (kind != '5' && substr(name, -1) == '/')) fail('invalid member type');
		bytes += 512 + int((size + 511) / 512) * 512;
		if (size > 12582912 || bytes > 25165824) fail('archive expansion limit');
		if (name == './SHA256SUMS' && size > 131072) fail('manifest too large');
		let left = int((size + 511) / 512) * 512;
		while (left) { let n = min(left, 65536), part = exact(stream, n); if (name == './SHA256SUMS') manifest += part; left -= n; }
		if (name == './SHA256SUMS') manifest = substr(manifest, 0, size);
	}
	for (let name in ['./SHA256SUMS', './TARGET', './NATIVE_DNS_SHA256', './install-native-dns.sh', './tools/install-native-rc-files.sh'])
		if (names[name] != 'file') fail('incomplete Native bundle');
	let listed = {};
	for (let line in split(trim(manifest), '\n')) {
		let m = match(line, /^[a-f0-9]{64}  (\.\/[A-Za-z0-9_.\/-]+)$/);
		if (!m || names[m[1]] != 'file' || listed[m[1]] || m[1] == './SHA256SUMS') fail('unsafe manifest');
		listed[m[1]] = true;
	}
	for (let name, kind in names) if (kind == 'file' && name != './SHA256SUMS' && !listed[name]) fail('unmanifested file');
	printf('archive_entries=%d\nunpacked_kib=%d\n', count, int((bytes + 1023) / 1024));
}
function install(base) {
	if (!match(base, /^\/tmp\/podkopchik-native-update\.[A-Za-z0-9]+\/package$/)) fail('invalid install path');
	let root = (getenv('PODKOPCHIK_CONFIG_DIR') || '/etc/podkopchik') + '/native-state';
	let s = lstat(root), f;
	if (s?.type != 'directory' || s.uid != 0 || (s.mode & 0o077)) fail('unsafe Native state directory');
	s = lstat(root + '/.lock');
	if (s && (s.type != 'file' || s.uid != 0 || s.nlink != 1 || (s.mode & 0o077))) fail('unsafe Native lock');
	f = open(root + '/.lock', 'a+', 0o600);
	if (!f || !f.lock('x')) fail('cannot lock Native runtime');
	let state = json(readfile(root + '/runtime.json'));
	if (state.pending || state.repair || state.phase != 'active') fail('Native is not confirmed and active');
	let rc = system(['sh', base + '/tools/install-native-rc-files.sh', base]);
	f.close();
	if (rc != 0) fail('static installer failed; confirmed generation retained');
}
function release(file, repo) {
	if (!match(repo, /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/)) fail('invalid repository');
	let releases = json(readfile(file)), best;
	if (type(releases) != 'array') fail('invalid GitHub release response');
	for (let r in releases) {
		if (r.draft || !r.prerelease || !match(r.tag_name || '', /^native-rc-[A-Za-z0-9_.-]+$/)) continue;
		let asset;
		for (let a in r.assets || []) if (a.name == 'podkopchik-native-ax6000-candidate.tar.gz') asset = a;
		if (!asset || asset.size <= 0 || asset.size > 12582912 || !match(asset.digest || '', /^sha256:[a-f0-9]{64}$/)) continue;
		let url = 'https://github.com/' + repo + '/releases/download/' + r.tag_name + '/' + asset.name;
		if (asset.browser_download_url != url) continue;
		if (!best || r.published_at > best.date) best = {tag:r.tag_name, date:r.published_at, url, digest:substr(asset.digest, 7)};
	}
	if (!best) fail('no verified Native RC release asset; source archives cannot update Native');
	printf('channel=native-rc\nrepo=%s\nlatest=%s\narchive_url=%s\nsha256=%s\nactivation=explicit-ordinary-apply\n', repo, best.tag, best.url, best.digest);
}

if (ARGV[0] == 'archive') archive(ARGV[1]);
else if (ARGV[0] == 'release') release(ARGV[1], ARGV[2]);
else if (ARGV[0] == 'install') install(ARGV[1]);
else fail('invalid action');
