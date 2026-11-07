'use strict';
import * as fs from 'fs';
const model=require('native_observe_lib');
const action=ARGV[0],work=ARGV[1],OWNER='pkc-native-observe-v1';
const META='/etc/podkopchik/native-state/runtime.json',PLAN='/tmp/podkopchik/native-runtime-plan.json';
let config;
function fail(){die('Native observation failed; no routing or recovery action taken\n');}
function text(path){return fs.readfile(path) || '';}
function jsonfile(path, limit){let s=fs.lstat(path);if(!s||s.type!='file'||s.uid!=0||(s.mode&0o077)||s.nlink!=1||s.size>(limit || 4194304))fail();return json(text(path));}
function atomic(name,value){let path=work+'/'+name,f=fs.open(path+'.new','w',0o600);if(!f)fail();f.write(sprintf('%J\n',value));f.close();if(!fs.rename(path+'.new',path))fail();}
function uptime(){return int(split(text('/proc/uptime'),' ')[0]);}
function quote(v){return "'"+replace(''+v,"'","'\\''")+"'";}
function command(args, seconds){
	let cmd=[config.helper,'-run-timeout',''+(seconds || 5),'--',...args];
	let p=fs.popen(join(' ',map(cmd,quote))+' 2>/dev/null','r');if(!p)return null;
	let out=p.read('all'),rc=p.close();if(rc!=0||length(out)>65536)return null;return out;
}
function service(name){let out=command(['ubus','call','service','list',sprintf('%J',{name})]);if(out==null)return null;let v=json(out);return v[name]?.instances?.main;}
function process(pid){
	if(!pid || pid<2)return null;let root='/proc/'+pid,stat=text(root+'/stat');if(!stat)return null;
	let count={fd:0,tcp:0,udp:0,unix:0,socket_other:0,pipe:0,anon_inode:0,file:0,other:0,raced:0},sockets={},seen={},states={};
	for(let fd in fs.lsdir(root+'/fd') || []){
		let path=fs.readlink(root+'/fd/'+fd);if(!path){count.raced++;continue;}count.fd++;
		let m=match(path,/^socket:\[([0-9]+)\]$/);
		if(m){sockets[m[1]]=(sockets[m[1]] || 0)+1;continue;}
		if(index(path,'pipe:[')==0)count.pipe++;else if(index(path,'anon_inode:')==0)count.anon_inode++;
		else if(fs.stat(root+'/fd/'+fd)?.type=='file')count.file++;else count.other++;
	}
	for(let type in ['tcp','tcp6','udp','udp6','unix'])for(let row in slice(split(text(root+'/net/'+type),'\n'),1)){
		let c=model.words(row),inode=c[type=='unix'?6:9];if(!sockets[inode]||seen[inode])continue;seen[inode]=true;
		let kind=type=='unix'?'unix':index(type,'tcp')==0?'tcp':'udp';count[kind]+=sockets[inode];
		if(kind=='tcp')states[c[3]]=(states[c[3]] || 0)+sockets[inode];
	}
	for(let inode,n in sockets)if(!seen[inode])count.socket_other+=n;
	let status=text(root+'/status'),limit=match(text(root+'/limits'),/Max open files[ \t]+([0-9]+)/);
	return {...count,...model.process_stat(stat),pid,fd_at_end:length(fs.lsdir(root+'/fd') || []),rss_kib:model.field(status,'VmRSS'),
		fd_limit:limit?+limit[1]:null,tcp_states:states};
}
if(trim(text('/tmp/sysinfo/board_name'))!='xiaomi,redmi-router-ax6000-stock')fail();
if(!match(work || '',/^\/tmp\/pkc-native-observe\.[A-Za-z0-9]+$/))fail();
let dir=fs.lstat(work);if(dir?.type!='directory'||dir.uid!=0||(dir.mode&0o077))fail();
if(action=='init'){
	if(fs.lstat(work+'/config.json'))fail();let hours=+ARGV[2];if(hours<24||hours>48)fail();
	let m=jsonfile(META),p=jsonfile(PLAN);if(m.engine!='native'||m.phase!='active'||m.pending)fail();
	let pidfile=fs.popen('ubus call service list \'{"name":"podkopchik-native-dns"}\'','r');if(!pidfile)fail();
	let services=json(pidfile.read('all'));if(pidfile.close()!=0)fail();
	let pid=services['podkopchik-native-dns']?.instances?.main?.pid;
	let helper=fs.readlink('/proc/'+pid+'/exe');
	if(!match(helper || '',/^\/etc\/podkopchik\/native-bin\/[a-f0-9]{64}$/))fail();
	let transports=sort(keys(p.compiled.adapters));if(length(transports)>32)fail();
	atomic('config.json',{owner:OWNER,started_epoch:time(),deadline_epoch:time()+hours*3600,started_mono:uptime(),deadline_mono:uptime()+hours*3600,
		boot:trim(text('/proc/sys/kernel/random/boot_id')),helper,transports,interval:60,probe_interval:900,log_limit:524288});
	print('Observation configured; application configuration unchanged.\n');return;
}
config=jsonfile(work+'/config.json',65536);if(config.owner!=OWNER)fail();
if(action=='remaining'){print(model.finished(config,uptime(),trim(text('/proc/sys/kernel/random/boot_id')))?0:max(0,config.deadline_mono-uptime()));return;}
if(action=='failure'){
	let s=fs.lstat(work+'/summary.json')?jsonfile(work+'/summary.json'):{schema:1,samples:0,started_epoch:config.started_epoch};
	s.collection_failures=(s.collection_failures || 0)+1;s.last_collection_failure_epoch=time();atomic('summary.json',s);return;
}
if(action=='finish'){
	let s=fs.lstat(work+'/summary.json')?jsonfile(work+'/summary.json'):{};
	s.monitor_finished=true;s.finished_epoch=time();s.complete=uptime()>=config.deadline_mono;s.stop_reason=s.complete?'deadline':'operator_or_interruption';atomic('summary.json',s);return;
}
if(action=='report'){printf('%J\n',jsonfile(work+'/summary.json'));return;}
if(action!='sample')fail();
let old=fs.lstat(work+'/summary.json')?jsonfile(work+'/summary.json'):null;
if(model.finished(config,uptime(),trim(text('/proc/sys/kernel/random/boot_id'))))return;
let m=jsonfile(META),p=jsonfile(PLAN),health=jsonfile('/tmp/podkopchik/state.json'),dns=service('podkopchik-native-dns'),emergency=service('podkopchik-native-emergency');
let proc=process(dns?.running?dns.pid:null),cpu=model.cpu(text('/proc/stat')),mem=text('/proc/meminfo'),connections=[];
let active=index(config.transports,p.automatic?.active),warnings=[];
for(let i,tag in config.transports){let a=p.compiled.adapters[tag],h=health.proxies?.[tag] || {},iface=a?.interface;
	let row={connection:+i+1,status:index(['up','down','unknown'],h.status)>=0?h.status:'unknown',
		probe:index(['up','down','unknown'],h.probe_status)>=0?h.probe_status:'unknown',age:max(0,time()-(h.checked_at || 0)),
		fail_count:+(h.fail_count || 0),latency_ms:type(h.latency_ms)=='int'?h.latency_ms:null};
	if(row.age>300 && index(warnings,'health_stale')<0)push(warnings,'health_stale');
	if(row.status=='down' && index(warnings,'transport_down')<0)push(warnings,'transport_down');
	if(iface && match(iface,/^[A-Za-z0-9_.-]{1,15}$/)){
		row.ifindex=+trim(text('/sys/class/net/'+iface+'/ifindex'));row.up=(hex(trim(text('/sys/class/net/'+iface+'/flags')))&1)!=0;
		row.rx_bytes=+trim(text('/sys/class/net/'+iface+'/statistics/rx_bytes'));row.tx_bytes=+trim(text('/sys/class/net/'+iface+'/statistics/tx_bytes'));
		let out=command(['awg','show',iface,'latest-handshakes']),last=0;
		if(out!=null)for(let line in split(out,'\n')){let w=model.words(line);if(length(w)==2)last=max(last,+w[1]);}
		row.handshake_age=last?max(0,time()-last):null;
	}
	push(connections,row);
}
let eg=jsonfile('/etc/podkopchik-native-emergency/state.json',65536);
let sample={epoch:time(),uptime:uptime(),process:proc,cpu:{...model.cpu_delta(old?.last?.cpu_raw,cpu,proc,old?.last?.process)},cpu_raw:cpu,
	memory:{total_kib:model.field(mem,'MemTotal'),available_kib:model.field(mem,'MemAvailable')},
	conntrack:{count:+trim(text('/proc/sys/net/netfilter/nf_conntrack_count')),max:+trim(text('/proc/sys/net/netfilter/nf_conntrack_max'))},
	native:{active:active<0?0:active+1,health_switch_epoch:+(health.groups?.auto_proxy_group?.last_switch_time || 0),phase:index(['active','repair','recovery','stopped','emergency'],m.phase)>=0?m.phase:'other',pending:!!m.pending,
		error:!!length(trim(text('/tmp/podkopchik/native-error'))),xray:!!service('podkopchik-native-xray')?.running},
	emergency:{accepted:eg.mode=='accepted',running:!!emergency?.running},connections,probes:{}};
