'use strict';
const model = require('interception');
let n=0;
function check(value, label) { if (!value) die('FAIL: '+label); n++; }
let f=model.settings({});
check(!f.udp && !f.ipv6, 'absent options default off');
f=model.settings({extended_interception:'1'});
check(f.udp && f.ipv6, 'legacy explicit opt-in remains readable');
f=model.settings({extended_interception:'1',udp_interception:'0',ipv6_interception:'0'});
check(!f.udp && !f.ipv6, 'explicit new options override legacy');
f=model.settings({udp_interception:'1',ipv6_interception:'0'});
check(f.udp && !f.ipv6, 'UDP does not enable IPv6');
f=model.settings({udp_interception:'0',ipv6_interception:'1'});
check(!f.udp && f.ipv6, 'IPv6 does not enable UDP');
function lan(scope, flags) { return model.lan_ipv6([{ifname:'br-lan',addr_info:[{family:'inet6',scope:scope,flags:flags}]}],'br-lan'); }
check(!lan('link',[]), 'link-local LAN alone is insufficient');
check(!lan('global',['tentative']) && !lan('global',['dadfailed']), 'unusable LAN addresses rejected');
check(!model.lan_ipv6([{ifname:'br-lan',addr_info:[{family:'inet6',scope:'global',tentative:true}]}],'br-lan'), 'iproute2 tentative boolean rejected');
check(lan('global',[]), 'usable LAN IPv6 accepted without assuming WAN support');
check(!model.profile_ipv6({interface:{Address:'10.66.0.2/32'},peers:[{AllowedIPs:'::/0'}]}), 'AllowedIPs alone insufficient');
check(!model.profile_ipv6({interface:{Address:'fd00::2/128'},peers:[{AllowedIPs:'2001:db8::/32'}]}), 'partial allowed prefixes not advertised as full IPv6');
check(!model.profile_ipv6({interface:{Address:'fe80::2/128'},peers:[{AllowedIPs:'::/0'}]}), 'link-local tunnel address insufficient');
check(model.profile_ipv6({interface:{Address:'10.66.0.2/32, fd00::2/128'},peers:[{AllowedIPs:'0.0.0.0/0, ::/0'}]}), 'dual-stack profile accepted');
printf('Interception model native smoke OK (%d assertions)\n',n);
