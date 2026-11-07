'use strict';
import * as fs from 'fs';
import { cursor } from 'uci';
const LIB=getenv('PODKOPCHIK_LIB') || '/usr/libexec/podkopchik';
const CONF=getenv('PODKOPCHIK_CONFIG_DIR') || '/etc/podkopchik';
const TMP=getenv('PODKOPCHIK_TMP_DIR') || '/tmp/podkopchik';
const UCI_DIR=getenv('PODKOPCHIK_UCI_CONFIG_DIR') || '/etc/config';
const DNS=getenv('PODKOPCHIK_NATIVE_DNS') || LIB+'/podkopchik-native-dns';
const NS=getenv('PKC_NATIVE_VM_NS');
const ROOT=CONF+'/native-state', META=ROOT+'/runtime.json', OWNER='podkopchik-native-runtime-v1';
const RUNTIME=TMP+'/native-runtime-plan.json';
const DNS_STATE=TMP+'/native-dns-upstream.json';
const EMERGENCY=(getenv('PKC_EMERGENCY_VM_ROOT') || '/etc/podkopchik-native-emergency')+'/recovery.uc';
let selection_at=0;
let candidate_path=null;
let operation_deadline=0;
const planner=require('universal_plan'), guard=require('fakedns_guard'), awg=require('awg'), network=require('awg_network');
const boot=trim(fs.readfile('/proc/sys/kernel/random/boot_id') || '');
function fail(s){die('Native Apply: '+s+'\n');}
function quote(s){return "'"+replace(''+s,"'","'\\''")+"'";}
function uptime(){let v=split(fs.readfile('/proc/uptime') || '','.')[0];if(!match(v,/^[0-9]+$/))fail('missing monotonic clock');return +v;}
function helper_available(){
	let s=fs.lstat(DNS);if(!s||s.type!='file'||s.uid!=0||(s.mode&0o022)||!(s.mode&0o111))return false;
	let p=fs.popen(quote(DNS)+' -capabilities 2>/dev/null','r');if(!p)return false;let text=p.read('all'),rc=p.close();
	try{let c=json(text);return rc==0&&c.schema==3&&c.persistent_dns&&c.bounded_commands&&c.protected_dns;}catch(e){return false;}
}
function run(args,env,optional){
	// BusyBox env may prefer its own ip applet over the ip-full alternative.
	if(args[0]=='ip')args=['/sbin/ip',...slice(args,1)];
	let a=[];if(env){a=['env'];for(let k,v in env)push(a,k+'='+v);}a=[...a,...args];
	let timeout=operation_deadline?min(30,operation_deadline-uptime()):30;
	if(timeout<1)fail('native activation deadline expired');
	a=[DNS,'-run-timeout',''+timeout,'--',...a];
	fs.writefile(TMP+'/native-last-command.json',sprintf('%J\n',a));
	let p=fs.popen(join(' ',map(a,quote))+' 2>'+quote(TMP+'/native-command.err'),'r');
	if(!p)fail('command unavailable');let out=p.read('all'),rc=p.close();
	if(rc!=0 && !optional)fail('command failed: '+args[0]+' '+(args[1] || ''));
	return rc==0?out:null;
}
function net(args,env,optional){
	// Custom AWG executors must retain awg_network's numeric ownership view.
	if(args[0]=='ip'&&index(args,'-j')>=0&&index(args,'-N')<0)args=['ip','-N',...slice(args,1)];
	return run(NS?['ip','netns','exec',NS,...args]:args,env,optional);
}
function jrun(args){if(args[0]=='ip'&&index(args,'-N')<0)args=['ip','-N',...slice(args,1)];return json(net(args));}
function emergency_env(){let e={};if(NS){e={PKC_EMERGENCY_VM_NS:NS,PKC_EMERGENCY_VM_ROOT:getenv('PKC_EMERGENCY_VM_ROOT'),PODKOPCHIK_CONFIG_DIR:CONF,PODKOPCHIK_UCI_CONFIG_DIR:UCI_DIR,PODKOPCHIK_TMP_DIR:TMP};}return e;}
function emergency(action,token){return run(['ucode',EMERGENCY,action,...(token?[token]:[])],emergency_env());}
function private_dir(path){
	let s=fs.lstat(path);if(!s){if(!fs.mkdir(path,0o700))fail('cannot create private state');s=fs.lstat(path);}
	if(s.type!='directory'||s.uid!=0||(s.mode&0o077))fail('unsafe state directory');
}
function read(path,optional){let s=fs.lstat(path);if(!s&&optional)return null;
	if(!s||s.type!='file'||s.uid!=0||s.nlink!=1||(s.mode&0o077)||s.size>8*1024*1024)fail('unsafe state file: '+path);return fs.readfile(path);}
function data(path,optional){let text=read(path,optional);return text?json(text):null;}
function atomic(path,text){
	if(fs.lstat(path+'.new')){read(path+'.new');fs.unlink(path+'.new');}
	let f=fs.open(path+'.new','wx',0o600);if(!f||f.write(text)!=length(text)||!f.flush()||!f.close()||!fs.rename(path+'.new',path))fail('cannot persist state');
	if(system(['sync'])!=0)fail('cannot sync state');
}
function save(path,v){atomic(path,sprintf('%J\n',v));}
function meta(){return data(META,true) || {schema:1,engine:'legacy',confirmed:null,current:null,pending:null};}
function generation(id){if(!match(id || '',/^[a-f0-9]{32}$/))fail('invalid generation');return ROOT+'/g-'+id;}
function nonce(){return awg.nonce();}
function ctx(dir){let c=cursor(dir || UCI_DIR);c.load('podkopchik');return c;}
function settings(dir){return ctx(dir).get_all('podkopchik','main') || {};}
function files(path){return fs.lsdir(path) || [];}
function copy(src,dst){atomic(dst,read(src));}
function copy_code(src,dst){let s=fs.lstat(src);if(!s || s.type!='file'||s.uid!=0||(s.mode&0o022)||s.nlink!=1||s.size>8*1024*1024)fail('unsafe recovery source');atomic(dst,fs.readfile(src));}
function journal(action,g,seconds){return trim(run(['ucode',LIB+'/trial-state.uc',action,g,seconds==null?'':''+seconds]));}
function nft(text,check){let path=TMP+'/native-batch.nft';atomic(path,text);net(['nft',...(check?['-c']:[]),'-f',path]);}
function service(name){return json(run(['ubus','call','service','list',sprintf('%J',{name})]));}
function instance(name){return service(name)?.[name]?.instances?.main;}
function stop(name,identity){let s=instance(name);if(!s)return;
	let cmd=join(' ',s.command || []);
	if(index(cmd,ROOT+'/')<0 && index(cmd,LIB+'/')<0)fail('foreign procd instance');
	if(identity && index(s.command || [],identity)<0)fail('foreign procd instance');
	run(['ubus','call','service','delete',sprintf('%J',{name})]);}
function spawn(name,command){let old=instance(name);if(old){
		if(sprintf('%J',old.command)==sprintf('%J',command)&&old.running)return;
		if(name!='podkopchik-native-watch')stop(name,command[0]);
		else if(index(join(' ',old.command || []),ROOT+'/')<0)fail('foreign native supervisor');}
	// Match procd.sh: legacy respawn is an array of decimal strings, not ints.
	run(['ubus','call','service','set',sprintf('%J',{name,instances:{main:{command,respawn:['3600','1','0'],limits:{nofile:name=='podkopchik-native-xray'?'16384 16384':'4096 4096'},stdout:true,stderr:true}}})]);}
