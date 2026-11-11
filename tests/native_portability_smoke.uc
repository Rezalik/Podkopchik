'use strict';
import {readfile} from 'fs';
const package_policy=require('native_package'), inventory=require('native_inventory');
let catalog=json(readfile(ARGV[0])), a=json(readfile(ARGV[1])), f=json(readfile(ARGV[2])), host=json(readfile(ARGV[3]));
let total=0;
function ok(v,label){total++;if(!v)die('FAIL: '+label+'\n');}
function rejects(fn,label){let rejected=false;try{fn();}catch(e){rejected=true;}ok(rejected,label);}
ok(package_policy.admit(catalog,f,host).status=='requirements_met','Flint matching prerequisites');
rejects(()=>package_policy.admit(catalog,a,host),'Xiaomi package on Flint');
rejects(()=>package_policy.admit(catalog,f,{...host,os:{...host.os,board:a.platform.board}}),'Flint package on Xiaomi');
rejects(()=>package_policy.admit(catalog,f,{...host,os:{...host.os,board:'unknown,board'}}),'unknown board');
rejects(()=>package_policy.admit(catalog,f,{...host,os:{...host.os,kernel:'6.6.1'}}),'wrong kernel');
rejects(()=>package_policy.admit(catalog,f,{...host,firewall:{...host.firewall,flowtables:1}}),'active flowtable');
rejects(()=>package_policy.admit(catalog,f,{...host,firewall:{...host.firewall,flowtables:null}}),'unknown flowtable');
rejects(()=>package_policy.admit(catalog,f,{...host,awg:{...host.awg,loaded:false}}),'required AWG missing');
rejects(()=>package_policy.validate(catalog,{...f,platform:a.platform}),'inconsistent manifest');
rejects(()=>package_policy.validate(catalog,{...f,components:{...f.components,helper:{...f.components.helper,abi:'linux-mips'}}}),'wrong binary ABI');
let v={lan:'lan-custom',dns_port:'24253',addresses:[{ifname:'lan-custom',addr_info:[{family:'inet',scope:'global',local:'192.168.8.1',prefixlen:24}]}],
	routes:[{dst:'default',gateway:'192.168.7.1'},{dst:'192.168.8.0/24'}],rules:[{priority:32766,table:254}],
	ports:[],nft_tables:[],issued:[],endpoints:['192.0.2.1'],exclusions:[],pools:['198.19.0.0/24'],endpoint_inventory_complete:true,
	profiles:[{valid:true,protocol:'vless',role:'main',tag:'PRIVATE_TEST_TAG'}]};
let r=inventory.assess(v);
ok(r.status=='no_observed_conflicts'&&!r.activation_authorized&&!r.installation_authorized,'clean inventory not authorization');
ok(r.lan_families.ipv4==1 && r.profiles.vless==1 && r.roles.main==1,'custom LAN and profile summary');
ok(index(sprintf('%J',r),'192.168.8.1')<0&&index(sprintf('%J',r),'PRIVATE_TEST_TAG')<0,'private data is not reflected');
ok(inventory.assess({...v,pools:['192.168.8.0/24']}).issues.native_pool_overlap_or_existing_ownership==1,'overlap with local LAN');
ok(inventory.assess({...v,issued:v.pools}).issues.native_pool_overlap_or_existing_ownership==1,'overlap with issued pool');
ok(inventory.assess({...v,routes:[...v.routes,{dst:'198.19.0.0/25'}]}).issues.native_pool_overlap_or_existing_ownership==1,'overlap with VPN route');
ok(inventory.assess({...v,ports:[24253,23037]}).issues.occupied_listener_port==2,'DNS and VLESS port occupancy');
ok(inventory.assess({...v,ports:null}).issues.socket_inventory_incomplete==1,'missing socket evidence');
ok(inventory.assess({...v,profiles:[{...v.profiles[0],unresolved:true}]}).issues.named_endpoint_requires_resolution==1,'no DNS lookup implied');
ok(inventory.assess({...v,rules:[{priority:1,fwmark:'0x4000000',fwmask:'0xff000000'}]}).issues.existing_policy_rule_requires_ownership_review==1,'masked mark overlap');
ok(inventory.assess({...v,routes:[{dst:'default',table:43000}]}).issues.existing_route_table_requires_ownership_review==1,'existing table overlap');
ok(inventory.assess({...v,nft_tables:[{family:'inet',name:'podkopchik_native'}]}).issues.existing_native_table_requires_ownership_review==1,'existing nft ownership');
let raw=' sl local_address rem_address st\n 0: 00000000:5EBD 00000000:0000 0A\n 1: 00000000:1234 00000000:0000 01\n';
ok(length(inventory.sockets(raw,true))==1&&length(inventory.sockets(raw,false))==2,'TCP listen and UDP bind parsing');
ok(inventory.sockets('unreadable',true)==null,'unreadable socket file not empty');
printf('PASS: %d manifest admission and configuration inventory assertions\n',total);
