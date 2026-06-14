'use strict';

const fs = require('fs');

const sourcePath = 'root/www/luci-static/resources/view/podkopchik/proxies.js';
const source = fs.readFileSync(sourcePath, 'utf8');
const fakeUri = 'vless://11111111-2222-3333-4444-555555555555@example.invalid:443?type=tcp&security=reality&sni=example.invalid&fp=chrome&pbk=AAAA&sid=abcd#fake-proxy';

if (/require form|form\.GridSection|form\.TableSection/.test(source))
	throw new Error('Proxy Links view must not use CBI table/grid rendering');

const sections = [{
	'.type': 'proxy',
	'.name': 'cfgmain',
	enabled: '1',
	name: 'Germany',
	tag: 'proxy_germany',
	uri: fakeUri,
	role: 'main',
	detected_transport: 'tcp',
	detected_security: 'reality',
	note: 'Primary link'
}];

function matches(node, selector) {
	var m;

	if (!node || typeof node != 'object')
		return false;

	if (selector[0] == '#')
		return node.attrs && node.attrs.id == selector.slice(1);

	if (selector[0] == '.')
		return String(node.attrs && node.attrs.class || '').split(/\s+/).indexOf(selector.slice(1)) >= 0;

	m = selector.match(/^\[data-([a-z-]+)="([^"]+)"\]$/);
	if (m)
		return node.attrs && node.attrs['data-' + m[1]] == m[2];

	return false;
}

function walk(node, fn) {
	if (!node || typeof node != 'object')
		return;

	fn(node);
	(node.children || []).forEach(function(child) {
		walk(child, fn);
	});
}

function findNode(root, selector) {
	var found = null;

	walk(root, function(node) {
		if (!found && matches(node, selector))
			found = node;
	});

	return found;
}

function makeNode(tag, attrs, data) {
	var node;

	if (typeof tag != 'string' || !/^[A-Za-z][A-Za-z0-9-]*$/.test(tag))
		throw new Error('Invalid tag passed to E(): ' + tag);

	node = {
		tag: tag,
		attrs: attrs || {},
		children: [],
		style: {},
		value: attrs && Object.prototype.hasOwnProperty.call(attrs, 'value') ? attrs.value : '',
		checked: !!(attrs && attrs.checked),
		parentNode: null,
		dataset: {},
		appendChild: function(child) {
			if (child && typeof child == 'object')
				child.parentNode = this;

			this.children.push(child);
			return child;
		},
		remove: function() {
			var idx;

			if (!this.parentNode)
				return;

			idx = this.parentNode.children.indexOf(this);
			if (idx >= 0)
				this.parentNode.children.splice(idx, 1);
		},
		querySelector: function(selector) {
			return findNode(this, selector);
		},
		querySelectorAll: function(selector) {
			var out = [];

			walk(this, function(child) {
				if (matches(child, selector))
					out.push(child);
			});

			return out;
		},
		closest: function(selector) {
			var node = this;

			while (node) {
				if (matches(node, selector))
					return node;

				node = node.parentNode;
			}

			return null;
		}
	};

	Object.keys(attrs || {}).forEach(function(key) {
		if (key.indexOf('data-') == 0)
			node.dataset[key.slice(5).replace(/-([a-z])/g, function(_, c) { return c.toUpperCase(); })] = attrs[key];
	});

	function add(child) {
		if (child === null || child === undefined || child === false || child === '')
			return;

		if (Array.isArray(child))
			child.forEach(add);
		else
			node.appendChild(child);
	}

	add(data);

	if (tag == 'select') {
		var selected = node.children.find(function(child) {
			return child && typeof child == 'object' && child.attrs && child.attrs.selected;
		});
		var first = node.children.find(function(child) {
			return child && typeof child == 'object' && child.attrs && Object.prototype.hasOwnProperty.call(child.attrs, 'value');
		});

		node.value = selected ? selected.attrs.value : first ? first.attrs.value : node.value;
	}

	return node;
}

function E(tag, attrs, data) {
	if (Array.isArray(tag))
		return tag;

	if (arguments.length == 2 && (attrs === null || typeof attrs != 'object' || Array.isArray(attrs))) {
		data = attrs;
		attrs = {};
	}

	return makeNode(tag, attrs, data);
}