function exists_table(name){for(let v in jrun(['nft','-j','list','tables']).nftables || [])if(v.table?.family=='inet'&&v.table.name==name)return v.table;return null;}
function owned_tables(p){let lines=[];for(let item in [['podkopchik_native','podkopchik-native-'],['podkopchik_native_gate','podkopchik-native-dns-']]){
	let t=exists_table(item[0]);if(t){let epochs=map(data(ROOT+'/namespaces.json',true) || [],n=>n.epoch);push(epochs,p.epoch);
		if(index(map(epochs,x=>item[1]+x),t.comment)<0)fail('foreign native table');push(lines,'delete table inet '+item[0]);}}
	return lines;
}
function fw4_delete(){let out=[];
	let text=net(['nft','-j','-a','list','table','inet','fw4'],null,true);if(!text)return out;
	for(let v in json(text).nftables || [])if(v.rule?.comment==OWNER){let r=v.rule;
		if(index(['input','forward'],r.chain)<0||type(r.handle)!='int')fail('foreign firewall marker');
		push(out,'delete rule inet fw4 '+r.chain+' handle '+r.handle);}
	return out;
}
function has_flowtable(){for(let row in jrun(['nft','-j','list','ruleset']).nftables || [])if(row.flowtable)return true;return false;}
function transition(lan,on){
	let t=exists_table('podkopchik_native_transition'),lines=[];
	if(t){if(t.comment!=OWNER)fail('foreign transition guard');push(lines,'delete table inet podkopchik_native_transition');}
	if(on){
		push(lines,'add table inet podkopchik_native_transition { comment "'+OWNER+'"; }');
		push(lines,'add chain inet podkopchik_native_transition pre { type filter hook prerouting priority -321; policy accept; }');
		for(let name in lan){if(!match(name,/^[A-Za-z0-9_.-]{1,15}$/))fail('invalid guarded LAN');
			push(lines,'add rule inet podkopchik_native_transition pre iifname "'+name+'" meta l4proto { tcp, udp } th dport 53 counter drop');
			push(lines,'add rule inet podkopchik_native_transition pre iifname "'+name+'" fib daddr type { local, broadcast, multicast } return');
			push(lines,'add rule inet podkopchik_native_transition pre iifname "'+name+'" counter drop');}
	}
	if(length(lines))nft(join('\n',lines)+'\n');
}
function clear_missing_guard(){let t=exists_table('podkopchik_native_uninitialized');if(!t)return;
	if(t.comment!=OWNER)fail('foreign missing-state guard');nft('delete table inet podkopchik_native_uninitialized\n');}
function env_for(g){return {PODKOPCHIK_LIB:LIB,PODKOPCHIK_UCI_CONFIG_DIR:g+'/uci',PODKOPCHIK_AWG_ROOT:g+'/awg',PODKOPCHIK_TMP_DIR:TMP};}
function state_env(){let e={PODKOPCHIK_LIB:LIB,PODKOPCHIK_TMP_DIR:TMP,PODKOPCHIK_UCI_CONFIG_DIR:UCI_DIR,PODKOPCHIK_NATIVE_DNS:DNS};if(getenv('PODKOPCHIK_CONFIG_DIR'))e.PODKOPCHIK_CONFIG_DIR=CONF;if(getenv('PODKOPCHIK_CORE_DIR'))e.PODKOPCHIK_CORE_DIR=getenv('PODKOPCHIK_CORE_DIR');if(NS){e.PKC_NATIVE_VM_NS=NS;if(getenv('PKC_EMERGENCY_VM_ROOT'))e.PKC_EMERGENCY_VM_ROOT=getenv('PKC_EMERGENCY_VM_ROOT');if(getenv('CURL_CA_BUNDLE'))e.CURL_CA_BUNDLE=getenv('CURL_CA_BUNDLE');if(getenv('SSL_CERT_FILE'))e.SSL_CERT_FILE=getenv('SSL_CERT_FILE');}return e;}
function command(args,env,inside){let out=['/usr/bin/env'];for(let k,v in env)push(out,k+'='+v);return [...out,...(inside&&NS?['/sbin/ip','netns','exec',NS]:[]),...args];}
function digest(path){return split(trim(run(['sha256sum',path])),' ')[0];}
function freeze(){
	let names=filter(files(LIB),n=>match(n,/^[a-zA-Z0-9_.-]+\.(uc|sh)$/));sort(names);
	let ctl=getenv('PODKOPCHIK_CTL') || '/usr/bin/podkopchikctl';
	let sums=[];for(let n in names)push(sums,digest(LIB+'/'+n)+' '+n);push(sums,digest(DNS)+' dns',digest(ctl)+' ctl');
	atomic(TMP+'/native-code-id',join('\n',sums)+'\n');let id=digest(TMP+'/native-code-id'),path=ROOT+'/code-'+id;
	if(!fs.lstat(path)){
		private_dir(path);for(let n in names)copy_code(LIB+'/'+n,path+'/'+n);
		copy_code(DNS,path+'/podkopchik-native-dns');fs.chmod(path+'/podkopchik-native-dns',0o700);
		copy_code(getenv('PODKOPCHIK_CTL') || '/usr/bin/podkopchikctl',path+'/podkopchikctl');fs.chmod(path+'/podkopchikctl',0o700);
	}
	for(let n in names)if(digest(path+'/'+n)!=digest(LIB+'/'+n))fail('recovery source checksum mismatch');
	if(digest(path+'/podkopchik-native-dns')!=digest(DNS))fail('recovery DNS checksum mismatch');
	if(digest(path+'/podkopchikctl')!=digest(ctl))fail('recovery controller checksum mismatch');
	return path;
}
function watch_service(){let m=meta(),path=m.code || LIB,e=state_env();e.PODKOPCHIK_LIB=path;e.PODKOPCHIK_NATIVE_DNS=path+'/podkopchik-native-dns';e.PODKOPCHIK_CTL=path+'/podkopchikctl';
	spawn('podkopchik-native-watch',command(['/bin/sh',path+'/native_runtime.sh','watch'],e));}
function read_state(){return data(TMP+'/state.json',true) || {};}
function compile(g,statefile){let out=net(['ucode','-L',LIB,LIB+'/generate.uc','native',g+'/spec.json',statefile || TMP+'/state.json'],env_for(g));
	let p=json(out);if(p.mode!='native'||!p.compiled||!p.dns.persistent)fail('not a permanent native candidate');return p;}
function manifest(g){let names=['spec.json','plan.json','dns.json','xray.json'];if(fs.lstat(g+'/code.json'))push(names,'code.json');for(let n in files(g+'/uci'))push(names,'uci/'+n);for(let n in files(g+'/awg'))push(names,'awg/'+n);
	let lines=[];for(let n in names)push(lines,digest(g+'/'+n)+'  '+n);atomic(g+'/files.sha256',join('\n',lines)+'\n');}
function verify(g){let sums=read(g+'/files.sha256');for(let line in split(trim(sums),'\n')){
		let m=match(line,/^([a-f0-9]{64})  ([a-zA-Z0-9_.\/-]+)$/);if(!m||index(m[2],'..')>=0||substr(m[2],0,1)=='/'||digest(g+'/'+m[2])!=m[1])fail('generation checksum mismatch');}}
function snapshot_profiles(g){private_dir(g+'/awg');
	for(let n in files(CONF+'/awg'))if(match(n,/^[a-f0-9]{32}(\.[a-f0-9]{32}\.conf|\.json)$/))copy(CONF+'/awg/'+n,g+'/awg/'+n);
}
function resolve(host){if(awg.ip(host))return [host];if(index(host,'/')>=0)return [host];if(!awg.domain(host))fail('invalid endpoint/bypass host');
	// Root-only endpoint/explicit-Direct bootstrap. Pinned HTTPS uses neither
	// ISP DNS, the LAN classifier nor a tunnel that has yet to be created.
	let ips=[];for(let kind in ['A','AAAA'])for(let ip in ['1.1.1.1','1.0.0.1']){
		let out=net(['curl','--noproxy','*','--proto','=https','--fail','--silent','--show-error','--connect-timeout','2','--max-time','3',
			'--resolve','cloudflare-dns.com:443:'+ip,'--header','accept: application/dns-json','https://cloudflare-dns.com/dns-query?name='+host+'&type='+kind],null,true);
		if(!out)continue;let value;try{value=json(out);}catch(e){continue;}
		if(value.Status!=0)continue;for(let r in value.Answer || [])if(r.type==(kind=='A'?1:28)&&awg.ip(r.data)&&index(ips,r.data)<0)push(ips,r.data);break;
	}return ips;}
