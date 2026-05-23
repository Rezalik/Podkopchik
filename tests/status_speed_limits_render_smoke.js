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

console.log('Status speed-limits render smoke OK');
