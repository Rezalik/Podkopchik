'use strict';
// Frozen separately from the candidate coordinator. Only management failure
// or an explicit emergency request may restore the protected legacy capsule.
import * as fs from 'fs';
import { cursor } from 'uci';
const VM=getenv('PKC_EMERGENCY_VM_NS'), BASE=getenv('PKC_EMERGENCY_VM_ROOT');
if((VM||BASE) && (!match(VM || '',/^pkc-router-[0-9]+$/)||!match(BASE || '',/^\/tmp\/native-dns-vm\.[A-Za-z0-9]+\/emergency$/)||
	(replace(fs.readfile('/proc/device-tree/model') || '','\x00','')!='linux,dummy-virt' && trim(fs.readfile('/sys/class/dmi/id/sys_vendor') || '')!='QEMU')))die('invalid emergency VM override');
const ROOT=BASE || '/etc/podkopchik-native-emergency';
const CONF=VM?getenv('PODKOPCHIK_CONFIG_DIR'):'/etc/podkopchik';
const UCI=VM?getenv('PODKOPCHIK_UCI_CONFIG_DIR'):'/etc/config';
const TMP=VM?getenv('PODKOPCHIK_TMP_DIR'):'/tmp/podkopchik';
const LIB=getenv('PODKOPCHIK_LIB') || '/usr/libexec/podkopchik';
const OWNER='podkopchik-native-emergency-v1';
const TABLE='podkopchik_native_emergency', TEST='pkc_native_emergency_test';
const BOOT=trim(fs.readfile('/proc/sys/kernel/random/boot_id') || '');
function fail(s){die('Native emergency: '+s+'\n');}
function now(){return +split(fs.readfile('/proc/uptime'),'.')[0];}
function quote(s){return "'"+replace(''+s,"'","'\\''")+"'";}
function run(a,optional,net){if(net&&VM)a=['/sbin/ip','netns','exec',VM,...a];
	let p=fs.popen(join(' ',map(a,quote))+' 2>/dev/null','r');if(!p)fail('command unavailable');let out=p.read('all'),rc=p.close();
	if(rc!=0&&!optional)fail('command failed: '+a[0]+' '+(a[1] || ''));return rc==0?out:null;}
function dir(p){if(!fs.lstat(p))fs.mkdir(p,0o700);let s=fs.lstat(p);if(s?.type!='directory'||s.uid!=0||(s.mode&0o077))fail('unsafe capsule directory');}
function read(p,optional){let s=fs.lstat(p);if(!s&&optional)return null;
	if(s?.type!='file'||s.uid!=0||s.nlink!=1||(s.mode&0o077)||s.size>8*1024*1024)fail('unsafe capsule file');return fs.readfile(p);}
function data(p,optional){let v=read(p,optional);return v?json(v):null;}
function write(p,t){if(fs.lstat(p+'.next')){read(p+'.next');fs.unlink(p+'.next');}let f=fs.open(p+'.next','wx',0o600);if(!f||f.write(t)!=length(t)||!f.flush()||!f.close()||!fs.rename(p+'.next',p))fail('cannot persist capsule');}
function save(p,v){write(p,sprintf('%J\n',v));}
function hash(p){return split(trim(run(['sha256sum',p])),' ')[0];}
function note(s){let old=read(ROOT+'/recovery.log',true) || '';write(ROOT+'/recovery.log',substr(old,max(0,length(old)-12288))+sprintf('%d %s\n',time(),s));}
function net(a,optional){return run(a,optional,true);}
function nft(text,check){write(ROOT+'/batch.nft',text);net(['nft',...(check?['-c']:[]),'-f',ROOT+'/batch.nft']);}
function tables(){return json(net(['nft','-j','list','tables'])).nftables || [];}
function table(name){for(let v in tables())if(v.table?.family=='inet'&&v.table.name==name)return v.table;return null;}
function owned_drop(name){let t=table(name);if(!t)return '';if(t.comment!=OWNER)fail('foreign emergency table');return 'delete table inet '+name+'\n';}
function service(name){return json(run(['ubus','call','service','list',sprintf('%J',{name})]))?.[name]?.instances?.main;}
function stop(name,prefix){let s=service(name);if(!s)return;if(index(join(' ',s.command || []),prefix)<0)fail('foreign emergency service');run(['ubus','call','service','delete',sprintf('%J',{name})]);}
function spawn(name,cmd){run(['ubus','call','service','set',sprintf('%J',{name,instances:{main:{command:cmd,respawn:['3600','1','0'],limits:{nofile:'16384 16384'},stdout:true,stderr:true}}})]);}
function stop_legacy(){let all=json(run(['ubus','call','service','list','{"name":"podkopchik"}']))?.podkopchik?.instances || {};
	for(let name in ['xray','health'])if(all[name]){let cmd=all[name].command || [];
		if(name=='xray'&&(index(cmd,'run')<0||index(cmd,CONF+'/config.json')<0))fail('foreign baseline Xray');
		if(name=='health'&&index(join(' ',cmd),'health_check.sh')<0)fail('foreign baseline health');
		run(['ubus','call','service','delete',sprintf('%J',{name:'podkopchik',instance:name})]);}}