function inventory(g,pool,oldspec){
	let c=ctx(g+'/uci'),s=settings(g+'/uci'),addresses=jrun(['ip','-j','addr','show']),routes=[],rules=[],bypass=[],profiles=[],pins=oldspec?.pins || {},slots=oldspec?.vless_slots || {};
	for(let family in ['-4','-6']){routes=[...routes,...jrun(['ip',family,'-j','route','show','table','all'])];rules=[...rules,...jrun(['ip','-N',family,'-j','rule','show'])];}
	let registered=data(getenv('PODKOPCHIK_CONFIG_DIR')?CONF+'/fakedns-guard.json':'/etc/podkopchik-fakedns-guard.json',true) || {};
	let retired=filter(registered.pools || [],x=>index(pool.pools,x)<0);
	let oldconfig=data(CONF+'/config.json',true);for(let f in (type(oldconfig?.fakedns)=='array'?oldconfig.fakedns:[oldconfig?.fakedns]))if(f?.ipPool&&index(retired,f.ipPool)<0)push(retired,f.ipPool);
	for(let p in pool.pools)retired=filter(retired,x=>x!=p);
	let endpoint_pins={};
	function endpoint(host){if(!endpoint_pins[host])endpoint_pins[host]=resolve(host);
		if(!length(endpoint_pins[host]))fail('protected endpoint bootstrap failed: '+host);
		for(let ip in endpoint_pins[host])if(index(bypass,ip)<0)push(bypass,ip);}
	c.foreach('podkopchik','proxy',p=>{if(p.enabled=='0')return;
		let tag=require('vless').clean_tag(p.tag || p.name,'proxy');
		if(!pins[tag]){let value=1;while(value==127||index(values(pins),value*16777216)>=0)value++;if(value>254)fail('native pin registry exhausted');pins[tag]=value*16777216;}
		if((p.protocol || 'vless')=='amneziawg'){
			let profile=awg.store(g+'/awg',0).run('profile',{id:p.awg_id});
			for(let address in split(profile.parsed.interface.Address || '',','))if(trim(address))push(routes,{dst:trim(address),protocol:'vpn-inventory'});
			for(let peer in profile.parsed.peers || [])for(let prefix in split(peer.AllowedIPs || '',','))if(index(['0.0.0.0/0','::/0'],trim(prefix))<0)push(routes,{dst:trim(prefix),protocol:'vpn-inventory'});
			for(let ep in profile.parsed.endpoints || [])endpoint(substr(ep,0,1)=='['?substr(ep,1,index(ep,']')-1):substr(ep,0,rindex(ep,':')));
			push(profiles,p.awg_id);
		}else{let parsed=require('vless').parse(p.uri || '');endpoint(parsed.address);
			if(slots[tag]==null){let slot=0;while(index(values(slots),slot)>=0)slot++;if(slot>31)fail('native VLESS slot registry exhausted');slots[tag]=slot;}}
	});
	if(!length(keys(pins)))fail('no enabled transport');
	c.foreach('podkopchik','bypass_rule',r=>{if(r.enabled!='0')endpoint(trim(lc(r.host || '')));});
	let a4=null,a6=null;for(let l in addresses)if(l.ifname==s.lan_ifname || l.ifname=='br-lan'&&!s.lan_ifname)
		for(let a in l.addr_info || [])if(a.scope!='link'){if(a.family=='inet'&&!a4)a4=a.local;if(a.family=='inet6'&&!a6)a6=a.local;}
	if(!a4&&!a6)fail('LAN has no usable address');
	let activeOwned=(registered.native_pools || []);
	let filtered=filter(rules,r=>{
		if(+r.priority!=10992 || +r.protocol!=187 || (r.action!='blackhole'&&+r.action!=6) || r.src&&r.src!='all' || !r.dst)return true;
		for(let key in keys(r))if(index(['priority','src','dst','dstlen','action','protocol'],key)<0)return true;
		let prefix=guard.canonical(r.dst+(index(r.dst,'/')>=0?'':'/'+(r.dstlen || (index(r.dst,':')>=0?128:32))));
		return index(activeOwned,prefix)<0 || index(pool.pools,prefix)<0;
	});
	let inv={addresses,routes,rules:filtered,issued:retired,endpoints:bypass,exclusions:bypass};
	require('native_pool').inventory(inv,true);
	let endpoints=s.native_dns_tls || ['1.1.1.1:853@one.one.one.one','9.9.9.9:853@dns.quad9.net','[2606:4700:4700::1111]:853@one.one.one.one','[2620:fe::fe]:853@dns.quad9.net'];
	if(type(endpoints)=='string')endpoints=[endpoints];if(!length(endpoints)||length(endpoints)>8)fail('invalid protected DNS endpoint count');
	let tls_endpoints=[];for(let e in endpoints){let parts=split(e,'@');if(length(parts)!=2||!awg.domain(parts[1]))fail('invalid protected DNS TLS name');
		let hp=match(parts[0],/^\[([0-9a-fA-F:]+)\]:([0-9]+)$/)||match(parts[0],/^([0-9.]+):([0-9]+)$/);
		if(!hp||!awg.ip(hp[1])||+hp[2]<1||+hp[2]>65535)fail('protected DNS requires pinned numeric endpoints');
		let host_prefix=hp[1]+(index(hp[1],':')<0?'/32':'/128');
		for(let prefix in [...pool.pools,...retired])if(awg.overlap(host_prefix,prefix))fail('protected DNS endpoint overlaps a synthetic pool');
		push(tls_endpoints,{address:parts[0],name:parts[1]});}
	return {lan:s.lan_ifname || 'br-lan',legacy_lans:[],upstream:'127.0.0.1:53',protected_dns_state:DNS_STATE,dns_tls_endpoints:tls_endpoints,endpoint_pins,bypass,retired_pools:retired,pins,vless_slots:slots,profiles,
		synthetic:{epoch:pool.epoch,pools:pool.pools,private_pool:pool.private_pool,dns:{port: +(s.native_dns_port || '24253'),ipv4:a4,ipv6:a6},inventory:inv}};
}
function fw4_rules(p){let lines=[],lan='iifname "'+p.lan+'" ',terminal=null;
	let rules=[];for(let row in jrun(['nft','-j','-a','list','chain','inet','fw4','forward']).nftables || [])if(row.rule&&row.rule.comment!=OWNER)push(rules,row.rule);
	let last=rules[length(rules)-1];
	if(length(last?.expr || [])==1 && last.expr[0]?.jump?.target=='handle_reject')terminal=last.handle;
	for(let fam,addr in p.compiled.synthetic.dns.endpoints){let proto=fam=='4'?'ip':'ip6';
		push(lines,'insert rule inet fw4 input '+lan+proto+' daddr '+addr+' meta l4proto { tcp, udp } th dport '+p.compiled.synthetic.dns.port+' ct status dnat ct original proto-dst 53 accept comment "'+OWNER+'"');}
	for(let a in p.adapters)if(a.type=='vless')push(lines,'insert rule inet fw4 input '+lan+'meta mark '+a.delivery+' ct mark & 0xff000000 '+a.pin+' meta l4proto tcp accept comment "'+OWNER+'"');
	for(let a in p.adapters)if(a.type=='amneziawg')push(lines,(terminal==null?'add rule inet fw4 forward ':'insert rule inet fw4 forward position '+terminal+' ')+lan+'oifname "'+a.interface+'" meta mark '+a.mark+' ct state { new, established, related } accept comment "'+OWNER+'"');
	return lines;
}
function readmit(g){
	let saved=data(g+'/spec.json'),s=saved.synthetic,pool={pools:s.pools,epoch:s.epoch,private_pool:s.private_pool};
	let live=inventory(g,pool,saved),required={};for(let p in s.pools)required[index(p,':')<0?'4':'6']=1;
	require('native_pool').select(s.pools,live.synthetic.inventory,required,s.private_pool);
	if(live.lan!=saved.lan||sprintf('%J',live.synthetic.dns)!=sprintf('%J',s.dns))fail('LAN addresses changed; guarded re-admission and a new Apply are required');
}
function preflight(g,p){
	verify(g);
	if(p.classification.unknown!='direct')ctx(g+'/uci').foreach('podkopchik','domain_rule',r=>{
		if(r.enabled!='0'&&(!r.target||r.target=='direct'))fail('Strict domain-only Direct rules cannot authorize shared IPs; use a reviewed explicit address/client exclusion or Compatible mode');
	});
	let installed=meta();if(installed.current&&data(generation(installed.current)+'/plan.json').lan!=p.lan)fail('changing the installed LAN requires an explicit disable and separate network re-admission');
	if(index(net(['ip','-V']),'iproute2')<0)fail('ip-full is required');
	let fw=cursor(UCI_DIR);fw.load('firewall');fw.foreach('firewall','defaults',s=>{if(s.flow_offloading=='1'||s.flow_offloading_hw=='1')fail('flow offloading must be disabled');});
	if(has_flowtable())fail('live flowtable prevents native Apply');
	if(p.requires_xray){let x=trim(run(['sh','-c','. "$1/xray.sh"; xray_bin','xray',LIB]));if(!x)fail('Xray required for VLESS');net([x,'run','-test','-config',g+'/xray.json']);}
	for(let pool in p.dns.pools)net(['sh',LIB+'/fakedns_guard.sh','check-native',pool],{...state_env(),PODKOPCHIK_UCI_CONFIG_DIR:g+'/uci'});
	if(!p.dns.protected_upstream)fail('unprotected Native DNS upstream refused');
	let prior=meta(),lines=[];if(prior.current)lines=owned_tables(data(generation(prior.current)+'/plan.json'));
	else if(exists_table('podkopchik_native')||exists_table('podkopchik_native_gate'))fail('unowned native tables');
	let legacy=exists_table('podkopchik');if(legacy){if(trim(read(TMP+'/routing.env',true) || '')!='podkopchik-routing-v1')fail('unowned legacy table');push(lines,'delete table inet podkopchik');}
	lines=[...lines,...fw4_delete(),p.nft.routing,p.nft.protection,p.nft.dns_redirect,...fw4_rules(p)];
	atomic(g+'/activate.nft',join('\n',lines)+'\n');nft(read(g+'/activate.nft'),true);
	let space=net(['df','-Pk','/overlay'],null,true) || net(['df','-Pk',CONF]);let rows=split(trim(space),'\n'),cols=split(replace(rows[length(rows)-1],/[ \t]+/g,' '),' ');
	let codebytes=fs.stat(DNS).size+fs.stat(getenv('PODKOPCHIK_CTL') || '/usr/bin/podkopchikctl').size+524288;
	for(let n in files(LIB))if(match(n,/\.(uc|sh)$/))codebytes+=fs.stat(LIB+'/'+n).size+4096;
	let snapshot=16384;for(let sub in ['uci','awg'])for(let n in files(g+'/'+sub))snapshot+=(int(fs.stat(g+'/'+sub+'/'+n).size/4096)+1)*4096;
	for(let n in files(g))if(fs.stat(g+'/'+n).type=='file')snapshot+=(int(fs.stat(g+'/'+n).size/4096)+1)*4096;
	if(!meta().current && fs.stat(CONF+'/config.json'))snapshot+=fs.stat(CONF+'/config.json').size;
	let required=12288+int((codebytes+snapshot+1023)/1024);
	if(+(cols[3] || 0)<required)fail('insufficient flash for the measured recovery snapshot, 4 MiB DNS journal and 8 MiB safety reserve');
	let tmp_rows=split(trim(net(['df','-Pk',TMP])),'\n'),tmp_cols=split(replace(tmp_rows[length(tmp_rows)-1],/[ \t]+/g,' '),' ');
	let ram=match(fs.readfile('/proc/meminfo') || '',/MemAvailable:[ \t]+([0-9]+)/);
	if(+tmp_cols[3]<49152 || !ram || +ram[1]<98304)fail('Native Apply requires 48 MiB free tmpfs and 96 MiB available RAM');
	return {flash_required_kib:required,flash_free_kib:+cols[3],snapshot_kib:int((snapshot+1023)/1024),coordinator_kib:int((codebytes+1023)/1024),tmp_free_kib:+tmp_cols[3],ram_available_kib:+ram[1]};
}
function includes(p,on){
	let c=cursor(UCI_DIR);c.load('firewall');
	let names={podkopchik_native_runtime:['script',null,'fw4-reconcile.sh'],podkopchik_native_boot:['table-pre',null,'fw4-boot.nft']};
	for(let name,v in names){let current=c.get_all('firewall',name),path=ROOT+'/'+v[2];
		if(current && current.path!=path)fail('foreign firewall include');
		if(!on){if(current)c.delete('firewall',name);continue;}
		if(!current)c.set('firewall',name,'include');
		for(let k,val in {type:v[0]=='script'?'script':'nftables',path,enabled:'1'})c.set('firewall',name,k,val);
		if(v[0]=='script')c.set('firewall',name,'fw4_compatible','1');else c.set('firewall',name,'position',v[0]);
	}
	if(on){
		atomic(ROOT+'/fw4-reconcile.sh','#!/bin/sh\nset -eu\numask 077\nexec '+join(' ',map(command(['/bin/sh',LIB+'/native_runtime.sh','firewall'],state_env()),quote))+'\n');
		fs.chmod(ROOT+'/fw4-reconcile.sh',0o700);
		atomic(ROOT+'/fw4-boot.nft','chain pkc_native_boot { type filter hook prerouting priority -320; policy accept; comment "'+OWNER+'"; iifname "'+p.lan+'" meta l4proto { tcp, udp } th dport 53 counter drop; iifname "'+p.lan+'" fib daddr type { local, broadcast, multicast } return; iifname "'+p.lan+'" counter drop; }\n');
	}
	if(!c.commit('firewall'))fail('cannot persist owned firewall includes');
}
function reconcile_fw4(p){nft(join('\n',[...fw4_delete(),...fw4_rules(p)])+'\n');}
function clear_boot_guard(){let text=net(['nft','-j','list','chain','inet','fw4','pkc_native_boot'],null,true);if(!text)return;
	let rows=filter(json(text).nftables || [],r=>r.chain);if(rows[0]?.chain?.comment!=OWNER)fail('foreign boot guard');
	if(length(filter(json(text).nftables || [],r=>r.rule)))nft('flush chain inet fw4 pkc_native_boot\n');
}
function owned_vless_route(r){return +r.protocol==188&&r.dev=='lo'&&index(['local','2'],''+r.type)>=0&&index(['default','0.0.0.0/0','::/0'],r.dst)>=0;}
function policy_routes(p,remove,check){
	let registry=data(ROOT+'/rpdb.json',true) || {};
	for(let a in p.adapters)if(a.type=='vless')for(let f in ['-4','-6']){
		let key=f+':'+a.table,identity={table:a.table,priority:a.priority,delivery:a.delivery};
		let rows=jrun(['ip','-N',f,'-j','rule','show']),found=false;
		for(let r in rows){let mark=type(r.fwmark)=='string'?hex(replace(r.fwmark,'0x','')):r.fwmark;
			let mask=r.fwmask==null?4294967295:(type(r.fwmask)=='string'?hex(replace(r.fwmask,'0x','')):r.fwmask);
			if(+r.priority==a.priority || mark!=null && (mark&mask)==(a.delivery&mask)){
				if(+r.priority!=a.priority||+r.table!=a.table||+r.protocol!=188||mark!=a.delivery||mask!=4294967295||(r.src&&r.src!='all')||r.oif||r.iif)fail('foreign VLESS policy rule');found=true;}}
		let routes=filter(jrun(['ip',f,'-j','route','show','table','all']),r=>+r.table==a.table);
		// ip -N also renders RTN_LOCAL as numeric type 2, not "local".
		for(let r in routes)if(!owned_vless_route(r))fail('foreign VLESS route table');
		if((found||length(routes))&&sprintf('%J',registry[key])!=sprintf('%J',identity))fail('VLESS RPDB resource has no matching ownership journal');
		if(check)continue;
		if(remove){if(found)net(['ip',f,'rule','del','priority',a.priority,'fwmark',a.delivery,'table',a.table,'protocol',188]);
			if(length(routes))net(['ip',f,'route','del','local','default','dev','lo','table',a.table,'proto',188]);
		}else{if(!registry[key]){registry[key]=identity;save(ROOT+'/rpdb.json',registry);}
			if(!found)net(['ip',f,'rule','add','priority',a.priority,'fwmark',a.delivery,'table',a.table,'protocol',188]);
			if(!length(routes))net(['ip',f,'route','add','local','default','dev','lo','table',a.table,'proto',188]);}
	}
}
function release_policy_routes(){let adapters={};for(let key,r in (data(ROOT+'/rpdb.json',true) || {})){
	let slot=+r.table-43000;if(type(r.table)!='int'||slot<0||slot>31||r.priority!=12000+slot||r.delivery!=67109120+slot||index(['-4:'+r.table,'-6:'+r.table],key)<0)fail('invalid VLESS RPDB journal');
	adapters[r.table]={...r,type:'vless'};
}
	policy_routes({adapters:values(adapters)},true);
}
function start_transports(g){let spec=data(g+'/spec.json'),store=awg.store(g+'/awg',0);let ctl=network.controller({root:TMP+'/awg',store,endpoint_ips:spec.endpoint_pins,run:a=>net(a)});
	for(let id in spec.profiles){
		// A health probe owns the same mutation lock. An already attested
		// interface needs no start operation, and must not contend with it.
		let live=ctl.inspect_status(id),profile=store.run('profile',{id});
		if(live.running&&live.guarded&&live.addresses_assigned&&live.revision==profile.meta.revision)continue;
		ctl.run('start',id);
	}
}
function dns_transport_state(p){
	let rows=jrun(['ip','-j','link','show']),transports=[],seen={};
	for(let tag in [p.automatic.active,...p.compiled.unknown_candidates]){let a=p.compiled.adapters[tag];if(!a?.usable||seen[tag])continue;seen[tag]=true;
		let value={tag,type:a.type,ipv4:a.ipv4,ipv6:a.ipv6};
		if(a.type=='amneziawg'){let link=filter(rows,r=>r.ifname==a.interface)[0];if(!link)continue;
			value={...value,interface:a.interface,index:link.ifindex,mark:a.mark};
		}else {if(!p.xray_needed_now)continue;value.socks='127.0.0.1:'+(a.port+32);}
		push(transports,value);if(length(transports)==4)break;
	}
	return {schema:1,endpoints:p.dns_tls_endpoints,transports};
}
function publish_dns_transport(p){save(DNS_STATE,dns_transport_state(p));}
function recovery_dns_service(p){
	let cfg={...p.dns,groups:[],client_policies:[],persistent:false};
	let path=TMP+'/dns-recovery.json';save(path,cfg);
	let ledger=TMP+'/dns-recovery-'+digest(path);
	if(!fs.lstat(ledger))net([DNS,'-config',path,'-ledger',ledger,'-init-ledger']);
	spawn('podkopchik-native-dns',command([DNS,'-config',path,'-ledger',ledger],state_env(),true));
}
function dns_service(g,p){let e=state_env(),cmd=command([DNS,'-config',g+'/dns.json','-ledger',ROOT+'/pools/'+p.epoch+'/watermark'],e,true);
	spawn('podkopchik-native-dns',cmd);}