function visibleText(node, hidden) {
	var cls, style, nowHidden;

	if (node === null || node === undefined || node === false)
		return '';

	if (typeof node == 'string' || typeof node == 'number')
		return hidden ? '' : String(node);

	if (Array.isArray(node))
		return node.map(function(child) { return visibleText(child, hidden); }).join(' ');

	cls = String(node.attrs && node.attrs.class || '');
	style = String(node.attrs && node.attrs.style || '');
	nowHidden = hidden || cls.split(/\s+/).indexOf('podkopchik-proxy-edit') >= 0 || /display\s*:\s*none/.test(style);

	if (nowHidden)
		return '';

	return (node.children || []).map(function(child) {
		return visibleText(child, nowHidden);
	}).join(' ');
}

const modules = {
	view: { extend: function(obj) { return obj; } },
	fs: {},
	ui: {
		createHandlerFn: function(ctx, fn) { return function() { return ctx[fn](); }; },
		showModal: function() {},
		hideModal: function() {},
		changes: { apply: function() { return Promise.resolve(); } }
	},
	uci: {
		sections: function(_config, type) { return type == 'proxy' ? sections : []; },
		get: function(_config, sid, option) {
			var section = sections.find(function(item) { return item['.name'] == sid; });
			return section ? section[option] : undefined;
		},
		add: function(_config, type) {
			var id = 'cfg' + (sections.length + 1);
			sections.push({ '.type': type, '.name': id });
			return id;
		},
		set: function(_config, sid, option, value) {
			var section = sections.find(function(item) { return item['.name'] == sid; });

			if (!section) {
				section = { '.type': 'proxy', '.name': sid };
				sections.push(section);
			}

			section[option] = value;
		},
		unset: function(_config, sid, option) {
			var section = sections.find(function(item) { return item['.name'] == sid; });
			if (section)
				delete section[option];
		},
		remove: function(_config, sid) {
			var idx = sections.findIndex(function(item) { return item['.name'] == sid; });
			if (idx >= 0)
				sections.splice(idx, 1);
		},
		save: function() { return Promise.resolve(); },
		load: function() { return Promise.resolve(); }
	}
};

const L = { resolveDefault: function(_promise, fallback) { return Promise.resolve(fallback); } };
const fakeWindow = { setTimeout: function() {}, location: { reload: function() {} } };
const fakeDocument = {
	querySelectorAll: function() { return []; },
	createElement: function(tag) { return makeNode(tag, {}, []); },
	execCommand: function() {}
};

if (!String.prototype.format) {
	String.prototype.format = function() {
		var i = 0;
		var args = arguments;
		return this.replace(/%[sd]/g, function() { return String(args[i++]); });
	};
}

const factory = new Function('modules', 'E', '_', 'L', 'window', 'document',
	'var view = modules.view, fs = modules.fs, ui = modules.ui, uci = modules.uci;\n' + source);
const view = factory(modules, E, function(s) { return s; }, L, fakeWindow, fakeDocument);
const state = { proxies: { proxy_germany: { status: 'up', latency_ms: 85 } } };

Promise.resolve(view.render([null, state])).then(function(page) {
	var root = Array.isArray(page) ? { attrs: {}, children: page } : page;
	var list = findNode(root, '#podkopchik-proxy-list');
	var uriInput = findNode(root, '[data-field="uri"]');
	var text;

	if (!list)
		throw new Error('Proxy list container was not rendered');

	if (list.attrs['data-renderer'] != 'compact-proxy-cards')
		throw new Error('Proxy Links view did not use the compact card renderer');

	if (!uriInput)
		throw new Error('Proxy Links edit form did not render the VLESS URI input');

	if (uriInput.attrs.type == 'password')
		throw new Error('Proxy Links edit form must not hide the VLESS URI as a password field');

	if (uriInput.attrs.type != 'text')
		throw new Error('Proxy Links edit form VLESS URI input should be a visible text field');

	text = visibleText(list, false).replace(/\s+/g, ' ').trim();

	if (text.indexOf(fakeUri) >= 0)
		throw new Error('Visible Proxy Links list leaked the full VLESS URI');

	if (/\bmain\b/.test(text))
		throw new Error('Visible Proxy Links list exposed raw role value "main"');

	if (text.indexOf('Backup #') >= 0)
		throw new Error('Visible Proxy Links list showed backup priority for a main proxy');

	if (text.indexOf('Main proxy') < 0)
		throw new Error('Visible Proxy Links list did not show human-readable main role');

	if (text.indexOf('example.invalid:443') < 0)
		throw new Error('Visible Proxy Links list did not show a shortened URI host');

	if (text.indexOf('TCP') < 0 || text.indexOf('Reality') < 0)
		throw new Error('Visible Proxy Links list did not show compact detected transport/security');

	console.log('Proxy Links visible-list smoke OK');
}).catch(function(err) {
	console.error(err && err.stack || err);
	process.exit(1);
});
