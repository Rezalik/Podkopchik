'use strict';
const assert = require('assert');
const fs = require('fs');
const options = new Map();
const form = {
	NamedSection: {}, Flag: {}, DummyValue: {}, ListValue: {}, Value: {},
	Map: class {
		section() { return { option(type, key, label) {
			const o = { type, label, values: [], dependencies: [],
				value(k, text) { this.values.push([k, text]); },
				depends(k, v) { this.dependencies.push([k, v]); } };
			options.set(key, o); return o;
		} }; }
		render() { return Promise.resolve({}); }
	}
};
const source = fs.readFileSync('root/www/luci-static/resources/view/podkopchik/advanced.js', 'utf8');
const settings = {routing_engine:'legacy'};
const routing = require('./lib/luci-routing')();
const page = new Function('view', 'form', 'fs', 'ui', 'uci', '_', 'E', 'routing', source)(
	{ extend: x => x }, form, {}, { createHandlerFn: () => () => {} }, {get:(_c,_s,k)=>settings[k]}, x => x, () => ({}), routing);
(async () => {
	await page.render([null,{available:true}]);
	assert(options.get('routing_engine').values.some(row=>row[0]==='native'));
	assert.strictEqual(options.get('routing_engine').default,'legacy');
	assert(options.get('routing_engine').description.includes('rollback deadline'));
	assert.strictEqual(options.get('native_pool_v4').retain, true);
	assert.strictEqual(options.get('native_pool_v6').retain, true);
	const mode = options.get('native_classification_mode');
	assert.deepStrictEqual(mode.values, [['compatible', 'Selective routing (rules only)'], ['strict', 'Strict routing']]);
	assert.strictEqual(mode.default, 'compatible');
	assert(mode.description.includes('only enabled rules and presets'));
	assert.strictEqual(mode.retain, true);
	assert.deepStrictEqual(mode.dependencies, [['routing_engine', 'native']]);
	const warning = options.get('_native_compatible_warning');
	assert.deepStrictEqual(warning.dependencies, [[{routing_engine:'native',native_classification_mode:'compatible',native_migration_restrict_unknown:'0'}, undefined]]);
	assert(warning.cfgvalue().includes('Cached real IPs'));
	assert.strictEqual(options.get('native_migration_restrict_unknown').default, '0');
	assert.strictEqual(options.get('native_direct_grants_confirmed').default, '0');
	assert(options.get('native_direct_grants_confirmed').description.includes('override domain protection'));
	assert(options.get('native_direct_grants_confirmed').description.includes('shared CDN IP'));
	assert(options.get('_native_strict_warning').cfgvalue().includes('unknown-traffic policy'));
	assert.strictEqual(options.get('native_unknown_action').default, 'protected');
	const defaults = fs.readFileSync('root/etc/config/podkopchik', 'utf8');
	assert(defaults.includes("option native_classification_mode 'compatible'"));
	assert(defaults.includes("option native_migration_restrict_unknown '0'"));
	settings.routing_engine = 'native';
	settings.native_recovery_policy = 'repair';
	options.clear();
	await page.render([null,{available:true,engine:'native',phase:'active',classification:{mode:'strict',unknown:'protected'}}]);
	assert(options.get('_native_saved_policy').cfgvalue().includes('Selective routing'));
	assert(options.get('_native_active_policy').cfgvalue().includes('Strict routing'));
	assert(options.get('_native_policy_state').cfgvalue().includes('differs'));
	assert(!options.has('native_confirm_seconds'), 'repair mode must not expose an unused transactional timeout');
	assert(options.get('routing_engine').description.includes('Emergency recovery remains active'));
	assert(!options.get('routing_engine').description.includes('rollback deadline'));
	assert(options.get('_native_recovery_policy').cfgvalue().includes('Repair in place'));
	settings.native_migration_restrict_unknown = '1';
	await page.render([null,{available:true}]);
	assert(options.get('_native_saved_policy').cfgvalue().includes('Migration restriction'));
	assert(options.get('_native_migration_warning').cfgvalue().includes('not direct'));
	settings.native_classification_mode = 'invalid';
	await page.render([null,{available:true,engine:'native',phase:'active',classification:{mode:'strict',unknown:'protected'}}]);
	assert(options.get('_native_policy_state').cfgvalue().includes('invalid'));
	settings.routing_engine = 'legacy';
	await page.render([null,{available:false}]);
	assert(!options.get('routing_engine').values.some(row=>row[0]==='native'));
	console.log('Native classification LuCI PASS: selective defaults, explicit Strict opt-in, grant consent and compatible warning');
})().catch(e => { console.error(e); process.exitCode = 1; });