function xray_service(g,p){if(!p.xray_needed_now){stop('podkopchik-native-xray');return;}
	let bin=trim(run(['sh','-c','. "$1/xray.sh"; xray_bin','xray',LIB]));
	spawn('podkopchik-native-xray',command([bin,'run','-config',g+'/xray.json'],state_env(),true));}
function health_service(g){let e={...state_env(),...env_for(g),PODKOPCHIK_CTL:'/usr/bin/podkopchikctl',PODKOPCHIK_NATIVE_ACTIVE:'1'};
	e.PODKOPCHIK_NATIVE_BOOTSTRAP_SPEC=g+'/spec.json';
	e.PODKOPCHIK_CTL=getenv('PODKOPCHIK_CTL') || '/usr/bin/podkopchikctl';
	spawn('podkopchik-native-health',command(['/bin/sh',LIB+'/health_check.sh','daemon'],e,true));}
function kill_legacy(){let s=service('podkopchik')?.podkopchik?.instances || {};
	for(let name in ['xray','health'])if(s[name]){let cmd=s[name].command || [];
		if(name=='xray' && (index(cmd,'-config')<0 || index(cmd,CONF+'/config.json')<0))fail('foreign main Xray instance');
		if(name=='health' && index(join(' ',cmd),'health_check.sh')<0)fail('foreign main health instance');
		run(['ubus','call','service','delete',sprintf('%J',{name:'podkopchik',instance:name})]);}}
