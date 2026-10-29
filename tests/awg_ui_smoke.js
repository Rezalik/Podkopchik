'use strict';

const assert = require('assert');
const fs = require('fs');
const source = fs.readFileSync('root/www/luci-static/resources/view/podkopchik/awg.js', 'utf8');
const calls = [], notices = [];
let modal, flags = {};
String.prototype.format = function(...args) { let i = 0; return this.replace(/%[sd]/g, () => String(args[i++])); };
function E(tag, attrs, children) {
	assert(/^[a-z][a-z0-9]*$/i.test(tag), 'DOM tag must be constant, not user input');
	return { tag, attrs: attrs || {}, children: [].concat(children || []),
		value: attrs && attrs.value || '', files: [], style: {},
		checked: !!(attrs && Object.hasOwn(attrs, 'checked')),
		addEventListener(name, fn) { this.attrs[name] = fn; },
		replaceChildren() { this.children = []; }, appendChild(child) { this.children.push(child); }
	};
}
const item = { id: 'a'.repeat(32), name: '<img src=x onerror=alert(1)>', status: 'valid',
	endpoints: ['vpn.example:443'], created_at: 1, checked_at: 1, config: 'SECRET_MUST_NOT_RENDER' };
const rpc = { declare(spec) {
	assert.strictEqual(spec.object, 'podkopchik.awg');
	return async (...args) => {
		calls.push({ method: spec.method, args });
		if (spec.method === 'list') return { ok: true, connections: [item], ...flags };
		if (spec.method === 'set_interception') flags = { udp_interception: args[0] === '1', ipv6_interception: args[1] === '1' };
		return { ok: true };
	};
} };
const ui = { showModal(title, nodes) { modal = E('section', {}, [title, ...nodes]); }, hideModal() { modal = null; },
	addNotification(_title, node) { notices.push(node); } };
