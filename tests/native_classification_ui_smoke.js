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
const page = new Function('view', 'form', 'fs', 'ui', 'uci', '_', 'E', source)(
	{ extend: x => x }, form, {}, { createHandlerFn: () => () => {} }, {}, x => x, () => ({}));
(async () => {
	await page.render();
	const mode = options.get('native_classification_mode');
	assert.deepStrictEqual(mode.values, [['strict', 'Strict'], ['compatible', 'Compatible']]);
	assert.strictEqual(mode.default, 'strict');
	assert(mode.description.includes('legacy routing is unchanged'));
	const warning = options.get('_native_compatible_warning');
	assert.deepStrictEqual(warning.dependencies, [['native_classification_mode', 'compatible']]);
	assert(warning.cfgvalue().includes('not guaranteed'));
	assert.strictEqual(options.get('native_migration_restrict_unknown').default, '1');
	assert.strictEqual(options.get('native_direct_grants_confirmed').default, '0');
	assert(options.get('native_direct_grants_confirmed').description.includes('override domain protection'));
	assert(options.get('native_direct_grants_confirmed').description.includes('shared CDN IP'));
	assert(options.get('_native_strict_warning').cfgvalue().includes('unknown-traffic policy'));
	assert.strictEqual(options.get('native_unknown_action').default, 'protected');
	console.log('Native classification LuCI PASS: real options, migration default, explicit grant consent and compatible warning');
})().catch(e => { console.error(e); process.exitCode = 1; });