function inside(a){return VM?['/sbin/ip','netns','exec',VM,...a]:a;}
function frozen(quick){let m=data(ROOT+'/manifest.json');if(m.schema!=1||m.owner!=OWNER||!match(m.lan || '',/^[a-zA-Z0-9_.-]{1,15}$/))fail('invalid capsule');
	if(quick)return m;
	for(let n,h in m.files){if(!match(n,/^[a-zA-Z0-9_.\/-]+$/)||index(n,'..')>=0||substr(n,0,1)=='/'||!match(h,/^[a-f0-9]{64}$/))fail('invalid manifest member');read(ROOT+'/'+n);if(hash(ROOT+'/'+n)!=h)fail('capsule checksum mismatch');}
	if(hash(m.binary)!=m.binary_sha256)fail('baseline Xray binary changed');return m;}
function state(){let s=data(ROOT+'/state.json');if(s.owner!=OWNER||!match(s.token || '',/^[a-f0-9]{32}$/)||index(['armed','accepted','requested','restored','rehearsed','disarmed'],s.mode)<0)fail('invalid emergency state');return s;}
function guard(m,holding){let out=owned_drop(TABLE)+'add table inet '+TABLE+' { comment "'+OWNER+'"; }\n';
	out+='add chain inet '+TABLE+' retired { type filter hook prerouting priority -324; policy accept; }\n';
	out+='add rule inet '+TABLE+' retired ip daddr '+m.native_pool+' counter drop\n';
	out+='add rule inet '+TABLE+' retired ct direction original ct original ip daddr '+m.native_pool+' counter drop\n';
	if(holding){out+='add chain inet '+TABLE+' hold { type filter hook prerouting priority -325; policy accept; }\n';
		out+='add rule inet '+TABLE+' hold iifname "'+m.lan+'" fib daddr type { local, broadcast, multicast } return\n';
		out+='add rule inet '+TABLE+' hold iifname "'+m.lan+'" counter drop\n';}
	out+='add chain inet '+TABLE+' forward { type filter hook forward priority -205; policy accept; }\n';
	// Legacy TPROXY is local delivery. Remaining forwarded traffic is allowed
	// only to the baseline's reviewed address exceptions, never by domain guess.
	for(let hook in ['forward','output','postrouting']){
		if(hook!='forward')out+='add chain inet '+TABLE+' '+hook+' { type filter hook '+hook+' priority '+(hook=='output'?-90:305)+'; policy accept; }\n';
		for(let p in m.pools){let proto=index(p,':')<0?'ip':'ip6';out+='add rule inet '+TABLE+' '+hook+' '+proto+' daddr '+p+' counter drop\n';
			out+='add rule inet '+TABLE+' '+hook+' ct direction original ct original '+proto+' daddr '+p+' counter drop\n';}
	}
	for(let family in ['4','6']){let list=m.direct[family] || [],proto=family=='4'?'ip':'ip6';
		if(length(list))out+='add rule inet '+TABLE+' forward iifname "'+m.lan+'" '+proto+' daddr { '+join(', ',list)+' } return\n';}
	out+='add rule inet '+TABLE+' forward iifname "'+m.lan+'" counter drop\n';return out;}
