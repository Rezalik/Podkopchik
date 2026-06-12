'use strict';

const fs = require('fs');
const source = fs.readFileSync('root/www/luci-static/resources/view/podkopchik/domain-rules.js', 'utf8');
const prefix = source.split('return view.extend')[0];

if (!String.prototype.format) {
	String.prototype.format = function() {
		let i = 0;
		const args = arguments;
		return this.replace(/%[sd]/g, () => String(args[i++]));
	};
}

var sections = [];
var originalSids = '';

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
	},
	remove: function(_config, sid) {
		const idx = sections.findIndex(s => s['.name'] === sid);
		if (idx >= 0)
			sections.splice(idx, 1);
	}
};

const document = {
	getElementById: function(id) {
		if (id !== 'podkopchik-domain-groups')
			return null;

		return {
			getAttribute: function(name) {
				return name === 'data-original-sids' ? originalSids : '';
			}
		};
	}
};

function E() {}

const api = new Function('uci', 'document', 'E', '_',
	prefix + '\nreturn { normalizeDomains, collectDomainGroups, writeGroupsToUci };'
)(uci, document, E, s => s);

function domains(count) {
	const out = [];
	for (let i = 1; i <= count; i++)
		out.push('d' + String(i).padStart(3, '0') + '.example.com');
	return out;
}

function assert(condition, message) {
	if (!condition)
		throw new Error(message);
}

function reset(initial) {
	sections = initial || [];
	originalSids = sections.filter(s => s['.type'] === 'domain_rule').map(s => s['.name']).join(',');
}

function saveOneGroup(count) {
	reset([]);
	api.writeGroupsToUci([{
		sids: [],
		enabled: true,
		name: 'Big list',
		tag: 'big_list',
		domains: domains(count),
		target: 'auto_proxy_group',
		order: 0
	}]);

	const rules = sections.filter(s => s['.type'] === 'domain_rule');
	assert(rules.length === 1, count + ' domains should create one domain_rule section');
	assert(Array.isArray(rules[0].domain), 'domain must be stored as a list');
	assert(rules[0].domain.length === count, 'domain list length mismatch for ' + count);
}

assert(JSON.stringify(api.normalizeDomains('One.EXAMPLE.com\ntwo.example.com')) === JSON.stringify(['one.example.com', 'two.example.com']), 'newline normalization failed');
assert(JSON.stringify(api.normalizeDomains('one.example.com,two.example.com')) === JSON.stringify(['one.example.com', 'two.example.com']), 'comma normalization failed');
assert(JSON.stringify(api.normalizeDomains('one.example.com;two.example.com')) === JSON.stringify(['one.example.com', 'two.example.com']), 'semicolon normalization failed');
assert(JSON.stringify(api.normalizeDomains('one.example.com two.example.com')) === JSON.stringify(['one.example.com', 'two.example.com']), 'space normalization failed');
assert(JSON.stringify(api.normalizeDomains('ONE.example.com, two.example.com; one.example.com\nTHREE.example.com')) === JSON.stringify(['one.example.com', 'two.example.com', 'three.example.com']), 'mixed normalization failed');

for (const count of [10, 100, 500])
	saveOneGroup(count);

reset([]);
api.writeGroupsToUci([
	{
		sids: [],
		enabled: true,
		name: 'YouTube',
		tag: 'youtube',
		domains: [ 'youtube.com', 'youtu.be', 'googlevideo.com', 'ytimg.com' ],
		target: 'auto_proxy_group',
		order: 0
	},
	{
		sids: [],
		enabled: true,
		name: 'X / Twitter',
		tag: 'twitter',
		domains: [ 'x.com', 'twitter.com', 'twimg.com' ],
		target: 'auto_proxy_group',
		order: 1
	}
]);

