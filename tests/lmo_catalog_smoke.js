'use strict';

const assert = require('assert');
const fs = require('fs');

const lmo = fs.readFileSync('i18n/ru/podkopchik.ru.lmo');

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

function lookup(key) {
	const indexOffset = lmo.readUInt32BE(lmo.length - 4);
	const entries = (lmo.length - indexOffset - 4) / 16;
	const hash = sfhHash(key);

	for (let i = 0; i < entries; i++) {
		const off = indexOffset + i * 16;
		const keyHash = lmo.readUInt32BE(off);

		if (keyHash !== hash)
			continue;

		const valueOffset = lmo.readUInt32BE(off + 8);
		const valueLength = lmo.readUInt32BE(off + 12);

		return lmo.slice(valueOffset, valueOffset + valueLength).toString('utf8');
	}

	return null;
}

assert.notStrictEqual(lmo.readUInt32LE(0), 0x950412de, 'catalog must not be GNU .mo format');
assert.strictEqual(lookup('Proxy Links'), 'Прокси-ссылки');
assert.strictEqual(lookup('Domain Groups'), 'Доменные группы');
assert.strictEqual(lookup('Presets'), 'Пресеты');
assert.strictEqual(lookup('Apply settings'), 'Применить настройки');
assert.strictEqual(lookup('Check proxy availability'), 'Проверить доступность прокси');
assert.strictEqual(lookup('Restart service'), 'Перезапустить сервис');
assert.strictEqual(lookup('Disable traffic routing'), 'Отключить маршрутизацию трафика');
assert.strictEqual(lookup('Podkopchik'), null, 'brand name should not be translated');

console.log('LMO catalog smoke OK');