function prepare(pool){
	if(fs.lstat(ROOT+'/manifest.json'))fail('capsule already prepared');
	let prefix=require('fakedns_guard').canonical(pool);if(!require('native_pool').private_v4(prefix))fail('expected admitted private pool');
	let c=cursor(UCI);c.load('podkopchik');let s=c.get_all('podkopchik','main');if(s.routing_enabled!='1')fail('working baseline is not active');
	let cfg=json(fs.readfile(CONF+'/config.json')),health=json(fs.readfile(TMP+'/state.json'));
	let tag=health.groups?.auto_proxy_group?.active_proxy;
	let check=health.proxies?.[tag];if(check?.status!='up'||check.probe_status!='up'||type(check.checked_at)!='int'||time()-check.checked_at<0||time()-check.checked_at>=300)fail('baseline primary has no fresh successful probe');
	let a=filter(cfg.outbounds,o=>o.tag==tag && o.protocol=='freedom')[0];
	if(!a?.streamSettings?.sockopt?.mark || !match(a?.streamSettings?.sockopt?.interface || '',/^paw[a-f0-9]{12}$/))fail('baseline needs a verified native AWG outbound');
	let bin=VM?getenv('PKC_EMERGENCY_VM_XRAY'):'/usr/bin/xray';
	let legacy=net(['nft','-s','list','table','inet','podkopchik']);
	if(!legacy||index(legacy,'tproxy')<0)fail('missing legacy baseline interception');
	let direct={'4':[],'6':[]};for(let row in json(net(['nft','-j','list','table','inet','podkopchik'])).nftables || [])if(row.set){
		let m=match(row.set.name,/^(proxy_bypass|reserved)(4|6)$/);if(m)for(let e in row.set.elem || []){
			let v=type(e)=='string'?e:e?.prefix?e.prefix.addr+'/'+e.prefix.len:null;
			if(!v||!require('awg').ip(split(v,'/')[0]))fail('invalid baseline address exception');require('fakedns_guard').canonical(index(v,'/')<0?v+(m[2]=='4'?'/32':'/128'):v);push(direct[m[2]],v);}}
	let pools=[prefix];for(let f in (type(cfg.fakedns)=='array'?cfg.fakedns:[cfg.fakedns]))if(f?.ipPool)push(pools,f.ipPool);
	for(let p in slice(ARGV,2)){p=require('fakedns_guard').canonical(p);if(!require('native_pool').private_v4(p))fail('historical Native pool must be an inventoried private prefix');if(index(pools,p)<0)push(pools,p);}
	for(let family in ['4','6'])direct[family]=filter(direct[family],p=>!length(filter(pools,x=>require('awg').overlap(index(p,'/')<0?p+(family=='4'?'/32':'/128'):p,x))));
	push(cfg.outbounds,{tag:'native-emergency-blocked',protocol:'blackhole'});
	push(cfg.routing.rules,{type:'field',inboundTag:['transparent'],ip:pools,outboundTag:'native-emergency-blocked'},
		{type:'field',inboundTag:['transparent'],outboundTag:tag});
	write(ROOT+'/rescue.json',sprintf('%J\n',cfg));net([bin,'run','-test','-config',ROOT+'/rescue.json']);
	write(ROOT+'/legacy.nft',legacy);write(ROOT+'/podkopchik.uci',fs.readfile(UCI+'/podkopchik'));
	write(ROOT+'/recovery.uc',fs.readfile(LIB+'/native_emergency.uc'));
	let files={};for(let n in ['rescue.json','legacy.nft','podkopchik.uci','recovery.uc'])files[n]=hash(ROOT+'/'+n);
	// Retain only the small baseline adapter code, never another 29 MiB Xray.
	dir(ROOT+'/legacy-lib');let source=getenv('PKC_EMERGENCY_BASELINE_LIB') || LIB;
	for(let n in fs.lsdir(source) || [])if(match(n,/^[a-zA-Z0-9_.-]+\.uc$/)){
		let st=fs.lstat(source+'/'+n);if(st?.type!='file'||st.uid!=0||(st.mode&0o022))fail('unsafe baseline adapter source');
		write(ROOT+'/legacy-lib/'+n,fs.readfile(source+'/'+n));files['legacy-lib/'+n]=hash(ROOT+'/legacy-lib/'+n);}
	let profiles=[];c.foreach('podkopchik','proxy',p=>{if(p.enabled!='0'&&p.protocol=='amneziawg'){if(!match(p.awg_id || '',/^[a-f0-9]{32}$/))fail('invalid baseline AWG binding');push(profiles,p.awg_id);}});
	let families=[];for(let f in ['-4','-6'])if(length(filter(json(net(['/sbin/ip','-N',f,'-j','rule','show'])),r=>+r.priority==10991)))push(families,f);
	if(!length(families))fail('missing baseline policy routing');
	let manifest={schema:1,owner:OWNER,lan:s.lan_ifname || 'br-lan',binary:bin,binary_sha256:hash(bin),files,pools,native_pool:prefix,direct,families,profiles};
	save(ROOT+'/manifest.json',manifest);nft(guard(manifest,true),true);run(['sync']);
}
function clean_native(){let out='';let epochs=[];let n=data(CONF+'/native-state/namespaces.json',true);for(let v in n || [])push(epochs,v.epoch);
	for(let t in tables())if(t.table?.family=='inet'&&index(['podkopchik_native','podkopchik_native_gate','podkopchik_native_transition'],t.table.name)>=0){
		let v=t.table;if(v.comment!='podkopchik-native-runtime-v1'&&index(map(epochs,e=>'podkopchik-native-'+e),v.comment)<0&&index(map(epochs,e=>'podkopchik-native-dns-'+e),v.comment)<0)fail('foreign native table');
		out+='delete table inet '+v.name+'\n';}
	let rows=json(net(['nft','-j','-a','list','table','inet','fw4'])).nftables || [];
	for(let v in rows)if(v.rule?.comment=='podkopchik-native-runtime-v1'){let r=v.rule;if(index(['input','forward','pkc_native_boot'],r.chain)<0)fail('foreign native firewall hook');out+='delete rule inet fw4 '+r.chain+' handle '+r.handle+'\n';}
	let boot=filter(rows,v=>v.chain?.name=='pkc_native_boot')[0]?.chain;
	if(boot){if(boot.comment!='podkopchik-native-runtime-v1')fail('foreign boot guard');out+='flush chain inet fw4 pkc_native_boot\ndelete chain inet fw4 pkc_native_boot\n';}
	if(out)nft(out);
	let registry=data(CONF+'/native-state/rpdb.json',true) || {};
	for(let k,r in registry){let f=substr(k,0,2),slot=r.table-43000;if(index(['-4','-6'],f)<0||slot<0||slot>31||r.priority!=12000+slot||r.delivery!=67109120+slot)fail('foreign routing identity');
		let rules=json(net(['/sbin/ip','-N',f,'-j','rule','show']));
		for(let v in rules)if(+v.priority==r.priority){let mark=type(v.fwmark)=='string'?hex(replace(v.fwmark,'0x','')):v.fwmark;
			if(+v.protocol!=188||+v.table!=r.table||mark!=r.delivery)fail('foreign policy rule');net(['/sbin/ip',f,'rule','del','priority',r.priority,'fwmark',r.delivery,'table',r.table,'protocol',188]);}
		let routes=filter(json(net(['/sbin/ip',f,'-j','route','show','table','all'])),v=>+v.table==r.table);
		for(let v in routes){if(+v.protocol!=188||v.type!='local'||v.dev!='lo'||v.dst!='default')fail('foreign policy route');net(['/sbin/ip',f,'route','del','local','default','dev','lo','table',r.table,'proto',188]);}}
}
function restore(){let m=frozen(),s=state(),active=data(CONF+'/native-state/runtime.json',true);
	// An expired rehearsal must not restart or alter the working household.
	let test=owned_drop(TEST);if(test)nft(test);
	if(!active?.current && s.mode!='restored'&&!table('podkopchik_native')&&!table('podkopchik_native_uninitialized')){s.mode='rehearsed';save(ROOT+'/state.json',s);note('baseline retained; independent rehearsal completed');return;}
	nft(guard(m,true));
	for(let name in ['podkopchik-native-watch','podkopchik-native-health','podkopchik-native-dns','podkopchik-native-xray'])stop(name,CONF+'/native-state/');
	stop_legacy();
	clean_native();
	let legacy=table('podkopchik'),batch='';if(legacy)batch='delete table inet podkopchik\n';batch+=read(ROOT+'/legacy.nft');nft(batch);
	let c=cursor(UCI);c.load('firewall');for(let name in ['podkopchik_native_runtime','podkopchik_native_boot']){
		let v=c.get_all('firewall',name);if(!v)continue;if(index(v.path || '',CONF+'/native-state/')!=0)fail('foreign firewall include');c.delete('firewall',name);}
	if(!c.commit('firewall'))fail('cannot remove native includes');
	let adapter=ROOT+'/legacy-lib';
	net(['env','PODKOPCHIK_TMP_DIR='+TMP,'ucode','-L',adapter,'-e',
		'let ctl=require("awg_network").controller({store:require("awg").store(ARGV[0],0)});for(let id in slice(ARGV,1))ctl.run("start",id);','--',CONF+'/awg',...m.profiles]);
	// Existing AWG policy remains owned by awg_network (proto 186). Never
	// delete or replace shared interfaces, their keys, roles or default route.
	for(let f in m.families){if(index(['-4','-6'],f)<0)fail('invalid baseline address family');let rules=json(net(['/sbin/ip','-N',f,'-j','rule','show']));let found=false;
		for(let r in rules)if(+r.priority==10991){let mark=type(r.fwmark)=='string'?hex(replace(r.fwmark,'0x','')):r.fwmark;if(+r.table!=10991||mark!=1048576)fail('foreign baseline policy');found=true;}
		if(!found)net(['/sbin/ip',f,'rule','add','fwmark','0x100000','table',10991,'priority',10991]);
		if(!length(filter(json(net(['/sbin/ip',f,'-j','route','show','table','all'])),r=>+r.table==10991)))net(['/sbin/ip',f,'route','add','local','default','dev','lo','table',10991]);}
	spawn('podkopchik-native-emergency-xray',inside([m.binary,'run','-config',ROOT+'/rescue.json']));
	let expected=map(json(read(ROOT+'/rescue.json')).inbounds,i=>+i.port),ready=false;
	for(let i=0;i<15;i++){let s=service('podkopchik-native-emergency-xray'),sockets={},ports={};
		if(s?.running)for(let fd in fs.lsdir('/proc/'+s.pid+'/fd') || []){let v=match(fs.readlink('/proc/'+s.pid+'/fd/'+fd) || '',/^socket:\[([0-9]+)\]$/);if(v)sockets[v[1]]=true;}
		for(let name in ['tcp','tcp6','udp','udp6'])for(let row in split(fs.readfile('/proc/'+s?.pid+'/net/'+name) || '','\n')){let v=split(trim(row),/[ \t]+/);if(sockets[v[9]])ports[hex(split(v[1],':')[1])]=true;}
		if(s?.running&&!length(filter(expected,p=>!ports[p]))){ready=true;break;}system(['sleep','1']);}
	if(!ready)fail('rescue Xray did not start');
	if(active){active.engine='emergency';active.phase='emergency';active.pending=null;save(CONF+'/native-state/runtime.json',active);}
	let missing=table('podkopchik_native_uninitialized');if(missing){if(missing.comment!='podkopchik-native-runtime-v1')fail('foreign missing-state guard');nft('delete table inet podkopchik_native_uninitialized\n');}
	nft(guard(m,false));s.mode='restored';s.boot=BOOT;save(ROOT+'/state.json',s);note('protected legacy runtime restored; explicit repair required');
}
function management(){let listen={};for(let f in ['tcp','tcp6'])for(let row in split(fs.readfile('/proc/net/'+f) || '','\n')){
	let v=split(trim(row),/[ \t]+/);if(v[3]=='0A')listen[hex(split(v[1],':')[1])]=true;}
	return listen[22]&&(listen[80]||listen[443]);}