let due=!old?.last_probe_mono || uptime()-old.last_probe_mono>=config.probe_interval;
if(due){
	sample.probes.dns_udp_tcp=command([config.helper,'-probe',p.dns.listen,'-probe-native'],6)!=null?'ok':'fail';
	sample.probes.protected_dot=command([config.helper,'-protected-probe','/tmp/podkopchik/native-dns-upstream.json','-probe-name','www.youtube.com'],7)!=null?'ok':'fail';
	let current=p.compiled.adapters[p.automatic?.active];
	sample.probes.protected_https=current?.type=='amneziawg' && match(current.interface,/^[A-Za-z0-9_.-]{1,15}$/)?
		(trim(command(['curl','--interface',current.interface,'--noproxy','*','--connect-timeout','3','--max-time','5','--resolve','one.one.one.one:443:1.1.1.1','-sS','-o','/dev/null','-w','%{http_code}','https://one.one.one.one/cdn-cgi/trace'],6) || '')=='200'?'ok':'fail'):'skipped';
	// Root WAN control is not claimed as a LAN Direct-policy acceptance test.
	sample.probes.wan_control_https=trim(command(['curl','--interface','wan','--noproxy','*','--connect-timeout','3','--max-time','5','--resolve','one.one.one.one:443:1.1.1.1','-sS','-o','/dev/null','-w','%{http_code}','https://one.one.one.one/cdn-cgi/trace'],6) || '')=='200'?'ok':'fail';
	let tables=command(['nft','-j','list','tables']);
	let names=tables!=null?map(filter(json(tables).nftables || [],v=>v.table?.family=='inet'),v=>v.table.name):[];
	sample.probes.guard_tables=index(names,'podkopchik_native')>=0 && index(names,'podkopchik_native_gate')>=0 && index(names,'podkopchik_fake_guard')>=0?'ok':'fail';
}
if(!proc)push(warnings,'dns_process_missing');
if(active<0)push(warnings,'protected_transport_unavailable');
if(proc?.fd_limit && proc.fd>=proc.fd_limit*0.85)push(warnings,'fd_pressure');
if(sample.memory.available_kib<98304)push(warnings,'ram_pressure');
if(sample.conntrack.max && sample.conntrack.count>=sample.conntrack.max*0.8)push(warnings,'conntrack_pressure');
if(!sample.emergency.accepted||!sample.emergency.running)push(warnings,'emergency_not_ready');
if(sample.native.phase!='active'||sample.native.error)push(warnings,'native_attention');
for(let name,v in sample.probes)if(v=='fail')push(warnings,'probe_'+name);
sample.warnings=warnings;
let next=model.aggregate(old,sample);if(due)next.last_probe_mono=uptime();
next.started_epoch=config.started_epoch;next.deadline_epoch=config.deadline_epoch;next.monitor_finished=false;
atomic('summary.json',next);
model.bounded_append(fs,work+'/samples.jsonl',sprintf('%J\n',sample),config.log_limit);
