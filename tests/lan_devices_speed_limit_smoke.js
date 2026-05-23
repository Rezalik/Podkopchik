'use strict';

const fs = require('fs');
const source = fs.readFileSync('root/www/luci-static/resources/view/podkopchik/lan-devices.js', 'utf8');

function assertContains(pattern, message) {
	if (!pattern.test(source))
		throw new Error(message);
}

assertContains(/source_ip'[\s\S]*?datatype\s*=\s*'ipaddr'/, 'Source IP must use LuCI ipaddr validation');
assertContains(/function validatePositiveRate/, 'Speed limits must validate positive Mbit/s rates');
assertContains(/function validateTime/, 'Schedule fields must validate HH:MM time');
assertContains(/speed_limit_enabled/, 'Speed limit enabled option is missing');
assertContains(/download_mbit/, 'Download speed option is missing');
assertContains(/upload_mbit/, 'Upload speed option is missing');
assertContains(/speed_limit_mode/, 'Speed limit mode option is missing');
assertContains(/speed_limit_hours/, 'Temporary duration option is missing');
assertContains(/schedule_start/, 'Schedule start option is missing');
assertContains(/schedule_end/, 'Schedule end option is missing');
assertContains(/unlimited_window_start/, 'Unlimited window start option is missing');
assertContains(/unlimited_window_end/, 'Unlimited window end option is missing');
assertContains(/auto_proxy_group/, 'Automatic main/backups target is missing');
assertContains(/Speed limit enforcement is not active in this beta/, 'Diagnostic-only warning is missing');
assertContains(/Always limited/, 'Always limited mode is missing');
assertContains(/Limit for N hours/, 'Duration mode is missing');
assertContains(/Unlimited during time window/, 'Unlimited window mode is missing');

const prefix = source.split('return view.extend')[0];
const validators = new Function('_', prefix + '\nreturn { validatePositiveRate, validateHours, validateTime };')(s => s);

if (validators.validatePositiveRate(null, '0') === true)
	throw new Error('Invalid zero speed must be rejected');

if (validators.validatePositiveRate(null, '-1') === true)
	throw new Error('Invalid negative speed must be rejected');

if (validators.validatePositiveRate(null, '10.5') !== true)
	throw new Error('Positive decimal speed must be accepted');

if (validators.validateHours(null, '0') === true)
	throw new Error('Invalid zero temporary duration must be rejected');

if (validators.validateHours(null, '6') !== true)
	throw new Error('Preset-like temporary duration must be accepted');

if (validators.validateTime(null, '24:00') === true)
	throw new Error('Invalid HH:MM time must be rejected');

if (validators.validateTime(null, '00:00') !== true || validators.validateTime(null, '06:00') !== true)
	throw new Error('Valid HH:MM time window values must be accepted');

console.log('LAN Devices speed-limit UI smoke OK');
