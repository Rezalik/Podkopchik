'use strict';
// VM-only adapter stand-in. Data packets and RPDB lookups remain real;
// this never represents an AWG handshake/kernel-module acceptance result.
import * as fs from 'fs';
if(trim(fs.readfile('/sys/class/dmi/id/sys_vendor') || '')!='QEMU' && replace(fs.readfile('/proc/device-tree/model') || '','\x00','')!='linux,dummy-virt')die('VM only');
const real=require('awg_network_real');
function controller(options){
	function execute(args){if(options?.run)return options.run(args);if(args[0]=='ip'&&index(args,'-j')>=0&&index(args,'-N')<0)args=['ip','-N',...slice(args,1)];let p=fs.popen(join(' ',args),'r');if(!p)die('missing fixture command');let out=p.read('all');if(p.close()!=0)die('fixture command failed');return out;}
	function inspect(id){let r=real.resources(id),rows;
		function query(args){return json(execute(args));}
		rows=query(['ip','-j','addr','show','dev',r.interface]);
		if(query(['ip','-d','-j','link','show','dev',r.interface])[0]?.ifalias!=r.alias)die('unowned fixture');
		for(let f in ['-4','-6']){
			let rule=filter(query(['ip',f,'-j','rule','show']),v=>+v.priority==r.priority)[0];
			if(rule?.protocol!=186||+rule.table!=r.table)die('AWG executor lost numeric RPDB ownership');
			for(let route in query(['ip',f,'-j','route','show','table',r.table]))if(route.protocol!=186)die('AWG executor lost numeric route ownership');
		}
		return {running:true,guarded:true,addresses_assigned:true,addresses:join(',',map(rows[0].addr_info,a=>a.local+'/'+a.prefixlen))};}
	return {inspect_status:inspect,run:(method,id)=>{
		if(index(['start','status','check'],method)<0)die('VM adapter operation forbidden');
		let status=inspect(id);
		if(method=='start'){
			// The real guard requires oifkind amneziawg. Admit only this owned
			// Ethernet fixture to emulate that predicate; the Core's independent
			// mark/pin/interface checks are unchanged and still mandatory.
			let r=real.resources(id),rows=json(execute(['nft','-j','list','table','inet','podkopchik_fake_guard'])).nftables;
			if(length(filter(rows,v=>v.table?.comment=='podkopchik-fakedns-guard-v1'))!=1)die('unowned fixture guard');
			execute(['nft','insert','rule','inet','podkopchik_fake_guard','native_original','ct','status','dnat','oifname',r.interface,'meta','mark',r.mark,'return']);
		}
		if(method=='check')return {...status,status:fs.lstat(getenv('PODKOPCHIK_TMP_DIR')+'/probe-down-'+id)?'down':'up',latency_ms:1,external_ip:'203.0.113.200',checked_at:time()};
		return status;
	}};
}
return {...real,controller};
