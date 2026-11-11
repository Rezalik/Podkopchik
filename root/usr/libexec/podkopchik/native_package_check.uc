'use strict';
import * as fs from 'fs';
import {cursor} from 'uci';
const policy=require('native_package'), probe=require('native_platform_probe');
const action=ARGV[0], catalog_file=ARGV[1], base=ARGV[2];
function read(path,limit) {
	let s=fs.lstat(path);
	if(s?.type!='file'||s.uid!=0||s.nlink!=1||(s.mode&0o022)||s.size>limit) policy.fail('unsafe_package_file');
	let v=fs.readfile(path,limit+1);
	if(v==null||length(v)>limit) policy.fail('unreadable_package_file');
	return v;
}
function digest(path) {
	let p=fs.popen("sha256sum '"+replace(path,"'","'\\''")+"' 2>/dev/null",'r');
	if(!p) policy.fail('checksum_unavailable');
	let s=p.read(1024), rc=p.close(), m=match(s || '',/^([a-f0-9]{64})  /);
	if(rc!=0||!m) policy.fail('checksum_unavailable');
	return m[1];
}
if(!catalog_file) policy.fail('catalog_required');
const catalog=json(read(catalog_file,8192));
if(action=='device' && length(ARGV)==2) {
	let id=policy.device_target(catalog,probe.identity());
	printf('%s\n',id);
	return;
}
if(index(['verify','admit'],action)<0||length(ARGV)!=3||substr(base,0,1)!='/') policy.fail('invalid_package_check');
let m=policy.validate(catalog,json(read(base+'/PLATFORM.json',8192)));
if(action=='admit' && policy.device_target(catalog,probe.identity())!==m.target_id) policy.fail('package_target_mismatch');
let helper=base+'/'+m.components.helper.path, s=fs.lstat(helper);
if(s?.type!='file'||s.uid!=0||s.nlink!=1||(s.mode&0o022)||!(s.mode&0o111)||s.size<64||s.size>12582912) policy.fail('unsafe_helper');
let elf=fs.readfile(helper,20);
if(length(elf)!=20||substr(elf,0,4)!='\x7fELF'||ord(elf,4)!=2||ord(elf,5)!=1||
	ord(elf,18)!=183||ord(elf,19)!=0||digest(helper)!==m.components.helper.sha256||
	trim(read(base+'/NATIVE_DNS_SHA256',80))!==m.components.helper.sha256) policy.fail('helper_identity_mismatch');
let common=[], listed={};
for(let line in split(trim(read(base+'/SHA256SUMS',131072)),'\n')) {
	let v=match(line,/^[a-f0-9]{64}  (\.\/[A-Za-z0-9_.\/-]+)$/);
	if(!v||listed[v[1]]||index(split(substr(v[1],2),'/'),'..')>=0||
		index(split(substr(v[1],2),'/'),'.')>=0||index(v[1],'//')>=0) policy.fail('invalid_package_checksums');
	listed[v[1]]=true;
	if(v[1]!='./root/usr/libexec/podkopchik/podkopchik-native-dns' &&
		(index(v[1],'./root/')==0||index(v[1],'./i18n/')==0)) push(common,line);
}
sort(common);
if(!length(common)||read(base+'/COMMON_SHA256SUMS',131072)!==join('\n',common)+'\n'||
	digest(base+'/COMMON_SHA256SUMS')!==m.components.common.sha256) policy.fail('common_component_mismatch');
let launcher=read(base+'/root/usr/libexec/podkopchik/podkopchik-native-dns',1024);
if(launcher!=='#!/bin/sh\nset -eu\nexec "${PODKOPCHIK_CONFIG_DIR:-/etc/podkopchik}/native-bin/'+m.components.helper.sha256+'" "$@"\n') policy.fail('launcher_identity_mismatch');
if(action=='admit') {
	let c=cursor(), awg=false;
	if(!c.load('podkopchik')) policy.fail('podkopchik_configuration_unavailable');
	let recovery=c.get('podkopchik','main','native_recovery_policy');
	if(recovery&&recovery!='transactional') policy.fail('transactional_recovery_required');
	c.foreach('podkopchik','proxy',p=>{if(p.enabled!='0'&&p.protocol=='amneziawg') awg=true;});
	policy.admit(catalog,m,probe.probe(helper).collect(awg));
}
printf('Package target %s: %s (no activation)\n',m.target_id,action=='admit'?'prerequisites met':'manifest verified');
