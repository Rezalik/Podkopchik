'use strict';
const assert = require('assert');
const fs = require('fs');
const { spawnSync } = require('child_process');
const fixture = JSON.parse(fs.readFileSync('tests/fixtures/openwrt-25.12.6-packages.json'));
const install = fs.readFileSync('install.sh', 'utf8');
const dependencies = install.match(/DEPENDENCIES="([\s\S]*?)"/)[1].trim().split(/\s+/);
const makefile = fs.readFileSync('Makefile', 'utf8');
const recipe = makefile.slice(0, makefile.indexOf('LUCI_TITLE')).replace(/^include .*$/gm, '') +
	'\nprint-version:\n\t@printf "%s" "$(PKG_VERSION)"\n';
for (const [useApk, expected] of [['', '0.1.0-beta'], ['y', '0.1.0_beta']]) {
	const result = spawnSync('make', ['-f', '-', 'CONFIG_USE_APK=' + useApk, 'print-version'], { input: recipe, encoding: 'utf8' });
	assert.equal(result.status, 0, result.stderr);
	assert.equal(result.stdout, expected, 'Incorrect package prerelease version');
}
dependencies.forEach(name => {
	assert(fixture.packages[name], 'Unverified 25.12.6 dependency: ' + name);
	assert(fixture.feeds[fixture.packages[name].feed], 'Missing feed: ' + name);
	assert(makefile.includes('+' + name), 'Makefile missing dependency: ' + name);
});
assert.equal(fixture.packages['kmod-nft-tproxy'].version, '6.12.112-r1');
assert(dependencies.includes('rpcd-mod-file'));
assert(dependencies.includes('luci-light'));
const cli = fs.readFileSync('root/usr/bin/podkopchikctl', 'utf8');
const update = cli.slice(cli.indexOf('cmd_update_install()'), cli.indexOf('cmd_rollback()'));
assert(update.includes('sh "$installer"'), 'Application update must delegate to the dual-manager installer');
assert(update.includes('cp -p "$UCI_CONFIG" "$update_config_backup"'), 'Independent update config backup missing');
assert(update.includes("trap 'restore_update_config'"), 'Application update must restore config on failure');
console.log('25.12.6 dependency coverage OK (' + dependencies.length + ' packages; recorded feed snapshot, not a live solver test)');
