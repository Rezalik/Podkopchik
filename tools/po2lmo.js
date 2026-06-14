#!/usr/bin/env node
'use strict';

const fs = require('fs');

function usage() {
	console.error('Usage: tools/po2lmo.js input.po output.lmo');
	process.exit(2);
}

function unquotePoString(line) {
	const first = line.indexOf('"');
	const last = line.lastIndexOf('"');
	let out = '';
	let esc = false;

	if (first < 0 || last <= first)
		return null;

	const src = line.slice(first + 1, last);

	for (let i = 0; i < src.length; i++) {
		const ch = src[i];

		if (esc) {
			if (ch === '"' || ch === '\\')
				out = out.slice(0, -1);

			out += ch;
			esc = false;
		}
		else if (ch === '\\') {
			out += ch;
			esc = true;
		}
		else {
			out += ch;
		}
	}

	return out;
}

function parsePo(text) {
	const messages = [];
	let msg = {};
	let current = null;

	function finish() {
		if (msg.id !== undefined || Object.keys(msg.vals || {}).length)
			messages.push(msg);

		msg = {};
		current = null;
	}

	for (const rawLine of text.split(/\r?\n/)) {
		const line = rawLine.trimEnd();

		if (line[0] === '#')
			continue;

		if (line.startsWith('msgctxt ')) {
			if (msg.id !== undefined || Object.keys(msg.vals || {}).length)
				finish();

			msg.ctxt = null;
			current = { field: 'ctxt' };
		}
		else if (line.startsWith('msgid_plural ')) {
			msg.idPlural = null;
			current = { field: 'idPlural' };
		}
		else if (line.startsWith('msgid ')) {
			if (msg.id !== undefined || Object.keys(msg.vals || {}).length)
				finish();

			msg.id = null;
			current = { field: 'id' };
		}
		else if (line.startsWith('msgstr[')) {
			const m = line.match(/^msgstr\[(\d+)\]/);
			const idx = m ? Number(m[1]) : 0;

			msg.vals = msg.vals || {};
			msg.vals[idx] = null;
			msg.pluralNum = Math.max(msg.pluralNum ?? -1, idx);
			current = { field: 'val', index: idx };
		}
		else if (line.startsWith('msgstr ')) {
			msg.vals = msg.vals || {};
			msg.vals[0] = null;
			msg.pluralNum = Math.max(msg.pluralNum ?? -1, 0);
			current = { field: 'val', index: 0 };
		}
		else if (!line.startsWith('"')) {
			continue;
		}

		if (!current)
			continue;

		const value = unquotePoString(line);

		if (value === null)
			continue;

		if (!value.length)
			continue;

		if (current.field === 'val') {
			if (msg.vals[current.index] === null)
				msg.vals[current.index] = '';

			msg.vals[current.index] += value;
		}
		else {
			if (msg[current.field] === null)
				msg[current.field] = '';

			msg[current.field] += value;
		}
	}

	finish();
	return messages;
}

function sfhGet16(buf, off) {
	return (buf[off] || 0) | ((buf[off + 1] || 0) << 8);
}

function signedByte(v) {
	return v & 0x80 ? v - 0x100 : v;
}

