'use strict';
import * as fs from 'fs';
// Read-only, address-free process measurement. Match socket inodes, not all
// namespace sockets exposed by /proc/PID/net.
let p=fs.popen('ubus call service list \'{"name":"podkopchik-native-dns"}\'','r');
if(!p)die('ubus unavailable');
let services=json(p.read('all'));if(p.close()!=0)die('service inventory failed');
let pid=services['podkopchik-native-dns']?.instances?.main?.pid;
if(type(pid)!='int'||pid<2)die('Native DNS process is not running');
let root='/proc/'+pid,sockets={},counts={fd:0,tcp:0,udp:0,unix:0,socket_other:0,pipe:0,anon_inode:0,file:0,other:0};
for(let fd in fs.lsdir(root+'/fd') || []) {
	let path=fs.readlink(root+'/fd/'+fd);if(path==null)continue;counts.fd++;
	let m=match(path,/^socket:\[([0-9]+)\]$/);
	if(m){sockets[m[1]]=(sockets[m[1]] || 0)+1;continue;}
	if(index(path,'pipe:[')==0)counts.pipe++;
	else if(index(path,'anon_inode:')==0)counts.anon_inode++;
	else if(fs.stat(root+'/fd/'+fd)?.type=='file')counts.file++;
	else counts.other++;
}
let states={},classified={};
for(let kind in ['tcp','tcp6','udp','udp6','unix']) {
	let lines=split(fs.readfile(root+'/net/'+kind) || '','\n');
	for(let line in slice(lines,1)) {
		let c=split(trim(line),/[ \t]+/),inode=c[kind=='unix'?6:9];
		if(!sockets[inode]||classified[inode])continue;classified[inode]=true;
		let type=kind=='unix'?'unix':index(kind,'tcp')==0?'tcp':'udp';counts[type]+=sockets[inode];
		if(type=='tcp')states[c[3]]=(states[c[3]] || 0)+sockets[inode];
	}
}
for(let inode,n in sockets)if(!classified[inode])counts.socket_other+=n;
let status=fs.readfile(root+'/status') || '',stat=split(trim(fs.readfile(root+'/stat') || ''),' ');
printf('%J\n',{epoch:time(),pid,counts,tcp_states_hex:states,
	rss_kib:+(match(status,/VmRSS:[ \t]+([0-9]+)/)?.[1] || 0),cpu_ticks:+stat[13]+ +stat[14],
	start_ticks:+stat[21],system_uptime:trim(fs.readfile('/proc/uptime') || ''),
	mem_available_kib:+(match(fs.readfile('/proc/meminfo') || '',/MemAvailable:[ \t]+([0-9]+)/)?.[1] || 0),
	conntrack:+trim(fs.readfile('/proc/sys/net/netfilter/nf_conntrack_count') || '0'),load:trim(fs.readfile('/proc/loadavg') || '')});
