'use strict';

const fs = require('fs');

const source = fs.readFileSync('root/www/luci-static/resources/view/podkopchik/ip-rules.js', 'utf8');
const acl = fs.readFileSync('root/usr/share/rpcd/acl.d/luci-app-podkopchik.json', 'utf8');

function assertMatch(pattern, message) {
	if (!pattern.test(source))
		throw new Error(message);
}

assertMatch(/'require fs';/, 'IP Rules view must import fs for backend apply');
assertMatch(/'require ui';/, 'IP Rules view must import ui for LuCI apply flow');
assertMatch(/handleSaveApply\s*:\s*function/, 'IP Rules view must override Save & Apply');
assertMatch(/ui\.changes\.apply/, 'IP Rules Save & Apply must apply pending LuCI UCI changes');
assertMatch(/fs\.exec_direct\('\/usr\/bin\/podkopchikctl',\s*\[\s*'apply'\s*\]\)/, 'IP Rules Save & Apply must call podkopchikctl apply');

if (!acl.includes('"/usr/bin/podkopchikctl apply"'))
	throw new Error('rpcd ACL must allow /usr/bin/podkopchikctl apply');

console.log('IP Rules apply path smoke OK');