function sfhHash(input) {
	const buf = Buffer.isBuffer(input) ? input : Buffer.from(input, 'utf8');
	let len = buf.length;
	let hash = len >>> 0;
	let off = 0;
	let rem;
	let tmp;

	if (len <= 0)
		return 0;

	rem = len & 3;
	len >>>= 2;

	for (; len > 0; len--) {
		hash = (hash + sfhGet16(buf, off)) >>> 0;
		tmp = (((sfhGet16(buf, off + 2) << 11) >>> 0) ^ hash) >>> 0;
		hash = (((hash << 16) >>> 0) ^ tmp) >>> 0;
		off += 4;
		hash = (hash + (hash >>> 11)) >>> 0;
	}

	switch (rem) {
	case 3:
		hash = (hash + sfhGet16(buf, off)) >>> 0;
		hash ^= (hash << 16) >>> 0;
		hash ^= (signedByte(buf[off + 2]) << 18) >>> 0;
		hash = (hash + (hash >>> 11)) >>> 0;
		break;
	case 2:
		hash = (hash + sfhGet16(buf, off)) >>> 0;
		hash ^= (hash << 11) >>> 0;
		hash = (hash + (hash >>> 17)) >>> 0;
		break;
	case 1:
		hash = (hash + signedByte(buf[off])) >>> 0;
		hash ^= (hash << 10) >>> 0;
		hash = (hash + (hash >>> 1)) >>> 0;
		break;
	}

	hash ^= (hash << 3) >>> 0;
	hash = (hash + (hash >>> 5)) >>> 0;
	hash ^= (hash << 4) >>> 0;
	hash = (hash + (hash >>> 17)) >>> 0;
	hash ^= (hash << 25) >>> 0;
	hash = (hash + (hash >>> 6)) >>> 0;

	return hash >>> 0;
}

function pad4(buf) {
	const pad = (4 - (buf.length % 4)) % 4;
	return pad ? Buffer.concat([ buf, Buffer.alloc(pad) ]) : buf;
}

function addEntry(entries, dataChunks, key, value, pluralCount) {
	const keyHash = sfhHash(key);
	const valHash = sfhHash(value);

	if (keyHash === valHash)
		return;

	const valueBuf = Buffer.from(value, 'utf8');
	const offset = dataChunks.reduce((sum, chunk) => sum + chunk.length, 0);

	entries.push({
		keyHash,
		valId: pluralCount,
		offset,
		length: valueBuf.length
	});

	dataChunks.push(pad4(valueBuf));
}

function compile(messages) {
	const entries = [];
	const dataChunks = [];

	for (const msg of messages) {
		const vals = msg.vals || {};

		if (msg.id && vals[0]) {
			const pluralNum = msg.pluralNum ?? 0;

			for (let i = 0; i <= pluralNum; i++) {
				if (vals[i] === undefined)
					continue;

				let key;

				if (msg.ctxt !== undefined && msg.idPlural !== undefined)
					key = `${msg.ctxt}\x01${msg.id}\x02${i}`;
				else if (msg.ctxt !== undefined)
					key = `${msg.ctxt}\x01${msg.id}`;
				else if (msg.idPlural !== undefined)
					key = `${msg.id}\x02${i}`;
				else
					key = msg.id;

				addEntry(entries, dataChunks, key, vals[i], pluralNum + 1);
			}
		}
		else if (vals[0]) {
			const header = vals[0];
			const match = header.match(/(?:^|\\n)Plural-Forms:\s*([^\\]*(?:\\(?!n)[^\\]*)*)/);

			if (match)
				addEntry(entries, dataChunks, Buffer.alloc(0), match[1], 0);
		}
	}

	const indexOffset = dataChunks.reduce((sum, chunk) => sum + chunk.length, 0);
	const index = Buffer.alloc(entries.length * 16 + 4);

	entries.sort((a, b) => a.keyHash - b.keyHash);

	entries.forEach((entry, idx) => {
		const off = idx * 16;

		index.writeUInt32BE(entry.keyHash, off);
		index.writeUInt32BE(entry.valId, off + 4);
		index.writeUInt32BE(entry.offset, off + 8);
		index.writeUInt32BE(entry.length, off + 12);
	});

	index.writeUInt32BE(indexOffset, entries.length * 16);

	return Buffer.concat([ ...dataChunks, index ]);
}

if (process.argv.length !== 4)
	usage();

const input = process.argv[2];
const output = process.argv[3];
const po = fs.readFileSync(input, 'utf8');
const lmo = compile(parsePo(po));

if (!lmo.length)
	throw new Error('No translated messages found');

fs.writeFileSync(output, lmo);
