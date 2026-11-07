'use strict';
// Read-only inventory, including configured remote VPN prefixes. Never print
// profiles, endpoint credentials or the underlying household inventory.
import * as fs from 'fs';
import { cursor } from 'uci';
const lib=require('native_pool'),awg=require('awg');
function query(a){let p=fs.popen(join(' ',a),'r');if(!p)die('inventory command unavailable');let out=p.read('all');if(p.close()!=0)die('incomplete live inventory');return json(out);}
let addresses=query(['/sbin/ip','-j','addr','show']),routes=[],rules=[],endpoints=[],exclusions=[];
for(let f in ['-4','-6']){routes=[...routes,...query(['/sbin/ip','-N',f,'-j','route','show','table','all'])];rules=[...rules,...query(['/sbin/ip','-N',f,'-j','rule','show'])];}
let c=cursor();c.load('podkopchik');let db=awg.store('/etc/podkopchik/awg',0);
c.foreach('podkopchik','proxy',p=>{if(p.enabled=='0')return;if(p.protocol!='amneziawg')die('review VLESS endpoint inventory before admission');
	let conf=db.run('profile',{id:p.awg_id}).parsed;
	for(let raw in split(conf.interface.Address || '',','))if(trim(raw))push(routes,{dst:trim(raw)});
	for(let peer in conf.peers || [])for(let raw in split(peer.AllowedIPs || '',','))if(index(['0.0.0.0/0','::/0'],trim(raw))<0)push(routes,{dst:trim(raw)});
	for(let ep in conf.endpoints || []){let host=substr(ep,0,1)=='['?substr(ep,1,index(ep,']')-1):substr(ep,0,rindex(ep,':'));if(!awg.ip(host))die('resolve and inventory named endpoint first');push(endpoints,host);}
});
for(let v in query(['nft','-j','list','table','inet','podkopchik']).nftables || [])if(v.set&&index(['proxy_bypass4','proxy_bypass6'],v.set.name)>=0)
	for(let e in v.set.elem || []){if(type(e)=='string')push(exclusions,e);else if(e.prefix)push(exclusions,e.prefix.addr+'/'+e.prefix.len);else die('unsupported exclusion inventory');}
let issued=['198.18.0.0/15','172.31.253.0/24'];
let saved=fs.readfile('/etc/podkopchik-fakedns-guard.json');if(saved)issued=[...issued,...json(saved).pools];
const candidate=ARGV[0] || '172.30.0.0/16';
let result=lib.select([candidate],{addresses,routes,rules,endpoints,exclusions,issued},{'4':8192},candidate);
printf('%J\n',{selected:result,links:length(addresses),routes:length(routes),policy_rules:length(rules),known_issued:issued,remote_vpn_inventory:true});