function capture_legacy(){if(fs.lstat(ROOT+'/legacy/snapshot.json'))return;
	private_dir(ROOT+'/legacy');let g=ROOT+'/legacy',s=settings();
	if(exists_table('podkopchik')){copy(CONF+'/config.json',g+'/config.json');atomic(g+'/rules.nft',net(['nft','-s','list','table','inet','podkopchik']));}
	else{save(g+'/snapshot.json',{lan:s.lan_ifname || 'br-lan',active:false});return;}
	let state=read(TMP+'/state.json',true);if(state)atomic(g+'/state.json',state);
	let bin=trim(run(['sh','-c','. "$1/xray.sh"; xray_bin','xray',LIB]));
	save(g+'/snapshot.json',{lan:s.lan_ifname || 'br-lan',binary:bin,binary_sha256:digest(bin),state:!!state,active:true,
		ipv6:trim(read(TMP+'/routing6.env',true)||'')=='podkopchik-routing6-v1'});
}
function xray_ready(g,p){
	if(!p.xray_needed_now)return true;let s=instance('podkopchik-native-xray'),pid=+(s?.pid || 0);
	if(!s?.running || pid<2)return false;
	let argv=split(fs.readfile('/proc/'+pid+'/cmdline') || '','\x00');if(index(argv,g+'/xray.json')<0)return false;
	let sockets={},ports={};for(let fd in files('/proc/'+pid+'/fd')){let m=match(fs.readlink('/proc/'+pid+'/fd/'+fd) || '',/^socket:\[([0-9]+)\]$/);if(m)sockets[m[1]]=true;}
	for(let file in ['tcp','tcp6'])for(let row in split(fs.readfile('/proc/'+pid+'/net/'+file) || '','\n')){
		let f=split(trim(row),/[ \t]+/);if(f[3]=='0A' && sockets[f[9]])ports[hex(split(f[1],':')[1])]=true;
	}
	for(let a in p.adapters)if(a.type=='vless'&&(!ports[a.port]||!ports[a.port+32]))return false;
	return true;
}
function healthy(g,p){
	let dns=instance('podkopchik-native-dns');if(!dns?.running||+(dns.pid || 0)<2)return false;
	if(index(split(fs.readfile('/proc/'+dns.pid+'/cmdline') || '','\x00'),g+'/dns.json')<0)return false;
	if(!xray_ready(g,p))return false;
	if(!exists_table('podkopchik_native')||!exists_table('podkopchik_native_gate'))return false;
	let count=0;for(let v in jrun(['nft','-j','list','table','inet','fw4']).nftables || [])if(v.rule?.comment==OWNER)count++;
	if(count!=length(fw4_rules(p)))return false;
	return net([DNS,'-probe',p.dns.listen,'-probe-native'],null,true)!=null;
}
function activate_impl(g){verify(g);let saved=data(g+'/plan.json'),m=meta();transition([saved.lan],true);readmit(g);
	if(has_flowtable())fail('live flowtable prevents native activation');
	for(let pool in saved.dns.pools)net(['sh',LIB+'/fakedns_guard.sh','register-native',pool],{...state_env(),PODKOPCHIK_UCI_CONFIG_DIR:g+'/uci'});
	if(m.repair)emergency('suspend');
	start_transports(g);
	let p=compile(g);save(RUNTIME,p);
	if(sprintf('%J',p.dns)!=sprintf('%J',saved.dns)||sprintf('%J',p.xray)!=sprintf('%J',saved.xray))fail('immutable native policy changed outside Apply');
	// DNS policy is health-independent. Profile/layout edits require Apply.
	stop('podkopchik-native-dns');stop('podkopchik-native-xray');kill_legacy();
	policy_routes(p,false);includes(p,true);
	let lines=owned_tables(saved);if(exists_table('podkopchik'))push(lines,'delete table inet podkopchik');
	lines=[...lines,...fw4_delete(),p.nft.routing,p.nft.protection,p.nft.dns_redirect,...fw4_rules(p)];nft(join('\n',lines)+'\n');
	xray_service(g,p);publish_dns_transport(p);dns_service(g,p);
	let ready=false;for(let i=0;i<60;i++){
		if(meta().pending && journal('poll',g)=='rollback')fail('confirmation deadline expired during startup');
		if(healthy(g,p)){ready=true;break;}system(['sleep','1']);}
	if(!ready)fail('native listeners not ready');
	if(has_flowtable())fail('live flowtable prevents forwarding release');
	clear_boot_guard();
	m=meta();
	if(m.pending){let trial=data(g+'/trial.json');if(trial.state=='armed')journal('verify',g);if(journal('poll',g)=='rollback')fail('confirmation deadline expired during activation');}
	m.phase='active';m.engine='native';save(META,m);
	health_service(g);transition([p.lan],false);
	clear_missing_guard();
}
function activate(g){
	let previous=operation_deadline;operation_deadline=uptime()+120;
	let m=meta();if(m.pending){let t=data(generation(m.pending)+'/trial.json');if(t.boot!=boot)fail('Apply belongs to an earlier boot');if(!t.repair)operation_deadline=min(operation_deadline,t.deadline);}
	try{activate_impl(g);operation_deadline=previous;}catch(e){operation_deadline=previous;die(e.message);}
}
function recovery_policy(p){
	if(p.classification.unknown!='direct')return p;
	// Losing exact DNS classification may tighten Compatible, never widen it.
	p.classification={...p.classification,mode:'strict',migration_restrict_unknown:true,unknown:'protected',unknown_action:'protected'};
	p.compiled.classification=p.classification;
	p.nft.routing=planner.batch(p.compiled);p.nft.protection=planner.dns_gate(p.compiled);
	for(let f in ['4','6'])for(let protocol in ['tcp','udp','other'])p.unknown_fallback[f][protocol]=planner.unknown_target(p.compiled,f,protocol);
	for(let a in p.adapters)if(a.type=='vless')for(let f in ['4','6'])if(index(values(p.unknown_fallback[f]),a.tag)>=0)p.xray_needed_now=true;
	return p;
}
function recover_kernel(g){
	// An automatic return to legacy's implicit direct outbound would undo
	// Strict migration. Restore a protected real-answer DNS worker with the
	// validated native packet policy. Cached addresses stay protected/blocked.
	verify(g);let p=recovery_policy(compile(g)),m=meta();transition([p.lan],true);readmit(g);
	if(has_flowtable())fail('live flowtable prevents protected recovery');
	stop('podkopchik-native-health');stop('podkopchik-native-dns');stop('podkopchik-native-xray');kill_legacy();
	for(let pool in p.dns.pools)net(['sh',LIB+'/fakedns_guard.sh','register-native',pool],{...state_env(),PODKOPCHIK_UCI_CONFIG_DIR:g+'/uci'});
	start_transports(g);policy_routes(p,false);includes(p,true);
	let lines=[...owned_tables(p),...fw4_delete()];if(exists_table('podkopchik'))push(lines,'delete table inet podkopchik');
	lines=[...lines,p.nft.routing,p.nft.protection,p.nft.dns_redirect,...fw4_rules(p)];nft(join('\n',lines)+'\n');
	xray_service(g,p);publish_dns_transport(p);recovery_dns_service(p);
	let ready=false;for(let i=0;i<15;i++){if(net([DNS,'-probe',p.dns.listen,'-probe-native'],null,true)!=null){ready=true;break;}system(['sleep','1']);}
	if(!ready)fail('protected recovery DNS listener unavailable');
	save(RUNTIME,p);clear_boot_guard();
	m.current=substr(g,length(ROOT+'/g-'));m.engine='native';m.phase='recovery';if(!m.repair)m.pending=null;save(META,m);
	health_service(g);transition([p.lan],false);clear_missing_guard();
}
function rollback(m){
	let p=data(generation(m.current)+'/plan.json');transition([p.lan],true);
	stop('podkopchik-native-health');
	let failed=m.pending;
	if(failed && journal('poll',generation(failed))=='waiting')journal('abort',generation(failed));
	if(m.confirmed && m.confirmed!=m.current){
		let previous=generation(m.confirmed);verify(previous);let code=data(previous+'/code.json').path;
		m.current=m.confirmed;m.pending=null;m.phase='activating';m.code=code;save(META,m);
		if(code!=LIB){if(failed)journal('restored',generation(failed));watch_service();return;}
		activate(previous);
	}else recover_kernel(generation(m.previous || m.current));
	if(failed)journal('restored',generation(failed));
}
function discard_candidate(g){for(let sub in ['uci','awg']){for(let n in files(g+'/'+sub))fs.unlink(g+'/'+sub+'/'+n);fs.rmdir(g+'/'+sub);}for(let n in files(g))fs.unlink(g+'/'+n);fs.rmdir(g);}
function prune(){
	let m=meta(),keep={},codes={};for(let id in [m.current,m.confirmed,m.previous,m.pending])if(id)keep[id]=true;
	if(m.code)codes[m.code]=true;
	for(let n in files(ROOT))if(match(n,/^g-[a-f0-9]{32}$/)){
		let g=ROOT+'/'+n;private_dir(g);
		if(keep[substr(n,2)]){verify(g);codes[data(g+'/code.json').path]=true;continue;}
		// Only private regular files in our fixed generation layout are removable.
		for(let sub in ['uci','awg']){private_dir(g+'/'+sub);for(let name in files(g+'/'+sub))read(g+'/'+sub+'/'+name);}
		for(let name in files(g))if(index(['uci','awg'],name)<0)read(g+'/'+name);
		discard_candidate(g);
	}
	for(let n in files(ROOT))if(match(n,/^code-[a-f0-9]{64}$/)&&!codes[ROOT+'/'+n]){
		let path=ROOT+'/'+n;private_dir(path);for(let name in files(path))read(path+'/'+name);
		for(let name in files(path))fs.unlink(path+'/'+name);fs.rmdir(path);
	}
}
function persist_candidate(src,id){let dst=generation(id);private_dir(dst);
	for(let sub in ['uci','awg']){private_dir(dst+'/'+sub);for(let n in files(src+'/'+sub))copy(src+'/'+sub+'/'+n,dst+'/'+sub+'/'+n);}
	for(let n in ['spec.json','plan.json','dns.json','xray.json','code.json','files.sha256'])copy(src+'/'+n,dst+'/'+n);
	verify(dst);discard_candidate(src);return dst;
}
function prepare(checkonly,output){let s=settings(),prior=meta(),superseded=null;
	if(prior.pending){if(prior.repair && index(['repair','recovery'],prior.phase)>=0 && !checkonly){superseded=prior.pending;prior.pending=null;}else fail('confirm or abort the pending Apply first');}
	let repair=s.native_recovery_policy=='repair';if(s.native_recovery_policy && index(['transactional','repair'],s.native_recovery_policy)<0)fail('invalid Native recovery policy');
	if(repair){emergency('verify');let e=json(emergency('status'));if(!e.valid||!e.running||index(['armed','accepted'],e.mode)<0)fail('arm the verified independent emergency management watchdog before repair-mode Apply');}
	if(!helper_available())fail('install the Native DNS schema 3 protected-upstream component for this router architecture first');
	let id=nonce(),g=TMP+'/native-candidate-'+id;candidate_path=g;private_dir(g);private_dir(g+'/uci');copy(UCI_DIR+'/podkopchik',g+'/uci/podkopchik');snapshot_profiles(g);
	if(fs.lstat(UCI_DIR+'/firewall'))copy_code(UCI_DIR+'/firewall',g+'/uci/firewall');
	let staged=ctx(g+'/uci');staged.set('podkopchik','main','enabled','1');staged.set('podkopchik','main','routing_enabled','1');if(!staged.commit('podkopchik'))fail('cannot persist candidate intent');
	let pools=[];for(let raw in [s.native_pool_v4,s.native_pool_v6])if(raw)push(pools,guard.canonical(raw));
	if(!length(pools))fail('configure and admit a separate native synthetic pool');
	let namespaces=data(ROOT+'/namespaces.json',true) || [];let identity=join('|',pools),pool=null;
	if(type(namespaces)!='array'||length(namespaces)>8)fail('invalid native namespace registry');
	for(let n in namespaces)if(type(n.pools)!='array'||!length(n.pools)||!match(n.epoch || '',/^[a-f0-9]{16}$/)||n.identity!=join('|',map(n.pools,guard.canonical)))fail('untrusted native namespace registry');
	if(prior.current && !length(namespaces))fail('cannot reset the installed DNS namespace registry');
	for(let n in namespaces)if(n.identity==identity)pool=n;
	if(!pool)for(let n in namespaces)for(let old in n.pools)for(let next in pools)if(awg.overlap(old,next))fail('an issued pool cannot be reused in another DNS namespace');
	let existing_pool=pool!=null;
	if(!pool){let registered=data(getenv('PODKOPCHIK_CONFIG_DIR')?CONF+'/fakedns-guard.json':'/etc/podkopchik-fakedns-guard.json',true) || {};
		for(let old in registered.native_pools || [])for(let next in pools)if(awg.overlap(old,next))fail('issued native pool has no trusted allocator registry; choose a fresh pool');
		if(length(namespaces)>=8)fail('native namespace history capacity exhausted');
		pool={identity,pools,epoch:substr(nonce(),0,16),private_pool:null};for(let p in pools)if(require('native_pool').private_v4(p))pool.private_pool=p;push(namespaces,pool);}
	let old=data(ROOT+'/resources.json',true);
	let spec=inventory(g,pool,old);save(g+'/spec.json',spec);
	let p=compile(g);save(g+'/plan.json',p);save(g+'/dns.json',p.dns);save(g+'/xray.json',p.xray);manifest(g);let budget=preflight(g,p);
	policy_routes(p,false,true);
	if(checkonly){if(output)save(output,p);discard_candidate(g);candidate_path=null;return {valid:true,engine:'native',requires_xray:p.requires_xray,lan:p.lan,output,resources:budget};}
	let code=freeze();save(g+'/code.json',{path:code});manifest(g);
	g=persist_candidate(g,id);candidate_path=null;
	private_dir(ROOT+'/pools');private_dir(ROOT+'/pools/'+pool.epoch);
	let ledger=ROOT+'/pools/'+pool.epoch+'/watermark';
	if(!fs.lstat(ledger)){if(existing_pool)fail('refusing to reset a previously admitted DNS allocator');net([DNS,'-config',g+'/dns.json','-ledger',ledger,'-init-ledger']);}
	else if(!instance('podkopchik-native-dns')?.running)net([DNS,'-config',g+'/dns.json','-ledger',ledger,'-check']);
	if(!prior.current || prior.engine=='legacy')capture_legacy();save(ROOT+'/namespaces.json',namespaces);save(ROOT+'/resources.json',{pins:spec.pins,vless_slots:spec.vless_slots});
	let seconds=+(s.native_confirm_seconds || '300');if(seconds<60||seconds>900)fail('invalid confirmation deadline');
	journal(repair?'arm-repair':'arm',g,repair?120:seconds);
	let m={...prior,previous:prior.current,current:id,pending:id,phase:'prepared',engine:prior.engine || 'legacy',boot,code,repair};save(META,m);
	if(superseded)journal('cancel',generation(superseded));
	let c=ctx();c.set('podkopchik','main','enabled','1');c.set('podkopchik','main','routing_enabled','1');
	try{if(!c.commit('podkopchik'))fail('cannot record explicit Apply intent');watch_service();}
	catch(e){save(META,prior);journal('abort',g);journal('restored',g);fail('could not persist Apply intent or arm independent supervisor; previous runtime retained');}
	return {pending:id,timeout:repair?120:seconds,engine:'native',confirmation_required:true,recovery_policy:repair?'repair':'transactional'};
}
function select_state(path){let m=meta();if(m.engine!='native'||index(['active','recovery'],m.phase)<0)return;
	let g=generation(m.current);verify(g);let previous=data(RUNTIME),next=compile(g,path);
	if(m.phase=='recovery')next=recovery_policy(next);
	let batch=planner.switch_batch(previous.compiled,next.compiled);
	nft(batch,true);
	if(next.xray_needed_now){xray_service(g,next);let ready=false;for(let i=0;i<10;i++){if(xray_ready(g,next)){ready=true;break;}system(['sleep','1']);}if(!ready)fail('VLESS listeners are not ready');}
	nft(batch);publish_dns_transport(next);if(!next.xray_needed_now)xray_service(g,next);save(RUNTIME,next);fs.unlink(TMP+'/native-error');
}
function boot_guard(){let m=meta();if(!m.current || settings().routing_enabled=='0')return;
	let p=data(generation(m.current)+'/plan.json');transition([p.lan],true);
}
function release_native(m){
	if(!m.current){clear_missing_guard();return;}let p=data(generation(m.current)+'/plan.json');transition([p.lan],true);
	stop('podkopchik-native-health');stop('podkopchik-native-dns');stop('podkopchik-native-xray');
	let lines=[...owned_tables(p),...fw4_delete()];
	let chain=net(['nft','-j','list','chain','inet','fw4','pkc_native_boot'],null,true);
	if(chain){let rows=filter(json(chain).nftables || [],r=>r.chain);if(rows[0]?.chain?.comment!=OWNER)fail('foreign boot chain');push(lines,'delete chain inet fw4 pkc_native_boot');}
	if(length(lines))nft(join('\n',lines)+'\n');includes(null,false);release_policy_routes();
	if(m.pending && journal('poll',generation(m.pending))=='waiting')journal('abort',generation(m.pending));
	m.engine='native';m.phase='disabled';m.pending=null;save(META,m);
	if(m.repair)emergency('disarm');
	transition([p.lan],false);clear_missing_guard();stop('podkopchik-native-watch');
}
function tick(){let m=meta();if(!m.current)return false;let g=generation(m.current);
	if(m.phase=='emergency')return false;
	if(m.repair){let e=json(emergency('status'));if(!e.valid||!e.running){transition([data(g+'/plan.json').lan],true);emergency('request');m.phase='emergency';save(META,m);return false;}}
	if(m.pending){let state=journal('poll',g);
		if(state=='rollback'){if(m.repair){transition([data(g+'/plan.json').lan],true);emergency('request');return false;}rollback(m);return true;}
		if(state=='confirmed'){m.confirmed=m.current;m.pending=null;save(META,m);}
	}
	if(m.phase=='rollback'){rollback(m);return true;}
	if(m.phase=='prepared'||m.phase=='activating'){try{activate(g);}catch(e){atomic(TMP+'/native-error',substr(sprintf('%J',e)+'\n'+(fs.readfile(TMP+'/native-last-command.json') || '')+'\n'+(fs.readfile(TMP+'/native-command.err') || ''),0,4096));m=meta();m.phase=m.repair?'repair':'rollback';if(m.repair)m.engine='native';save(META,m);if(!m.repair)rollback(m);}return true;}
	if(m.phase=='repair')return true;
	if(m.engine=='native'&&m.phase=='recovery'){
		let p=data(RUNTIME);if(!exists_table('podkopchik_native')||!exists_table('podkopchik_native_gate'))recover_kernel(g);
		if(!instance('podkopchik-native-dns')?.running)recovery_dns_service(p);
		if(time()-selection_at>=30){start_transports(g);select_state();selection_at=time();}
	}
	if(m.engine=='native'&&m.phase=='active'){
		let p=data(RUNTIME);
		if(has_flowtable()){transition([p.lan],true);atomic(TMP+'/native-error','Flow offloading is unsupported; Native LAN guard retained.\n');return true;}
		let count=0;for(let row in jrun(['nft','-j','list','table','inet','fw4']).nftables || [])if(row.rule?.comment==OWNER)count++;
		if(count!=length(fw4_rules(p)))reconcile_fw4(p);
		if(!healthy(g,p)){transition([p.lan],true);try{activate(g);}catch(e){
			atomic(TMP+'/native-error',substr(e.message,0,4096));
			// A permanently failed classifier must not leave all LAN DNS
			// redirected to a dead listener. Retain Strict and protected DNS.
			try{recover_kernel(g);}catch(recovery_error){atomic(TMP+'/native-error',substr(e.message+'\n'+recovery_error.message,0,4096));}
			return true;
		}}
		clear_boot_guard();
		if(time()-selection_at>=30){try{start_transports(g);select_state();selection_at=time();}catch(e){atomic(TMP+'/native-error',substr(e.message,0,4096));}}
	}
	return true;
}

