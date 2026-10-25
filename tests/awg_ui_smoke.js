'use strict';

const assert = require('assert');
const fs = require('fs');
const source = fs.readFileSync('root/www/luci-static/resources/view/podkopchik/awg.js', 'utf8');
const calls = [], notices = [];
let modal;
String.prototype.format = function(...args) { let i = 0; return this.replace(/%[sd]/g, () => String(args[i++])); };
function E(tag, attrs, children) {
	assert(/^[a-z][a-z0-9]*$/i.test(tag), 'DOM tag must be constant, not user input');
	return { tag, attrs: attrs || {}, children: [].concat(children || []),
		value: attrs && attrs.value || '', files: [],
		replaceChildren() { this.children = []; }, appendChild(child) { this.children.push(child); }
	};
}
const item = { id: 'a'.repeat(32), name: '<img src=x onerror=alert(1)>', status: 'valid',
	endpoints: ['vpn.example:443'], created_at: 1, checked_at: 1, config: 'SECRET_MUST_NOT_RENDER' };
const rpc = { declare(spec) {
	assert.strictEqual(spec.object, 'podkopchik.awg');
	return async (...args) => {
		calls.push({ method: spec.method, args });
		if (spec.method === 'list') return { ok: true, connections: [item] };
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
	assert(!/Connected|Available|Handshake/.test(text(dom)), 'must not claim tunnel availability');
	assert.strictEqual(page.handleSaveApply, null, 'must not invoke routing Apply');
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
	assert.deepStrictEqual(acl.write.ubus['podkopchik.awg'].slice().sort(), ['delete','import','rename','replace','validate']);
	for (const access of [acl.read.file, acl.write.file])
		assert(!Object.keys(access).some(x => x.includes('/etc/podkopchik/awg')), 'no raw secret file ACL');
	assert(!source.includes('fs.exec'), 'upload must use authenticated RPC, not command arguments');
	console.log('AWG LuCI import/edit/delete/render and least-privilege ACL smoke OK');
})().catch(e => { console.error(e.stack); process.exitCode = 1; });
