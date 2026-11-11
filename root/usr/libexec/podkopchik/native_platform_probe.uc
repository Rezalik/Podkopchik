'use strict';
import * as fs from 'fs';
import {cursor} from 'uci';
const platform=require('native_platform');
function quote(s) { return "'"+replace(s,"'","'\\''")+"'"; }

function identity() {
	let os=platform.release(fs.readfile('/etc/openwrt_release',4096));
	os.board=trim(fs.readfile('/tmp/sysinfo/board_name',256) || '') || null;
	os.kernel=trim(fs.readfile('/proc/sys/kernel/osrelease',256) || '') || null;
	return os;
}
function probe(helper) {
	let executor=null, stat=fs.lstat(helper);
	function command(text) {
		if (!executor) return null;
		let p=fs.popen(quote(executor)+' -run-timeout 4 -- sh -c '+quote(text)+' 2>/dev/null','r');
		if (!p) return null;
		let out=p.read(65537), rc=p.close();
		return rc==0 && type(out)=='string' && length(out)<=65536 ? trim(out) : null;
	}
	function json_command(text) {
		let out=command(text);
		try { return out==null ? null : json(out); } catch (e) { return null; }
	}
	function collect(want_awg) {
		let os=identity();
		os.machine=command('uname -m');
		let commands={}, list=[...platform.requirements().commands,'awg'];
		let raw=command('for name in '+join(' ',list)+'; do if command -v "$name" >/dev/null 2>&1; then printf "%s=1\\n" "$name"; else printf "%s=0\\n" "$name"; fi; done');
		for (let line in split(raw || '', '\n')) { let m=match(line,/^([a-z0-9_]+)=([01])$/); if (m && index(list,m[1])>=0) commands[m[1]]=m[2]=='1'; }
		let firewall={software_offload:null,hardware_offload:null}, c=cursor(), defaults=[];
		if (c.load('firewall')) c.foreach('firewall','defaults',s=>push(defaults,s));
		if (length(defaults)==1) {
			firewall.software_offload=platform.flag(defaults[0].flow_offloading);
			firewall.hardware_offload=platform.flag(defaults[0].flow_offloading_hw);
		}
		let flow=json_command('nft -j list flowtables'), tables=json_command('nft -j list tables');
		firewall.flowtables=type(flow?.nftables)=='array' ? length(filter(flow.nftables,r=>!!r.flowtable)) : null;
		firewall.fw4_table=type(tables?.nftables)=='array' ? length(filter(tables.nftables,r=>r.table?.name=='fw4' && r.table.family=='inet'))>0 : null;
		let disk=command('df -Pk /overlay /tmp'), ip=command('ip -V'), tools=want_awg?command('awg --version'):null;
		return {schema:1,os,commands,bounded_commands:executor?true:null,iproute2:ip==null?null:index(ip,'iproute2')>=0,firewall,
			resources:{mem_available_kib:platform.memory(fs.readfile('/proc/meminfo')),overlay_free_kib:platform.space(disk,'/overlay'),tmp_free_kib:platform.space(disk,'/tmp')},
			awg:{requested:want_awg,tools_31:want_awg?(tools==null?commands.awg===false?false:null:!!match(tools,/^amneziawg-tools v3\.1\./)):null,
				loaded:want_awg?!!fs.stat('/sys/module/amneziawg'):null}};
	}
	if (match(helper,/^\/[A-Za-z0-9_.\/-]+$/) && stat?.type=='file' && stat.uid==0 && stat.nlink==1 && !(stat.mode&0o022) && (stat.mode&0o111)) {
		executor=helper;
		let caps=json_command(quote(helper)+' -capabilities');
		if (caps?.schema!=3 || caps.bounded_commands!==true) executor=null;
	}
	return {collect, json_command, available:executor!=null};
}
return {identity, probe};