const action=ARGV[0];
if(NS && trim(fs.readfile('/sys/class/dmi/id/sys_vendor') || '')!='QEMU' && replace(fs.readfile('/proc/device-tree/model') || '','\x00','')!='linux,dummy-virt')fail('VM override is forbidden on hardware');
if(action=='status'&&!fs.lstat(ROOT)){let selected=settings().routing_engine=='native';printf('%J\n',{engine:selected?'native':'legacy',phase:selected?'uninitialized':'inactive',pending:null,ready:false,available:helper_available()});return;}
if(!fs.lstat(CONF))fs.mkdir(CONF,0o700);if(!fs.lstat(TMP))fs.mkdir(TMP,0o700);
for(let path in [CONF,TMP]){let s=fs.lstat(path);if(s?.type!='directory'||s.uid!=0||(s.mode&0o022))fail('unsafe coordinator parent directory');}
private_dir(ROOT);
function locked(fn){let f=fs.open(ROOT+'/.lock','a+',0o600);if(!f||!f.lock('x'))fail('cannot lock runtime');try{let v=fn();f.close();return v;}catch(e){
	if(candidate_path){try{discard_candidate(candidate_path);}catch(cleanup_error){}}
	f.close();die(e.message);}}
if(action=='management-heartbeat'){
	let m=meta();if(!m.repair||!m.pending||ARGV[1]!=m.pending)fail('repair management token changed');
	let e=json(emergency('status'));emergency('heartbeat',e.token);journal('repair-renew',generation(m.pending),120);print('Management lease renewed.\n');
}else if(action=='watch'){
	for(;;){let keep=locked(tick);if(!keep)return;system(['sleep','2']);}
}else if(action=='apply')printf('%J\n',locked(()=>prepare(false)));
else if(action=='validate')printf('%J\n',locked(()=>prepare(true)));
else if(action=='generate')printf('%J\n',locked(()=>prepare(true,ARGV[1] || CONF+'/native.generated.json')));
else if(action=='validate-active')locked(()=>{let m=meta();if(!m.current||m.phase=='disabled')fail('no active native generation');let g=generation(m.current);verify(g);readmit(g);let p=data(RUNTIME,true) || data(g+'/plan.json');preflight(g,p);policy_routes(p,false,true);print('Native active generation is valid.\n');});
else if(action=='boot')locked(()=>{let m=meta();if(!m.current)return;
	if(m.phase=='emergency')return;
	if(settings().routing_enabled=='0'){release_native(m);return;}
	if(settings().enabled=='0'){boot_guard();return;}
	boot_guard();if(m.pending && journal('poll',generation(m.current))=='rollback'){if(m.repair){emergency('request');return;}rollback(m);watch_service();return;}
	if(m.phase=='recovery'){recover_kernel(generation(m.current));watch_service();return;}
	m.phase='activating';save(META,m);watch_service();});
