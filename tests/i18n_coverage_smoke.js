'use strict';
const fs = require('fs');
const vm = require('vm');
const assert = require('assert');
const text = fs.readFileSync('po/ru/podkopchik.po', 'utf8');
const messages = new Map();
for (const entry of text.split(/\n\s*\n/)) {
	let id = '', value = '', field = '';
	for (const line of entry.split('\n')) {
		if (line.startsWith('msgid ')) { field = 'id'; id = JSON.parse(line.slice(6)); }
		else if (line.startsWith('msgstr ')) { field = 'value'; value = JSON.parse(line.slice(7)); }
		else if (line.startsWith('"')) {
			if (field === 'id') id += JSON.parse(line);
			else if (field === 'value') value += JSON.parse(line);
		}
	}
	if (id) messages.set(id, value);
}
const missing = new Set();
const dir = 'root/www/luci-static/resources/view/podkopchik';
for (const file of fs.readdirSync(dir).filter(name => name.endsWith('.js'))) {
	for (const m of fs.readFileSync(dir + '/' + file, 'utf8').matchAll(/_\(\s*('(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*")\s*\)/g)) {
		const id = vm.runInNewContext(m[1]);
		if (id !== 'Podkopchik' && !messages.get(id)) missing.add(id);
	}
}
const menu = JSON.parse(fs.readFileSync('root/usr/share/luci/menu.d/luci-app-podkopchik.json'));
for (const item of Object.values(menu)) {
	if (item.title && item.title !== 'Podkopchik' && !messages.get(item.title)) missing.add(item.title);
}
assert.deepStrictEqual([...missing], [], 'Untranslated LuCI strings: ' + [...missing].join(', '));
console.log('LuCI JS/menu i18n coverage OK');
