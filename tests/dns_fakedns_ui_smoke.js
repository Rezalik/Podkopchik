'use strict';

const fs = require('fs');

const source = fs.readFileSync('root/www/luci-static/resources/view/podkopchik/dns.js', 'utf8');

function assert(condition, message) {
	if (!condition)
		throw new Error(message);
}

const options = [];

function Section() {}
Section.prototype.option = function(_ctor, name, label) {
	const option = {
		name,
		label,
		deps: [],
		depends: function(key, value) {
			this.deps.push({ key, value });
		}
	};

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
	Map,
	NamedSection: function() {},
	Flag: function() {},
	Value: function() {},
	DummyValue: function() {}
};

const fakeFs = {
	exec_direct: function(cmd, args) {
		fakeFs.calls.push({ cmd, args });
		return Promise.resolve('Podkopchik routing applied.');
	},
	calls: []
};

const ui = {
	changes: {
		apply: function() {
			ui.applied = true;
			return Promise.resolve();
		}
	},
	applied: false,
	addNotification: function() {}
};

function E() {
	return {};
}

const settings = {routing_engine:'legacy',fakedns_port:'9999',native_dns_port:'1053'};
const uci = {get:(_c,_s,k)=>settings[k],load:()=>Promise.resolve()};
const routing = require('./lib/luci-routing')({ui,E});
const factory = new Function('view', 'form', 'fs', 'ui', '_', 'E', 'uci', 'routing', source);
const luciView = factory(view, form, fakeFs, ui, s => s, E, uci, routing);

luciView.render();

function option(name) {
	return options.find(o => o.name === name);
}

function requiresFakeDns(name) {
	const opt = option(name);
	return opt && opt.deps.some(dep => dep.key === 'fakedns_enabled' && dep.value === '1');
}

assert(option('fakedns_enabled'), 'DNS page must expose fakedns_enabled');
assert(option('fakedns_hijack_dns'), 'DNS page must expose fakedns_hijack_dns');
assert(option('fakedns_port'), 'DNS page must expose fakedns_port');
assert(option('fakedns_pool_v4'), 'DNS page must expose fakedns_pool_v4');
assert(option('fakedns_pool_size'), 'DNS page must expose fakedns_pool_size');
assert(option('fakedns_listen'), 'DNS page must expose fakedns_listen');
assert(option('_fakedns_notice'), 'DNS page must show FakeDNS notes');

assert(option('fakedns_enabled').default === '0', 'FakeDNS must remain off by default in LuCI');
assert(requiresFakeDns('fakedns_hijack_dns'), 'DNS hijack option must depend on FakeDNS being enabled');
assert(requiresFakeDns('fakedns_port'), 'FakeDNS port option must depend on FakeDNS being enabled');
assert(requiresFakeDns('fakedns_pool_v4'), 'FakeDNS IPv4 pool option must depend on FakeDNS being enabled');
assert(requiresFakeDns('fakedns_pool_size'), 'FakeDNS pool size option must depend on FakeDNS being enabled');
assert(requiresFakeDns('fakedns_listen'), 'FakeDNS listen option must depend on FakeDNS being enabled');

assert(option('fakedns_port').validate(null, '1053') === true, 'valid FakeDNS port should pass');
assert(option('fakedns_port').validate(null, '0') !== true, 'invalid FakeDNS port should fail');
assert(option('fakedns_port').validate(null, '65536') !== true, 'out-of-range FakeDNS port should fail');
assert(option('fakedns_pool_v4').validate(null, '198.18.0.0/15') === true, 'valid FakeDNS IPv4 CIDR should pass');
assert(option('fakedns_pool_v4').validate(null, '198.18.0.0') !== true, 'FakeDNS pool without prefix should fail');
assert(option('fakedns_pool_v4').validate(null, '198.18.0.0/33') !== true, 'FakeDNS pool with invalid prefix should fail');
assert(option('fakedns_pool_v4').validate(null, '2001:db8::/32') !== true, 'FakeDNS IPv6 CIDR should fail because this option is IPv4 only');
assert(option('fakedns_pool_size').validate(null, '65535') === true, 'valid FakeDNS pool size should pass');
assert(option('fakedns_pool_size').validate(null, '0') !== true, 'zero FakeDNS pool size should fail');

Promise.resolve(luciView.handleSaveApply(null, '1')).then(function() {
	assert(ui.applied, 'DNS Save & Apply must apply LuCI changes');
	assert(fakeFs.calls.some(call => call.cmd === '/usr/bin/podkopchikctl' && call.args[0] === 'apply'),
		'DNS Save & Apply must call podkopchikctl apply');
	options.length = 0;
	settings.routing_engine = 'native';
	luciView.render([null,{engine:'native',phase:'active',dns:{listen:'192.168.1.1:1053',pools:['172.30.0.0/16'],protected:true}}]);
	assert(option('native_dns_port') && option('native_pool_v4') && option('native_pool_v6'), 'Native DNS must use Native UCI options');
	assert(!option('fakedns_enabled') && !option('fakedns_port') && !option('dns_redirect'), 'Native DNS must not expose ignored Xray/DNS redirect switches');
	assert(option('_native_dns_runtime').cfgvalue() === '192.168.1.1:1053', 'active listener comes from runtime, not legacy saved port');
	assert(option('_native_dns_pools').cfgvalue() === '172.30.0.0/16', 'active pool must not claim 198.18/15');
	assert(option('_native_dns_upstream').cfgvalue().includes('DNS-over-TLS'), 'protected Native upstream must be shown');
	assert(option('native_dns_port').validate(null,'1053') === true, 'valid Native port must pass');
	assert(option('native_pool_v4').validate(null,'172.30.0.0/16') === true, 'Native pool validation must accept the admitted private pool');
	console.log('DNS FakeDNS UI smoke OK');
}).catch(function(err) {
	console.error(err && err.stack || err);
	process.exit(1);
});
