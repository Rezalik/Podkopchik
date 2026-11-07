'use strict';
const assert = require('assert');
const fs = require('fs');
const net = require('net');
const source = fs.readFileSync('root/usr/libexec/podkopchik/generate.uc', 'utf8');
const start = source.indexOf('function pinned_vless(');
const end = source.indexOf('\n}\n', start) + 2;
assert(start > 0 && end > start);
const pin = new Function('require', 'type', 'die', 'length', `${source.slice(start, end)}; return pinned_vless;`)(
	() => ({ip: value => net.isIP(value) !== 0}), value => Array.isArray(value) ? 'array' : typeof value,
	message => { throw Error(message); }, value => value?.length || 0);
const original = {settings:{vnext:[{address:'vpn.example',port:443,users:[{id:'public-fixture'}]}]},
	streamSettings:{security:'reality',realitySettings:{serverName:'protected.example',publicKey:'public-fixture'}}};
const copy = JSON.parse(JSON.stringify(original));
pin(copy, {endpoint_pins:{'vpn.example':['192.0.2.2']}});
assert.strictEqual(copy.settings.vnext[0].address, '192.0.2.2');
assert.deepStrictEqual(copy.streamSettings, original.streamSettings);
assert.deepStrictEqual(copy.settings.vnext[0].users, original.settings.vnext[0].users);
assert.strictEqual(original.settings.vnext[0].address, 'vpn.example');
assert.throws(() => pin(JSON.parse(JSON.stringify(original)), {}), /verified Native VLESS bootstrap/);
assert.strictEqual(pin(copy, {}).settings.vnext[0].address, '192.0.2.2');
assert(source.includes("path=getenv('PODKOPCHIK_NATIVE_BOOTSTRAP_SPEC')"));
console.log('Native DNS bootstrap PASS: numeric VLESS dial address, unchanged Reality/users, no unpinned hostname fallback, Native-only health use');