let visualGroups = api.collectDomainGroups();
assert(sections.filter(s => s['.type'] === 'domain_rule').length === 2, 'two visual groups should create two domain_rule sections');
assert(visualGroups.length === 2, 'two saved visual groups should read back as two groups');
assert(visualGroups[0].tag === 'youtube', 'first group tag should be preserved');
assert(visualGroups[1].tag === 'twitter', 'second group tag should be preserved');
assert(visualGroups[1].domains.indexOf('x.com') >= 0, 'second group lost x.com');
assert(visualGroups[1].domains.indexOf('twitter.com') >= 0, 'second group lost twitter.com');
assert(visualGroups[1].domains.indexOf('twimg.com') >= 0, 'second group lost twimg.com');
assert(visualGroups[1].targetMode === 'auto', 'second group target should be preserved');

reset([
	{ '.type': 'domain_rule', '.name': 'legacy1', enabled: '1', domain: 'youtube.com', target: 'auto_proxy_group', group_name: 'YouTube', group_tag: 'youtube', group_order: '0' },
	{ '.type': 'domain_rule', '.name': 'legacy2', enabled: '1', domain: 'youtu.be', target: 'auto_proxy_group', group_name: 'YouTube', group_tag: 'youtube', group_order: '0' },
	{ '.type': 'domain_rule', '.name': 'legacy3', enabled: '1', domain: 'googlevideo.com', target: 'auto_proxy_group', group_name: 'YouTube', group_tag: 'youtube', group_order: '0' }
]);

const groups = api.collectDomainGroups();
assert(groups.length === 1, 'legacy sections with the same group_tag should render as one visual group');
assert(groups[0].domains.length === 3, 'legacy group lost domains while reading');
api.writeGroupsToUci(groups);

const migrated = sections.filter(s => s['.type'] === 'domain_rule');
assert(migrated.length === 1, 'legacy group should migrate to one domain_rule section on save');
assert(Array.isArray(migrated[0].domain), 'migrated group should use list domain');
assert(migrated[0].domain.length === 3, 'migrated group lost domains');
assert(migrated[0].group_name === 'YouTube', 'group_name should be preserved');
assert(migrated[0].group_tag === 'youtube', 'group_tag should be preserved');
assert(migrated[0].target === 'auto_proxy_group', 'target should be preserved');

reset([
	{ '.type': 'domain_rule', '.name': 'unrelated', enabled: '1', domain: [ 'bank.example.com' ], target: 'direct', group_name: 'Banks', group_tag: 'banks', group_order: '1' }
]);
api.writeGroupsToUci(api.collectDomainGroups());
assert(sections.length === 1 && sections[0].group_tag === 'banks', 'unrelated group should not be deleted');

let failed = false;
const beforeInvalid = JSON.stringify(sections);
try {
	api.normalizeDomains('valid.example.com bad_domain');
}
catch (e) {
	failed = /Invalid domain value 2: bad_domain/.test(e.message);
}
assert(failed, 'invalid domain should be rejected with token number and value');
assert(JSON.stringify(sections) === beforeInvalid, 'invalid domain must not cause partial save');

reset([
	{ '.type': 'domain_rule', '.name': 'name1', enabled: '1', domain: 'instagram.com', target: 'direct', group_name: 'Instagram', group_order: '2' },
	{ '.type': 'domain_rule', '.name': 'name2', enabled: '1', domain: 'cdninstagram.com', target: 'direct', group_name: 'Instagram', group_order: '2' },
	{ '.type': 'domain_rule', '.name': 'name3', enabled: '1', domain: 'fbcdn.net', target: 'direct', group_name: 'Instagram', group_order: '2' }
]);

const byName = api.collectDomainGroups();
assert(byName.length === 1, 'legacy sections with the same group_name should render as one visual group');
api.writeGroupsToUci(byName);
assert(sections.filter(s => s['.type'] === 'domain_rule').length === 1, 'same group_name legacy group should migrate to one section');
assert(sections[0].domain.length === 3, 'same group_name migration lost domains');

console.log('Domain groups model smoke OK');
