'use strict';
const fs = require('fs');
const crypto = require('crypto');
const path = require('path');
const assert = require('assert');
const catalog = require('../root/usr/libexec/podkopchik/native-targets.json');
const launcherPath = './root/usr/libexec/podkopchik/podkopchik-native-dns';
const sha = data => crypto.createHash('sha256').update(data).digest('hex');

function target(id) {
	if (!Object.hasOwn(catalog.targets, id)) throw Error('Unknown Native package target');
	return catalog.targets[id];
}

function sums(text) {
	const common = [];
	for (const line of text.trimEnd().split('\n')) {
		const m = /^([a-f0-9]{64})  (\.\/[A-Za-z0-9_./-]+)$/.exec(line);
		if (!m) throw Error('Invalid component checksum line');
		if (m[2] !== launcherPath && (m[2].startsWith('./root/') || m[2].startsWith('./i18n/'))) common.push(line);
	}
	if (!common.length) throw Error('Missing common component');
	return common.sort().join('\n') + '\n';
}

function manifest(id, helperSha, commonSums) {
	const t = target(id);
	if (!/^[a-f0-9]{64}$/.test(helperSha)) throw Error('Invalid helper digest');
	return {
		schema: 2, baseline: catalog.baseline, target_id: id,
		platform: { ...catalog.platform, board: t.board }, asset: t.asset, track: t.track,
		activation: 'explicit-ordinary-apply',
		components: {
			common: { sha256: sha(commonSums) },
			helper: { ...catalog.helper, sha256: helperSha, path: 'native-bin/' + helperSha }
		}
	};
}

function verify(read, checksumText, helperSha) {
	const common = sums(checksumText);
	assert.strictEqual(read('./COMMON_SHA256SUMS').toString(), common, 'Common component manifest mismatch');
	const actual = JSON.parse(read('./PLATFORM.json'));
	assert.deepStrictEqual(actual, manifest(actual.target_id, helperSha, common), 'Platform manifest mismatch');
	assert.deepStrictEqual(JSON.parse(read('./root/usr/libexec/podkopchik/native-targets.json')), catalog, 'Target catalog mismatch');
	assert.strictEqual(read('./TARGET').toString(), legacyTarget(actual.target_id), 'Legacy target marker mismatch');
	return actual;
}

function legacyTarget(id) {
	return [
		'board=' + target(id).board, 'openwrt=' + catalog.platform.release,
		'architecture=' + catalog.platform.architecture, 'activation=explicit-ordinary-apply',
		'update_protocol=native-staged-v1', 'acceptance=requires-completed-vm-report-and-physical-preflight'
	].join('\n') + '\n';
}

if (require.main === module) {
	const [action, id, dir, digest] = process.argv.slice(2);
	if (action === 'asset') console.log(target(id).asset);
	else if (action === 'write') {
		const common = sums(fs.readFileSync(path.join(dir, 'SHA256SUMS'), 'utf8'));
		fs.writeFileSync(path.join(dir, 'COMMON_SHA256SUMS'), common);
		fs.writeFileSync(path.join(dir, 'PLATFORM.json'), JSON.stringify(manifest(id, digest, common), null, 2) + '\n');
		fs.writeFileSync(path.join(dir, 'TARGET'), legacyTarget(id));
	} else throw Error('Use asset TARGET or write TARGET DIRECTORY HELPER_SHA256');
}
module.exports = { manifest, sums, verify, target };
