'use strict';
import * as fs from 'fs';
import {cursor} from 'uci';
const review=require('native_inventory'), probe=require('native_platform_probe'), awg=require('awg'), vless=require('vless'), network=require('awg_network');
const helper=length(ARGV)==0?'/usr/libexec/podkopchik/podkopchik-native-dns':ARGV[1];
if(length(ARGV)!=0&&(length(ARGV)!=2||ARGV[0]!='--helper')) die('Use native_inventory_check.uc [--helper VERIFIED_HELPER]\n');
let exec=probe.probe(helper), c=cursor(), s={}, profiles=[], remote=[], endpoints=[], exclusions=[], issued=[], endpoint_complete=false;
function read_state(path,optional) {
	let st=fs.lstat(path);
	if(!st&&optional) return null;
	if(st?.type!='file'||st.uid!=0||st.nlink!=1||(st.mode&0o077)||st.size>1048576) die('unsafe state');
	let v=fs.readfile(path,1048577);
	if(v==null||length(v)>1048576) die('unreadable state');
	return json(v);
}
function add_endpoint(p,host) {
	if(awg.ip(host)) push(endpoints,host);
	else p.unresolved=true;
}
if(c.load('podkopchik')) {
	s=c.get_all('podkopchik','main') || {};
	endpoint_complete=true;
	c.foreach('podkopchik','proxy',p=>{
		if(p.enabled=='0'||length(profiles)>64) return;
		let row={protocol:p.protocol || 'vless',role:p.role,valid:false};
		try {
			row.tag=vless.clean_tag(p.tag || p.name,'proxy');
			if(row.protocol=='amneziawg') {
				let profile=awg.store('/etc/podkopchik/awg',0).inspect_profile(p.awg_id).parsed;
				row.resource=network.resources(p.awg_id); row.tag=row.resource.tag;
				row.listen_port=profile.interface.ListenPort;
				for(let ep in profile.endpoints || [])
					add_endpoint(row,substr(ep,0,1)=='['?substr(ep,1,index(ep,']')-1):substr(ep,0,rindex(ep,':')));
				for(let value in split(profile.interface.Address || '',',')) if(trim(value)) push(remote,{dst:trim(value)});
				for(let peer in profile.peers || []) for(let value in split(peer.AllowedIPs || '',','))
					if(trim(value)&&index(['0.0.0.0/0','::/0'],trim(value))<0) push(remote,{dst:trim(value)});
				row.valid=true;
			} else if(row.protocol=='vless') { add_endpoint(row,vless.parse(p.uri || '').address); row.valid=true; }
		} catch(e) { }
		push(profiles,row);
	});
	c.foreach('podkopchik','bypass_rule',p=>{
		if(p.enabled!='0'&&p.host&&length(exclusions)<=512) push(exclusions,p.host);
	});
	let dns=s.native_dns_tls || ['1.1.1.1:853@one.one.one.one','9.9.9.9:853@dns.quad9.net',
		'[2606:4700:4700::1111]:853@one.one.one.one','[2620:fe::fe]:853@dns.quad9.net'];
	if(type(dns)=='string') dns=[dns];
	if(type(dns)!='array'||!length(dns)||length(dns)>8) endpoint_complete=false;
	else for(let entry in dns) {
		let parts=split(entry,'@'), m=match(parts[0],/^\[([0-9A-Fa-f:]+)\]:([0-9]+)$/)||match(parts[0],/^([0-9.]+):([0-9]+)$/);
		if(length(parts)!=2||!m||!awg.ip(m[1])||+m[2]<1||+m[2]>65535||!awg.domain(parts[1])) endpoint_complete=false;
		else push(endpoints,m[1]);
	}
}
try {
	let state=read_state('/etc/podkopchik/native-state/runtime.json',true);
	let registry=read_state('/etc/podkopchik/native-state/namespaces.json',!state?.current);
	let guard=read_state('/etc/podkopchik-fakedns-guard.json',true);
	if(registry!=null&&type(registry)!='array') die('invalid registry');
	for(let ns in registry || []) {
		if(type(ns.pools)!='array') die('invalid registry');
		issued=[...issued,...ns.pools];
	}
	let legacy=read_state('/etc/podkopchik/config.json',true);
	for(let f in (type(legacy?.fakedns)=='array'?legacy.fakedns:[legacy?.fakedns])) if(f?.ipPool) push(issued,f.ipPool);
	issued=[...issued,...(guard?.pools || []),...(guard?.native_pools || [])];
} catch(e) { issued=null; }
let r4=exec.json_command('/sbin/ip -N -4 -j route show table all'), r6=exec.json_command('/sbin/ip -N -6 -j route show table all');
let p4=exec.json_command('/sbin/ip -N -4 -j rule show'), p6=exec.json_command('/sbin/ip -N -6 -j rule show');
let nft=exec.json_command('nft -j list tables');
let ports={}, complete=true;
for(let kind in ['tcp','tcp6','udp','udp6']) {
	let contents=fs.readfile('/proc/net/'+kind,262145);
	let p=length(contents || '')>262144?null:review.sockets(contents,index(kind,'tcp')==0);
	if(p==null) complete=false;
	else for(let port in p) ports[port]=true;
}
let report=review.assess({
	lan:s.lan_ifname || 'br-lan', dns_port:s.native_dns_port || '24253', profiles,
	addresses:exec.json_command('/sbin/ip -N -j address show'),
	routes:type(r4)=='array'&&type(r6)=='array'?[...r4,...r6,...remote]:null,
	rules:type(p4)=='array'&&type(p6)=='array'?[...p4,...p6]:null,
	ports:complete?map(keys(ports),p=>+p):null, issued,endpoints,exclusions,
	nft_tables:type(nft?.nftables)=='array'?map(filter(nft.nftables,r=>r.table),r=>r.table):null,
	endpoint_inventory_complete:endpoint_complete,
	pools:filter([s.native_pool_v4,s.native_pool_v6],p=>!!p)
});
report.source='live_read_only';
printf('%J\n',report);
exit(report.status=='no_observed_conflicts'?0:2);
