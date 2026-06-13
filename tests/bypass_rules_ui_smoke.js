'use strict';

const fs = require('fs');

const source = fs.readFileSync('root/www/luci-static/resources/view/podkopchik/bypass-rules.js', 'utf8');
const menu = fs.readFileSync('root/usr/share/luci/menu.d/luci-app-podkopchik.json', 'utf8');
const acl = fs.readFileSync('root/usr/share/rpcd/acl.d/luci-app-podkopchik.json', 'utf8');

function assert(condition, message) {
	if (!condition)
		throw new Error(message);
}

const options = [];
function Section() {}
Section.prototype.option = function(_ctor, name, label) {
	const option = { name, label };
	options.push(option);
	return option;
};

function Map() {}
Map.prototype.section = function() {
	return new Section();
};
Map.prototype.render = function() {
	return Promise.resolve({});
};
Map.prototype.save = function() {
	return Promise.resolve();
};

const view = {
	extend: function(obj) {
		return obj;
	}
};
const form = {
	Map: Map,
	GridSection: function() {},
	Flag: function() {},
	Value: function() {}
};
const fakeFs = {
	exec_direct: function() {
		return Promise.resolve('Podkopchik routing applied.');
	}
};
const ui = {
	changes: { apply: function() { return Promise.resolve(); } },
	addNotification: function() {}
};
const translate = function(s) { return s; };
const element = function() { return {}; };

const factory = new Function('view', 'form', 'fs', 'ui', '_', 'E', source);
const luciView = factory(view, form, fakeFs, ui, translate, element);
luciView.render();

const host = options.find(o => o.name === 'host');
assert(host && typeof host.validate === 'function', 'Host/IP/CIDR option must validate input');
assert(!options.some(o => o.name === 'port'), 'Bypass UI must not expose a port field');
assert(host.validate(null, 'famalymovi.ru') === true, 'domain should be accepted');
assert(host.validate(null, '5.42.117.16') === true, 'IPv4 should be accepted');
assert(host.validate(null, '192.0.2.0/24') === true, 'IPv4 CIDR should be accepted');
assert(host.validate(null, '2001:db8::1') === true, 'IPv6 should be accepted');
assert(host.validate(null, '2001:db8::/48') === true, 'IPv6 CIDR should be accepted');
assert(host.validate(null, 'https://panel.example.com/login') !== true, 'URL with scheme/path should be rejected');
assert(host.validate(null, 'panel.example.com:443') !== true, 'domain with port should be rejected');

assert(menu.includes('"path": "podkopchik/bypass-rules"'), 'LuCI menu must expose Exclusions page');
assert(/fs\.exec_direct\('\/usr\/bin\/podkopchikctl',\s*\[\s*'apply'\s*\]\)/.test(source), 'Save & Apply must call podkopchikctl apply');
assert(acl.includes('"/usr/bin/podkopchikctl apply"'), 'rpcd ACL must allow podkopchikctl apply');

console.log('Bypass Rules UI smoke OK');