dir(ROOT);
const ACTION=ARGV[0];
function locked(fn){let f=fs.open(ROOT+'/.lock','a+',0o600);if(!f||!f.lock('x'))fail('cannot lock emergency state');try{let v=fn();f.close();return v;}catch(e){f.close();die(e.message);}}
if(ACTION=='prepare')locked(()=>prepare(ARGV[1]));
else if(ACTION=='verify')printf('%J\n',locked(()=>{let m=frozen();return {verified:true,binary_sha256:m.binary_sha256,pools:m.pools};}));
else if(ACTION=='arm')locked(()=>{frozen();let seconds=+(ARGV[1] || '120');if(seconds<10||seconds>300)fail('invalid management lease');
	let token=replace(trim(fs.readfile('/proc/sys/kernel/random/uuid')),'-','');save(ROOT+'/state.json',{owner:OWNER,mode:'armed',token,boot:BOOT,deadline:now()+seconds});
	let env=VM?['/usr/bin/env','PKC_EMERGENCY_VM_NS='+VM,'PKC_EMERGENCY_VM_ROOT='+ROOT,'PODKOPCHIK_CONFIG_DIR='+CONF,'PODKOPCHIK_UCI_CONFIG_DIR='+UCI,'PODKOPCHIK_TMP_DIR='+TMP]:[];
	spawn('podkopchik-native-emergency',[...env,'ucode',ROOT+'/recovery.uc','watch']);run(['sync']);print(token+'\n');});
