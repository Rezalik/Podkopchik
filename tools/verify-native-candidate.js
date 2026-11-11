'use strict';
const fs = require('fs');
const crypto = require('crypto');
const { execFileSync } = require('child_process');
const file = process.argv[2];
if (!file || fs.statSync(file).size > 12 * 1024 * 1024) throw Error('Invalid candidate archive');
const tar = args => execFileSync('tar', args.concat(file), { maxBuffer: 24 * 1024 * 1024 });
const entries = tar(['-tzf']).toString().trim().split('\n');
if (entries.length > 1024 || new Set(entries).size !== entries.length) throw Error('Duplicate or oversized archive');
for (const name of entries) {
	if (!/^\.\/[A-Za-z0-9_./-]*$/.test(name) || name.split('/').includes('..')) throw Error('Unsafe archive path');
}
for (const row of tar(['--numeric-owner', '-tvzf']).toString().trim().split('\n')) {
	const cols = row.trim().split(/\s+/);
	if (!['-', 'd'].includes(cols[0][0]) || cols[2] !== '0' || cols[3] !== '0') throw Error('Unexpected file type or owner');
}
const read = name => execFileSync('tar', ['-xOf', file, name], { maxBuffer: 16 * 1024 * 1024 });
const hash = b => crypto.createHash('sha256').update(b).digest('hex');
const seen = new Set();
let unpacked = 0;
const checksumText = read('./SHA256SUMS').toString();
for (const line of checksumText.trim().split('\n')) {
	const m = /^([a-f0-9]{64})  (\.\/[A-Za-z0-9_./-]+)$/.exec(line);
	if (!m || !entries.includes(m[2]) || seen.has(m[2])) throw Error('Invalid manifest');
	seen.add(m[2]);
	const data = read(m[2]);
	unpacked += data.length;
	if (hash(data) !== m[1]) throw Error('Manifest checksum mismatch: ' + m[2]);
}
for (const name of entries) if (!name.endsWith('/') && name !== './SHA256SUMS' && !seen.has(name)) throw Error('Unmanifested file');
if (unpacked > 24 * 1024 * 1024) throw Error('Unexpected installation size');
const expected = read('./NATIVE_DNS_SHA256').toString().trim();
if (!/^[a-f0-9]{64}$/.test(expected)) throw Error('Invalid helper digest');
const binary = read('./native-bin/' + expected);
if (hash(binary) !== expected || binary.subarray(0, 4).toString('hex') !== '7f454c46' || binary[4] !== 2 || binary[5] !== 1 || binary.readUInt16LE(18) !== 183)
	throw Error('Not the verified Linux ARM64 helper');
const launcher = '#!/bin/sh\nset -eu\nexec "${PODKOPCHIK_CONFIG_DIR:-/etc/podkopchik}/native-bin/' + expected + '" "$@"\n';
if (read('./root/usr/libexec/podkopchik/podkopchik-native-dns').toString() !== launcher) throw Error('Launcher digest mismatch');
const platform = entries.includes('./PLATFORM.json') ? require('./native-package-manifest').verify(read, checksumText, expected) : null;
console.log(JSON.stringify({ files: seen.size, binary_bytes: binary.length, unpacked_bytes: unpacked,
	platform, helper_sha256: expected, archive_sha256: hash(fs.readFileSync(file)) }, null, 2));
