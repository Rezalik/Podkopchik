'use strict';
const n=require('universal_plan'), net=require('awg_network');
const id='11111111111111111111111111111111', a=net.resources(id);
function ok(v,s){ if(!v)die(s+'\n'); }
function fixture(mode,migration) {
	return {lan:'br-lan',legacy_lans:['legacy0'],automatic:a.tag,unknown_candidates:[a.tag],
		classification:{mode,migration_restrict_unknown:migration,direct_grants_confirmed:true},
		adapters:[{id,type:'amneziawg',usable:true,ipv4:true,ipv6:true,source_ips:['198.51.1.1','2001:db8:1::1']}],
		fake_pools:['198.18.0.0/15'],bypass:['192.0.2.2'],clients:[{cidr:'10.19.0.3',target:'direct'}],
		ips:[{cidr:'203.0.113.82',target:'direct'},{cidr:'203.0.113.81',target:a.tag}],
		domains:[{names:['protected.example'],target:a.tag},{names:['direct.example'],target:'direct'}],
		synthetic:{epoch:'0011223344556677',pools:['172.31.253.0/24'],private_pool:'172.31.253.0/24',
			inventory:{addresses:[{addr_info:[{local:'10.19.0.1',prefixlen:24}]}],routes:[{dst:'default'}],
				issued:['198.18.0.0/15']},dns:{port:1058,ipv4:'10.19.0.1'}}};
}
const strict=n.compile(fixture('strict',false)), compat=n.compile(fixture('compatible',false)), migration=n.compile(fixture('compatible',true));
ok(n.classification().mode=='strict' && n.classification().unknown=='protected','missing mode must default to protected Strict, not implicit WAN');
const s=n.batch(strict), c=n.batch(compat), m=n.batch(migration), gate=n.dns_gate(strict);
ok(strict.classification.unknown=='protected' && compat.classification.unknown=='direct' && migration.classification.unknown=='protected','mode semantics');
ok(index(s,'meta mark set 67109377 return')>=0 && index(s,'meta mark 67109377 counter drop')>=0,'strict unknown must not forward');
ok(index(c,'67109377')<0 && index(m,'meta mark 67109377 counter drop')>=0,'migration restricts compatible without falsely changing mode');
ok(n.unknown_target(strict,'4','tcp')==a.tag && n.unknown_target(strict,'6','udp')==a.tag,'unknown uses the available protected adapter');
let unavailable=n.compile({...fixture('strict',false),automatic:'blocked',adapters:[{id,type:'amneziawg',usable:false,ipv4:true,ipv6:true,source_ips:['198.51.1.1','2001:db8:1::1']}]});
ok(n.unknown_target(unavailable,'4','tcp')=='blocked','all-down unknown has no direct fallback');
let protocol=fixture('strict',false);protocol.adapters=[{tag:'vless',type:'vless',port:23000,usable:true,ipv4:true,ipv6:true},...protocol.adapters];protocol.automatic='vless';
const mixed=n.compile(protocol);
ok(n.unknown_target(mixed,'4','tcp')=='vless' && n.unknown_target(mixed,'4','udp')==a.tag,'TCP-only primary cannot take UDP away from an available native backup');
protocol.adapters[1].ipv6=false;
const familyLimited=n.compile(protocol);
ok(n.unknown_target(familyLimited,'6','tcp')=='vless' && n.unknown_target(familyLimited,'6','udp')=='blocked','unsupported IPv6 UDP cannot fall through to WAN');
const rulesOnly=n.compile({...fixture('strict',false),automatic:'blocked',adapters:[
	{id,type:'amneziawg',usable:false,ipv4:true,ipv6:true,source_ips:['198.51.1.1','2001:db8:1::1']},
	{tag:'rules_only',type:'vless',port:23000,usable:true,ipv4:true,ipv6:true}]});
ok(n.unknown_target(rulesOnly,'4','tcp')=='blocked','a rules-only profile is not an implicit unknown fallback');
let blocked=fixture('strict',false);blocked.classification.unknown_action='block';
ok(n.compile(blocked).classification.unknown=='drop','explicit block option remains available');
ok(index(s,'ip daddr 203.0.113.82/32 meta mark set 67109376 counter accept')>=0,'literal direct grant');
ok(index(s,'ip saddr 10.19.0.3/32 meta mark set 67109376 counter accept')>=0,'whole-client direct grant');
ok(index(s,'ip daddr @fake4')<index(s,'ip daddr @bypass4'),'synthetic denial precedes direct grants');
ok(index(s,'ip saddr 10.19.0.3/32')<index(s,'ip daddr 203.0.113.81/32'),'client override precedence');
ok(index(s,'fib daddr type { local, broadcast, multicast } return')<index(s,'classify iifname "br-lan" ip saddr 10.19.0.3/32'),
	'router DHCP and IPv6 control-plane delivery precede client/fallback marking');
ok(index(s,'s_0011223344556677_g1_4')<0,'domain-only direct must not mint grants from DNS');
ok(index(gate,'meta mark 67109376 ct state new ct mark & 0xff000000 0 ct mark set')>=0,'pin direct grants to the original flow');
ok(index(gate,'meta mark 67109376 ct mark & 0xff000000 2130706432 return')>=0,'established direct flow retains explicit pin');
ok(index(gate,'restricted_forward iifname "br-lan" counter drop')>=0,'a missing classifier cannot authorize unmarked WAN');
const release=n.legacy_restore(strict);
ok(index(release,'delete table inet podkopchik_native\n')>=0 &&
	index(release,'restricted_forward')<0 && index(release,'dns_lan')<0,'legacy restore removes native-only classification and DNS interception');
ok(index(release,'add table inet podkopchik_native_gate')>=0 && index(release,'flush ruleset')<0 &&
	index(release,'ip daddr 172.31.253.0/24 counter drop')>=0,'legacy restore atomically replaces quarantine without a global flush');
ok(index(release,'iifname != { "lo", "legacy0", "br-lan" } ip daddr 198.18.0.0/15 counter drop')>=0,
	'old FakeDNS can return to local Xray on the restored native LAN');
ok(index(s,'dns_input_safety iifname "br-lan" meta l4proto { tcp, udp } th dport 53 counter drop')>=0,'a missing gate cannot expose the stock DNS listener');
let failed=false; try{n.switch_batch(strict,compat);}catch(e){failed=true;} ok(failed,'classification changes require a new transaction');
let pending=fixture('strict',true);pending.classification.direct_grants_confirmed=false;
failed=false;try{n.compile(pending);}catch(e){failed=true;}ok(failed,'unconfirmed legacy direct grants cannot activate silently');
const switched=n.compile({...fixture('strict',false),automatic:'blocked'});
ok(index(n.switch_batch(strict,switched),'meta mark 67109377 counter drop')>=0,'failover retains unknown deny');
for(let invalid in [{mode:'random'},{mode:'strict',migration_restrict_unknown:'1'}]) {
	failed=false; try{n.classification(invalid);}catch(e){failed=true;} ok(failed,'invalid classification refused');
}
print('Native classification PASS: strict, compatible, migration, explicit grants, precedence and conntrack pinning\n');
