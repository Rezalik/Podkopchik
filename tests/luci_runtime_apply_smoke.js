'use strict';

const fs = require('fs');

const acl = fs.readFileSync('root/usr/share/rpcd/acl.d/luci-app-podkopchik.json', 'utf8');

function read(path) {
	return fs.readFileSync(path, 'utf8');
}

function assertMatch(source, pattern, message) {
	if (!pattern.test(source))
		throw new Error(message);
}

function assertApplyPage(path, label) {
	const source = read(path);

	assertMatch(source, /'require fs';/, label + ' must import fs for backend apply');
	assertMatch(source, /'require ui';/, label + ' must import ui for LuCI Save & Apply flow');
	assertMatch(source, /handleSaveApply\s*:\s*function/, label + ' must override Save & Apply');
	assertMatch(source, /return\s+ui\.changes\.apply/, label + ' must wait for LuCI UCI apply before runtime apply');
	assertMatch(source, /fs\.exec_direct\('\/usr\/bin\/podkopchikctl',\s*\[\s*'apply'\s*\]\)/, label + ' must call podkopchikctl apply');
	assertMatch(source, /'require podkopchik\.routing as routing';/, label + ' must load the shared policy/confirmation helper');
	assertMatch(source, /routing\.notifyApply\(res\)/, label + ' must explain pending Native confirmation');
}

[
	[ 'root/www/luci-static/resources/view/podkopchik/domain-rules.js', 'Domain Groups' ],
	[ 'root/www/luci-static/resources/view/podkopchik/ip-rules.js', 'IP Rules' ],
	[ 'root/www/luci-static/resources/view/podkopchik/bypass-rules.js', 'Exclusions' ],
	[ 'root/www/luci-static/resources/view/podkopchik/proxies.js', 'Proxy Links' ],
	[ 'root/www/luci-static/resources/view/podkopchik/groups.js', 'Advanced proxy groups' ],
	[ 'root/www/luci-static/resources/view/podkopchik/lan-devices.js', 'LAN Devices' ],
	[ 'root/www/luci-static/resources/view/podkopchik/dns.js', 'DNS' ]
].forEach(function(item) {
	assertApplyPage(item[0], item[1]);
});

const advanced = read('root/www/luci-static/resources/view/podkopchik/advanced.js');
assertMatch(advanced, /handleSaveApply\s*:\s*function/, 'Advanced settings must override Save & Apply');
assertMatch(advanced, /return\s+ui\.changes\.apply/, 'Advanced settings must wait for LuCI UCI apply');
assertMatch(advanced, /runRuntime\(\s*\[\s*'apply'\s*\]\s*\)/, 'Advanced settings must apply runtime changes when routing is active');
assertMatch(advanced, /runRuntime\(\s*\[\s*'cleanup'\s*\]\s*\)/, 'Advanced settings must cleanup routing when service is disabled');
assertMatch(advanced, /enabled == '0' \|\| routing == '0'/, 'Explicit routing OFF must release Native runtime without relying on a UCI reload restart');
assertMatch(advanced, /routing\.notifyApply\(res\)/, 'Advanced must explain pending Native confirmation');

const presets = read('root/www/luci-static/resources/view/podkopchik/presets.js');
assertMatch(presets, /'require fs';/, 'Presets view must import fs for backend apply');
assertMatch(presets, /'require ui';/, 'Presets view must import ui for LuCI apply flow');
assertMatch(presets, /ui\.changes\.apply/, 'Presets Add preset action must apply pending LuCI UCI changes');
assertMatch(presets, /fs\.exec_direct\('\/usr\/bin\/podkopchikctl',\s*\[\s*'apply'\s*\]\)/, 'Presets Add preset action must call podkopchikctl apply');
assertMatch(presets, /routing\.notifyApply\(res\)/, 'Preset application must explain pending Native confirmation');

if (!acl.includes('"/usr/bin/podkopchikctl apply"'))
	throw new Error('rpcd ACL must allow /usr/bin/podkopchikctl apply');

if (!acl.includes('"/usr/bin/podkopchikctl cleanup"'))
	throw new Error('rpcd ACL must allow /usr/bin/podkopchikctl cleanup');

assertMatch(read('tools/install-native-rc-files.sh'), /www\/luci-static\/resources\/podkopchik\/\*\.js/,
	'The Native RC installer must include shared LuCI modules, not just views');
for (const file of ['tools/install-native-rc-files.sh', 'tools/install-luci-alignment.sh']) {
	assertMatch(read(file), /if \[ "\$\(uci -q get podkopchik\.main\.native_recovery_policy[^\n]+ = repair \]; then\s+ucode \/etc\/podkopchik-native-emergency\/recovery\.uc verify/,
		'A transactional static-file update must not require a retired emergency capsule');
}

console.log('LuCI runtime apply smoke OK');