else if(action=='early')locked(()=>{if(meta().phase=='emergency')return;if(settings().routing_enabled=='0')includes(null,false);else boot_guard();});
else if(action=='firewall')locked(()=>{let m=meta();if(!m.current||m.phase=='disabled')return;let p=data(RUNTIME,true) || data(generation(m.current)+'/plan.json');reconcile_fw4(p);});
else if(action=='health')locked(()=>select_state(ARGV[1]));
else if(action=='health-once'){
	let m=locked(meta);if(!m.current)fail('no native generation');let g=generation(m.current);verify(g);
	let e={...state_env(),...env_for(g),PODKOPCHIK_CTL:getenv('PODKOPCHIK_CTL') || '/usr/bin/podkopchikctl',PODKOPCHIK_NATIVE_ACTIVE:'1'};
	e.PODKOPCHIK_NATIVE_BOOTSTRAP_SPEC=g+'/spec.json';
	if(system(command(['/bin/sh',LIB+'/health_check.sh','once'],e,true))!=0)fail('native health check failed');
}
else if(action=='confirm')locked(()=>{let m=meta();if(!m.pending||ARGV[1]!=m.pending)fail('Apply token changed');let g=generation(m.pending),p=data(RUNTIME);
	if(m.phase!='active')fail('native activation is not complete');
	if(!healthy(g,p))fail('native listeners or owned firewall permits are not ready for confirmation');
	if(p.classification.unknown=='protected'&&p.automatic.active=='blocked')fail('protected transport is unavailable for confirmation');
	net([DNS,'-protected-probe',DNS_STATE,'-probe-name','www.youtube.com']);
	journal('confirm',g);m.confirmed=m.current;m.pending=null;save(META,m);prune();print('Native Apply confirmed.\n');});
