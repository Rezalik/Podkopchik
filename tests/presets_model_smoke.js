'use strict';

const fs = require('fs');

const sourcePath = 'root/www/luci-static/resources/view/podkopchik/presets.js';
const source = fs.readFileSync(sourcePath, 'utf8');
const menu = JSON.parse(fs.readFileSync('root/usr/share/luci/menu.d/luci-app-podkopchik.json', 'utf8'));
const prefix = source.split('return view.extend')[0];

let sections = [];

const uci = {
	sections: function(_config, type) {
		return sections.filter(s => s['.type'] === type);
	},
	add: function(_config, type) {
		const sid = 'cfg' + String(sections.length + 1).padStart(6, '0');
		sections.push({ '.type': type, '.name': sid });
		return sid;
	},
	set: function(_config, sid, option, value) {
		const section = sections.find(s => s['.name'] === sid);
		if (!section)
			throw new Error('missing section ' + sid);
		section[option] = value;
	},
	unset: function(_config, sid, option) {
		const section = sections.find(s => s['.name'] === sid);
		if (section)
			delete section[option];
	}
};

function E() {}

const api = new Function('uci', 'E', '_',
	prefix + '\nreturn { PRESETS, PRESET_ORDER, addPresetToUci, domainValues };'
)(uci, E, s => s);

function assert(condition, message) {
	if (!condition)
		throw new Error(message);
}

function reset(initial) {
	sections = initial ? initial.slice() : [];
}

function domainRules() {
	return sections.filter(s => s['.type'] === 'domain_rule');
}

function ipRules() {
	return sections.filter(s => s['.type'] === 'ip_rule');
}

function domainsInRules() {
	let out = [];
	for (const rule of domainRules())
		out = out.concat(api.domainValues(rule));
	return out;
}

function sectionSignature() {
	return JSON.stringify(sections);
}

const expected = {
	telegram: { domains: 8, ips: 7 },
	youtube: { domains: 15, ips: 0 },
	instagram: { domains: 14, ips: 0 },
	tiktok: { domains: 14, ips: 0 },
	twitter: { domains: 19, ips: 0 },
	discord: { domains: 11, ips: 0 },
	openai: { domains: 14, ips: 0 },
	canva: { domains: 10, ips: 0 }
};

for (const key of api.PRESET_ORDER) {
	reset();
	const result = api.addPresetToUci(key, 'auto_proxy_group');
	const preset = api.PRESETS[key];
	const domains = domainsInRules();

	assert(result.addedDomains === expected[key].domains, key + ' domain added count mismatch');
	assert(result.addedIps === expected[key].ips, key + ' IP added count mismatch');
	assert(result.added === expected[key].domains + expected[key].ips, key + ' total added count mismatch');
	assert(result.skipped === 0, key + ' should not skip on first add');
	assert(domainRules().length === (expected[key].domains ? 1 : 0), key + ' should create one editable domain group');
	assert(ipRules().length === expected[key].ips, key + ' IP rule count mismatch');

	for (const domain of preset.domains)
		assert(domains.indexOf(domain) >= 0, key + ' lost domain ' + domain);

	for (const rule of domainRules())
		assert(rule.target === 'auto_proxy_group', key + ' domain target mismatch');

	for (const rule of ipRules())
		assert(rule.target === 'auto_proxy_group', key + ' IP target mismatch');
}

reset();
let first = api.addPresetToUci('telegram', 'auto_proxy_group');
let before = sectionSignature();
let second = api.addPresetToUci('telegram', 'auto_proxy_group');
assert(first.added === 15, 'Telegram should add 15 total entries on first add');
assert(second.added === 0, 'Repeated Telegram preset must not add duplicates');
assert(second.skipped === 15, 'Repeated Telegram preset should report 15 skipped duplicates');
assert(sectionSignature() === before, 'Repeated Telegram preset changed UCI sections');

reset([
	{ '.type': 'domain_rule', '.name': 'old1', enabled: '1', domain: [ 'telegram.org' ], target: 'auto_proxy_group', group_tag: 'telegram' },
	{ '.type': 'ip_rule', '.name': 'old2', enabled: '1', cidr: '91.108.4.0/22', target: 'auto_proxy_group' }
]);
let partial = api.addPresetToUci('telegram', 'auto_proxy_group');
assert(partial.added === 13, 'Partial Telegram preset should add only missing entries');
assert(partial.skipped === 2, 'Partial Telegram preset should skip existing domain and IP');
assert(domainRules().length === 1, 'Partial Telegram preset should append to existing preset domain group');
assert(api.domainValues(domainRules()[0]).length === 8, 'Partial Telegram domain group should contain all domains after append');
assert(ipRules().length === 7, 'Partial Telegram preset should create only missing IP rules');

reset();
api.addPresetToUci('youtube', 'gerwarp');
assert(domainRules()[0].target === 'gerwarp', 'Preset should preserve selected proxy target');
assert(domainRules()[0].group_name === 'YouTube', 'Preset domain group should have human-readable group name');

reset([
	{ '.type': 'domain_rule', '.name': 'other', enabled: '1', domain: [ 'example.com' ], target: 'direct', group_tag: 'youtube' }
]);
api.addPresetToUci('youtube', 'auto_proxy_group');
assert(domainRules().some(rule => rule.group_tag === 'youtube_2'), 'Preset should avoid duplicate domain group tags');

assert(/fs\.exec_direct\('\/usr\/bin\/podkopchikctl',\s*\[\s*'apply'\s*\]\)/.test(source), 'Preset page must call podkopchikctl apply');
assert(/ui\.changes\.apply/.test(source), 'Preset page must apply LuCI UCI changes');
assert(menu['admin/services/podkopchik/presets'], 'Menu must expose Presets page');

console.log('Presets model smoke OK');