const page = new Function('view', 'rpc', 'ui', 'E', '_', source)({ extend: x => x }, rpc, ui, E, x => x);
function walk(node, fn) { if (!node || typeof node !== 'object') return; fn(node); node.children.forEach(child => walk(child, fn)); }
function find(root, pred) { let found; walk(root, n => { if (!found && pred(n)) found = n; }); return found; }
function text(node) { return node && typeof node === 'object' ? node.children.map(text).join(' ') : String(node || ''); }
async function settle() { for (let i = 0; i < 20; i++) { await new Promise(r => setImmediate(r)); if (!page.busy) return; } throw Error('operation did not settle'); }
(async () => {
	const dom = page.render(await page.load());
	assert(text(dom).includes('Configuration is valid'));
	assert(text(dom).includes(item.name), 'untrusted name remains text');
	assert(!text(dom).includes('SECRET_MUST_NOT_RENDER'));
	assert(!text(dom).includes('Available'), 'no UP claim without real runtime evidence');
	assert.strictEqual(page.handleSaveApply, null, 'must not invoke routing Apply');
	function boxes(dom) { const result=[]; walk(dom, n => { if(n.tag==='input' && n.attrs.type==='checkbox') result.push(n); }); return result; }
	let controls = boxes(dom);
	assert.strictEqual(controls.length, 2, 'UDP and IPv6 are independent');
	assert(controls.every(n => n.checked === false && !Object.hasOwn(n.attrs, 'checked')), 'unset flags must not create checked=false HTML attributes');
	controls[0].checked = true; controls[0].attrs.change(); await settle();
	assert.deepStrictEqual(calls.find(x => x.method === 'set_interception').args, ['1','0']);
	controls = boxes(page.render(await page.load()));
	assert(controls[0].checked && !controls[1].checked, 'saved flags survive a fresh render/load');
	const freshPage = new Function('view','rpc','ui','E','_',source)({extend:x=>x},rpc,ui,E,x=>x);
	controls = boxes(freshPage.render(await freshPage.load()));
	assert(controls[0].checked && !controls[1].checked, 'new LuCI session reads backend values');
	controls = boxes(page.render({connections:[],udp_interception:'0',ipv6_interception:'0'}));
	assert(controls.every(n=>!n.checked), 'truthy strings must never enable a checkbox');
	find(dom, n => n.tag === 'button' && text(n) === 'Import .conf').attrs.click();
	let name = find(modal, n => n.tag === 'input' && n.attrs.type === 'text');
	let file = find(modal, n => n.tag === 'input' && n.attrs.type === 'file');
	name.value = 'First profile'; file.files = [{ name: '../../same.conf', size: 20, text: async () => 'SYNTHETIC_CONFIG' }];
	find(modal, n => n.tag === 'button' && text(n) === 'Import').attrs.click(); await settle();
	assert.deepStrictEqual(calls.find(x => x.method === 'import').args, ['First profile', 'SYNTHETIC_CONFIG']);
	assert(!JSON.stringify(calls).includes('../../'), 'original filename must never reach backend');
	page.editConnection(item);
	find(modal, n => n.tag === 'input' && n.attrs.type === 'text').value = 'New name';
	find(modal, n => n.tag === 'button' && text(n) === 'Save').attrs.click(); await settle();
	assert.deepStrictEqual(calls.find(x => x.method === 'rename').args, [item.id, 'New name']);
	page.editConnection(item);
	find(modal, n => n.tag === 'input' && n.attrs.type === 'file').files = [{ name: 'new.conf', size: 2, text: async () => 'REPLACEMENT' }];
	find(modal, n => n.tag === 'button' && text(n) === 'Save').attrs.click(); await settle();
	assert.deepStrictEqual(calls.find(x => x.method === 'replace').args, [item.id, item.name, 'REPLACEMENT']);
	page.editConnection(null);
	find(modal, n => n.tag === 'input' && n.attrs.type === 'text').value = 'Oversize';
	find(modal, n => n.tag === 'input' && n.attrs.type === 'file').files = [{ name: 'big.conf', size: 65537, text() { throw Error('must not read'); } }];
	const before = calls.filter(x => x.method === 'import').length;
	find(modal, n => n.tag === 'button' && text(n) === 'Import').attrs.click(); await settle();
	assert.strictEqual(calls.filter(x => x.method === 'import').length, before);
	assert(text(notices.at(-1)).includes('64 KiB'));
	const list = page.render({ ok: true, connections: [item] });
	find(list, n => n.tag === 'button' && text(n) === 'Check configuration').attrs.click(); await settle();
	assert(calls.some(x => x.method === 'validate' && x.args[0] === item.id));
	find(list, n => n.tag === 'button' && text(n) === 'Delete').attrs.click();
	assert(!calls.some(x => x.method === 'delete'), 'delete must require confirmation');
	find(modal, n => n.tag === 'button' && text(n) === 'Delete').attrs.click(); await settle();
	assert(calls.some(x => x.method === 'delete' && x.args[0] === item.id));
	const acl = JSON.parse(fs.readFileSync('root/usr/share/rpcd/acl.d/luci-app-podkopchik.json'))['luci-app-podkopchik'];
	assert.deepStrictEqual(acl.read.ubus['podkopchik.awg'], ['list']);
	assert.deepStrictEqual(acl.write.ubus['podkopchik.awg'].slice().sort(), ['assign','check','delete','import','recover','rename','replace','restart','set_interception','set_probe','start','stop','validate']);
	page.assignConnection(item);
	const selects = [];
	walk(modal, n => { if (n.tag === 'select') selects.push(n); });
	selects[0].value = 'backup'; selects[1].value = '2';
	find(modal, n => n.tag === 'button' && text(n) === 'Apply settings').attrs.click(); await settle();
	assert.deepStrictEqual(calls.find(x => x.method === 'assign').args, ['awg_' + item.id, 'backup', '2']);
	page.probeSettings(item);
	find(modal, n => n.tag === 'button' && text(n) === 'Save').attrs.click(); await settle();
	assert(calls.some(x => x.method === 'set_probe' && x.args[0] === item.id));
	for (const [label, method] of [['Start','start'], ['Stop','stop'], ['Restart','restart'], ['Check connection','check']]) {
		find(list, n => n.tag === 'button' && text(n) === label).attrs.click(); await settle();
		assert(calls.some(x => x.method === method && x.args[0] === item.id));
	}
	for (const access of [acl.read.file, acl.write.file])
		assert(!Object.keys(access).some(x => x.includes('/etc/podkopchik/awg')), 'no raw secret file ACL');
	assert(!source.includes('fs.exec'), 'upload must use authenticated RPC, not command arguments');
	console.log('AWG LuCI import/edit/delete/render and least-privilege ACL smoke OK');
})().catch(e => { console.error(e.stack); process.exitCode = 1; });
