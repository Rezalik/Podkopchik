'use strict';

const fs = require('fs');
const source = fs.readFileSync('root/www/luci-static/resources/view/podkopchik/status.js', 'utf8');

function makeNode(tag, attrs, data) {
	if (typeof tag !== 'string')
		throw new Error('invalid tag');

	const node = {
		tag,
		attrs: attrs || {},
		children: [],
		style: {},
		textContent: '',
		appendChild(child) {
			this.children.push(child);
			return child;
		},
		removeChild(child) {
			const idx = this.children.indexOf(child);
			if (idx >= 0)
				this.children.splice(idx, 1);
		},
		get firstChild() {
			return this.children[0] || null;
		}
	};

	function add(child) {
		if (child === null || child === undefined || child === false || child === '')
			return;
		if (Array.isArray(child))
			child.forEach(add);
		else
			node.children.push(child);
	}

	add(data);
	return node;
}

function E(tag, attrs, data) {
	if (Array.isArray(tag))
		return tag;

	if (arguments.length === 2 && (attrs === null || typeof attrs !== 'object' || Array.isArray(attrs))) {
		data = attrs;
		attrs = {};
	}

	return makeNode(tag, attrs, data);
}

function textOf(node) {
	if (node === null || node === undefined || node === false)
		return '';
	if (typeof node === 'string' || typeof node === 'number')
		return String(node);
	if (Array.isArray(node))
		return node.map(textOf).join(' ');
	return (node.children || []).map(textOf).join(' ');
}

function walk(node, fn) {
	if (node === null || node === undefined || node === false)
		return;
	if (typeof node !== 'object')
		return;
	if (Array.isArray(node)) {
		node.forEach(child => walk(child, fn));
		return;
	}

	fn(node);
	(node.children || []).forEach(child => walk(child, fn));
}

function findCard(root, phrase) {
	let found = null;

	walk(root, node => {
		const style = node.attrs && node.attrs.style || '';

		if (!found && String(node.attrs && node.attrs.class || '').includes('cbi-section') &&
		    style.includes('min-height:118px') && textOf(node).includes(phrase))
			found = node;
	});

	return found;
}

if (!String.prototype.format) {
	String.prototype.format = function() {
		let i = 0;
		const args = arguments;
		return this.replace(/%[sd]/g, () => String(args[i++]));
	};
}

const modules = {
	view: { extend: obj => obj },
	fs: { exec_direct: () => Promise.resolve('') },
	ui: { createHandlerFn: () => function() {}, addNotification: function() {} },
	uci: {
		load: () => Promise.resolve(),
		sections: function(_config, type) {
			if (type === 'lan_device') {
				return [{
					enabled: '1',
					name: 'Kid tablet',
					source_ip: '192.168.1.50',
					speed_limit_enabled: '1',
					download_mbit: '10',
					upload_mbit: '3',
					speed_limit_mode: 'always'
				}];
			}

			if (type === 'proxy')
				return [{ tag: 'proxy_main', role: 'main', enabled: '1' }];

			if (type === 'domain_rule')
				return [{ enabled: '1', group_tag: 'youtube' }];

			return [];
		}
	}
};

const view = new Function('modules', 'E', '_',
	'var view = modules.view, fs = modules.fs, ui = modules.ui, uci = modules.uci;\n' + source
)(modules, E, s => s);

const statusText = [
	'Podkopchik 0.1.0-beta',
	'Service enabled: 1',
	'Routing applied: 0',
	'Configured proxies: 1',
	'Proxy groups: 1',
	'Domain rules: 1',
	'IP rules: 0',
	'LAN device rules: 1',
	'Xray: not running',
	'',
	'State: not recorded yet'
].join('\n');

const rendered = view.render([ statusText ]);
const text = textOf(rendered).replace(/\s+/g, ' ').trim();

if (!text.includes('Speed limits'))
	throw new Error('Status page did not render the Speed limits card');

if (!text.includes('Speed limits configured, diagnostics only'))
	throw new Error('Status page did not show diagnostic-only speed limit state');

if (!text.includes('Kid tablet'))
	throw new Error('Status page did not list the configured speed-limited device');

if (/\benforced\b/i.test(text))
	throw new Error('Status page must not claim speed limits are enforced');