else if(action=='abort')locked(()=>{let m=meta();if(!m.pending||m.pending!=ARGV[1])fail('Apply token changed');if(m.repair)emergency('request');else journal('abort',generation(m.pending));});
else if(action=='stop')locked(()=>{let m=meta();if(m.engine!='native')return;let p=data(generation(m.current)+'/plan.json');transition([p.lan],true);stop('podkopchik-native-health');stop('podkopchik-native-dns');stop('podkopchik-native-xray');
	// A service stop is not permission to send LAN DNS through the ISP.
	// Retain DNS interception to the stopped listener (fail closed).
	m.phase='stopped';save(META,m);stop('podkopchik-native-watch');});
else if(action=='disable')locked(()=>release_native(meta()));
else if(action=='leave')locked(()=>{let m=meta();if(m.current && (m.phase!='disabled'||settings().routing_enabled!='0'))fail('explicitly disable Native routing before changing engines');
	if(m.current)save(ROOT+'/last-native.json',m);
	save(META,{schema:1,engine:'legacy',phase:'inactive',current:null,confirmed:null,pending:null});});
else if(action=='status'){let m=meta(),g=m.current?generation(m.current):null,p=g?data(RUNTIME,true):null;
	if(!m.current&&settings().routing_engine=='native'){printf('%J\n',{engine:'native',phase:'uninitialized',pending:null,ready:false,available:helper_available()});return;}
	let valid_trial=!m.pending || journal('poll',generation(m.pending))=='waiting';
	printf('%J\n',{engine:m.engine,phase:m.phase,pending:m.pending,confirmed:m.confirmed,available:helper_available(),lan:p?.lan,xray_required:p?.xray_needed_now || false,
		ready:p && m.phase=='active' && valid_trial?healthy(g,p):false,automatic:p?.automatic,unknown_fallback:p?.unknown_fallback,recovery_policy:m.repair?'repair':'transactional',dns_upstream:data(DNS_STATE,true),error:read(TMP+'/native-error',true)});}
else fail('unknown native lifecycle action');