else if(ACTION=='heartbeat'||ACTION=='accept')locked(()=>{frozen(ACTION=='heartbeat');let s=state();if(s.token!=ARGV[1]||s.mode!='armed'||s.boot!=BOOT||now()>=s.deadline)fail('management lease expired or changed');
	if(ACTION=='accept')s.mode='accepted';else s.deadline=now()+120;save(ROOT+'/state.json',s);});
else if(ACTION=='request')locked(()=>{let s=state();s.mode='requested';save(ROOT+'/state.json',s);note('explicit emergency request');});
else if(ACTION=='disarm')locked(()=>{let c=cursor(UCI);c.load('podkopchik');let m=data(CONF+'/native-state/runtime.json',true);
	if(c.get('podkopchik','main','routing_enabled')!='0'||m?.phase!='disabled')fail('explicit Native routing disable required');
	let s=state();s.mode='disarmed';save(ROOT+'/state.json',s);
	stop('podkopchik-native-emergency-xray',ROOT+'/rescue.json');let b=owned_drop(TABLE);if(b)nft(b);
	stop('podkopchik-native-emergency',ROOT+'/recovery.uc');note('explicit routing disable; emergency monitor disarmed');});
else if(ACTION=='suspend')locked(()=>{let m=frozen();let transition=table('podkopchik_native_transition');if(transition?.comment!='podkopchik-native-runtime-v1')fail('native transition guard required');
	stop('podkopchik-native-emergency-xray',ROOT+'/rescue.json');let b=owned_drop(TABLE);if(b)nft(b);});
else if(ACTION=='status')printf('%J\n',locked(()=>{frozen(true);let s=state();return {...s,running:service('podkopchik-native-emergency')?.running || false,valid:s.mode=='accepted'||s.mode=='armed'&&s.boot==BOOT&&now()<s.deadline};}));
else if(ACTION=='resume')locked(()=>{if(state().mode=='restored')restore();});
else if(ACTION=='watch'){
	let bad=0;for(;;){try{locked(()=>{let s=state();
		if(s.mode=='requested'||s.mode=='armed'&&(s.boot!=BOOT||now()>=s.deadline))restore();
		else if(s.mode=='accepted'){if(management())bad=0;else bad++;if(bad>=30){s.mode='requested';save(ROOT+'/state.json',s);note('local management listeners lost');restore();}}
		else if(s.mode=='restored'&&s.boot!=BOOT)restore();
	});}catch(e){try{note('recovery pending; guard retained');}catch(log_error){}}system(['sleep','2']);}
}
else fail('unknown emergency action');