const workingUncheckedStatus = [
	'Podkopchik 0.1.0-beta',
	'Service enabled: 1',
	'Routing applied: 1',
	'Configured proxies: 1',
	'Proxy groups: 1',
	'Domain rules: 1',
	'IP rules: 0',
	'LAN device rules: 0',
	'Xray: running',
	'',
	'State: not recorded yet'
].join('\n');
const workingUnchecked = view.render([ workingUncheckedStatus ]);
const workingUncheckedText = textOf(workingUnchecked).replace(/\s+/g, ' ').trim();
const uncheckedCard = findCard(workingUnchecked, 'Proxy availability check has not been updated yet.');

if (!workingUncheckedText.includes('Podkopchik is working'))
	throw new Error('Status page should not show a global warning when routing and Xray are active but health is not checked');

if (workingUncheckedText.includes('Main proxy has not been checked yet'))
	throw new Error('Status page still shows the misleading old main proxy health text');

if (!workingUncheckedText.includes('Routing can work if Xray is running and an active proxy is selected. Click "Check proxy availability" to refresh the status.'))
	throw new Error('Status page did not explain that routing can work without fresh health-check data');

if (!uncheckedCard)
	throw new Error('Status page did not render the primary proxy check card');

if (!String(uncheckedCard.attrs.style || '').includes('background:#f3f4f6'))
	throw new Error('Not-checked primary proxy status should be neutral gray, not warning');

if (String(uncheckedCard.attrs.style || '').includes('background:#fff8e1'))
	throw new Error('Not-checked primary proxy status must not use warning color');

const downStatus = [
	'Podkopchik 0.1.0-beta',
	'Service enabled: 1',
	'Routing applied: 1',
	'Configured proxies: 1',
	'Proxy groups: 1',
	'Domain rules: 1',
	'IP rules: 0',
	'LAN device rules: 0',
	'Xray: running',
	'',
	'State: {"proxies":{"proxy_main":{"status":"down","last_error":"probe failed"}}}'
].join('\n');
const downRendered = view.render([ downStatus ]);
const downCard = findCard(downRendered, 'Main proxy is unavailable');

if (!downCard)
	throw new Error('Status page did not render down primary proxy as unavailable');

if (!String(downCard.attrs.style || '').includes('background:#fdecea'))
	throw new Error('Down primary proxy should remain an error card');

console.log('Status speed-limits render smoke OK');

const originalSections = modules.uci.sections;
const awgID = 'a'.repeat(32), awgTag = 'awg_' + awgID;
modules.uci.sections = function(config, type) {
	if (type === 'proxy') return [
		{ tag: awgTag, protocol: 'amneziawg', awg_id: awgID, name: 'AWG main', role: 'main', enabled: '1' },
		{ tag: 'ibn', name: 'VLESS backup', role: 'backup', backup_priority: '1', enabled: '1' }
	];
	return originalSections(config, type);
};
const mixedState = { proxies: { [awgTag]: { status: 'up', checked_at: Date.now()/1000 } },
	groups: { auto_proxy_group: { active_proxy: awgTag } } };
const mixedStatus = workingUncheckedStatus.replace('State: not recorded yet', 'State: ' + JSON.stringify(mixedState));
const stoppedMixed = view.render([mixedStatus, null, { ok: true, connections: [
	{ id: awgID, tag: awgTag, runtime: { running: false, status: 'down', reason: 'stopped' } }
]}]);
if (!findCard(stoppedMixed, 'Main proxy is unavailable')) throw Error('Stopped AWG cannot inherit stale UP from cached health');
if (!textOf(stoppedMixed).includes('VLESS backup')) throw Error('Mixed backup name is missing');
mixedState.groups.auto_proxy_group.active_proxy = 'blocked';
const allDown = view.render([workingUncheckedStatus.replace('State: not recorded yet', 'State: '+JSON.stringify(mixedState))]);
const blockedCard = findCard(allDown, 'Matching traffic is blocked');
if (!blockedCard || !blockedCard.attrs.style.includes('background:#fdecea')) throw Error('All-down must render fail-closed as error');
console.log('Mixed AWG/VLESS Status render smoke OK: stopped override, backup labels, all-down blocking');
