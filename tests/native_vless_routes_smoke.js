'use strict';
const assert = require('assert');
const fs = require('fs');
const source = fs.readFileSync('root/usr/libexec/podkopchik/native_runtime.uc','utf8');
const a = source.indexOf('function owned_vless_route('), b = source.indexOf('\nfunction policy_routes',a);
const valid = new Function('index',source.slice(a,b)+';return owned_vless_route;')((xs,x) => xs.indexOf(x));
for (const type of ['local','2',2]) for (const dst of ['default','0.0.0.0/0','::/0']) {
	assert(valid({protocol:'188',dev:'lo',type,dst}));
}
for (const bad of [{protocol:186},{dev:'wan'},{type:'unicast'},{type:1},{dst:'192.0.2.1/32'}]) {
	assert(!valid({protocol:188,dev:'lo',type:'2',dst:'default',...bad}));
}
console.log('Native VLESS route ownership PASS: named/numeric iproute2 JSON, strict protocol/device/default destination');
