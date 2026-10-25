'use strict';
const assert = require('assert');
const fs = require('fs');
const source = fs.readFileSync('root/www/luci-static/resources/view/podkopchik/updates.js', 'utf8');
function E(tag, attrs, children) {
	if (arguments.length === 2 && (typeof attrs === 'string' || Array.isArray(attrs))) { children = attrs; attrs = {}; }
	const node = { tag, attrs: attrs || {}, children: [], disabled: false, textContent: '',
		appendChild(child) { this.children.push(child); },
		removeChild(child) { this.children.splice(this.children.indexOf(child), 1); },
		get firstChild() { return this.children[0]; },
		addEventListener(name, fn) { this.attrs[name] = fn; }
	};
	for (const child of [].concat(children || [])) node.appendChild(child);
	if (tag === 'select') node.value = node.children[0].attrs.value;
	return node;
}
function text(node) { return typeof node === 'string' ? node : node.textContent + node.children.map(text).join(' '); }
function all(node, tag) { return typeof node === 'string' ? [] : (node.tag === tag ? [node] : []).concat(...node.children.map(child => all(child, tag))); }
const calls = [];
const backend = { exec_direct: async (command, args) => { calls.push(args); return 'installed=25.1.30\nsource=package\narchitecture=aarch64\nstatus=verified\njob_id=fixture\njob_status=done\n'; } };
const api = new Function('fs', 'ui', 'E', '_', source.slice(0, source.indexOf('return view.extend({')) + '\nreturn { renderCore };')(backend, { addNotification() {} }, E, s => s);
(async () => {
	const card = api.renderCore('installed=25.1.30\nsource=package\narchitecture=aarch64\nstatus=not_checked\n');
	assert(text(card).includes('Installed Xray version'));
	assert(text(card).includes('25.1.30'));
	assert(text(card).includes('Not checked yet'));
	const select = all(card, 'select')[0];
	select.value = 'official';
	select.attrs.change();
	const buttons = all(card, 'button');
	await buttons[0].attrs.click({ preventDefault() {} });
	assert.deepStrictEqual(calls[0], [ 'xray-start-check', 'official' ]);
	await buttons[1].attrs.click({ preventDefault() {} });
	assert(calls.some(args => args.join(' ') === 'xray-start-install official'));
	await buttons[2].attrs.click({ preventDefault() {} });
	assert(calls.some(args => args.join(' ') === 'xray-start-rollback'));
	assert(buttons.every(button => !button.disabled));
	console.log('Xray Updates render/action smoke OK');
})().catch(err => { console.error(err.message); process.exitCode = 1; });
