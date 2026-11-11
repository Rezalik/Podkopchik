'use strict';
import {readfile} from 'fs';
const m=require('native_platform');
const baseline=json(readfile('tests/fixtures/native-platform-flint2.json'));
let assertions=0;
function ok(value,label) { assertions++; if (!value) die('FAIL: '+label+'\n'); }
function fixture() { return json(sprintf('%J',baseline)); }
function has(result,list,id) { return index(result[list],id)>=0; }
let before=sprintf('%J',baseline), result=m.assess(baseline);
ok(result.status=='requirements_met','Flint preliminary requirements');
ok(result.current_candidate.board_guard=='mismatch','Flint must still fail the AX6000 package board guard');
ok(!result.installation_authorized && !result.activation_authorized && result.physical_acceptance=='not_assessed','passing inventory never authorizes install or activation');
ok(sprintf('%J',baseline)==before,'assessment is pure');
let v=fixture();v.os.board='xiaomi,redmi-router-ax6000-stock';result=m.assess(v);
ok(result.status=='requirements_met' && result.current_candidate.board_guard=='match','AX6000 package identity is separate from requirements');
ok(!result.installation_authorized && result.physical_acceptance=='not_assessed','AX6000 inventory is not stability acceptance');
v=fixture();v.os.board='vendor,new-model';result=m.assess(v);
ok(result.status=='requirements_met' && result.current_candidate.board_guard=='mismatch','same capabilities do not imply package or model acceptance');
ok(m.assess({}).status=='incomplete','empty inventory is not success');
ok(m.assess([]).status=='incomplete','array inventory is not success');
v=fixture();v.schema='1';ok(has(m.assess(v),'unknown_checks','inventory_schema'),'schema type is strict');
v=fixture();v.schema=2;ok(has(m.assess(v),'blockers','inventory_schema'),'future inventory schema is refused');
for (let pair in [['release','24.10.4'],['target','ramips/mt7621'],['architecture','mipsel_24kc'],['machine','armv7l'],['kernel','6.6.110'],['id','VendorOS']]) {
	v=fixture();v.os[pair[0]]=pair[1];ok(has(m.assess(v),'blockers',pair[0]),'unvalidated baseline '+pair[0]);
}
for (let key in ['id','release','target','architecture','machine','kernel','board']) {
	v=fixture();delete v.os[key];ok(m.assess(v).status=='incomplete','missing identity '+key);
}
v=fixture();v.os.board='bad\nboard';ok(m.assess(v).device.board==null,'control characters are not reflected');
for (let name in m.requirements().commands) {
	v=fixture();v.commands[name]=false;ok(has(m.assess(v),'blockers','command_'+name),'missing required command '+name);
}
v=fixture();v.commands.nft='true';ok(has(m.assess(v),'unknown_checks','command_nft'),'command observation cannot be a truthy string');
v=fixture();v.commands=null;ok(m.assess(v).status=='incomplete','missing command inventory');
v=fixture();v.iproute2=false;ok(has(m.assess(v),'blockers','ip_full'),'BusyBox ip is not ip-full');
v=fixture();v.bounded_commands=false;ok(has(m.assess(v),'blockers','bounded_executor'),'incompatible command executor is not admitted');
v=fixture();delete v.bounded_commands;ok(has(m.assess(v),'unknown_checks','bounded_executor'),'missing command executor is not assumed available');
for (let key in ['software_offload','hardware_offload']) {
	v=fixture();v.firewall[key]=true;ok(has(m.assess(v),'blockers',key),'configured offload '+key);
	v.firewall[key]=null;ok(has(m.assess(v),'unknown_checks',key),'unreadable offload '+key);
}
v=fixture();v.firewall.flowtables=1;ok(has(m.assess(v),'blockers','live_flowtables'),'live offload blocks requirements');
for (let value in [null,'0',-1,0.5]) {
	v=fixture();v.firewall.flowtables=value;ok(has(m.assess(v),'unknown_checks','live_flowtables'),'invalid live flowtable observation');
}
v=fixture();v.firewall.fw4_table=false;ok(has(m.assess(v),'blockers','fw4_table'),'missing active firewall4');
for (let key in ['mem_available_kib','tmp_free_kib','overlay_free_kib']) {
	v=fixture();v.resources[key]=m.requirements()[key]-1;ok(has(m.assess(v),'blockers',key),'resource below floor '+key);
	v.resources[key]=m.requirements()[key];ok(m.assess(v).status=='requirements_met','resource exact floor '+key);
	for (let value in [null,'999999',-1,0.5]) {
		v=fixture();v.resources[key]=value;ok(has(m.assess(v),'unknown_checks',key),'invalid resource '+key);
	}
}
v=fixture();v.awg={requested:false,tools_31:false,loaded:false};ok(m.assess(v).status=='requirements_met','AWG optional for a VLESS-only assessment');
v=fixture();v.awg={};ok(has(m.assess(v),'unknown_checks','awg_request'),'AWG selection cannot be inferred from missing evidence');
for (let key in ['tools_31','loaded']) {
	v=fixture();v.awg[key]=false;ok(m.assess(v).status=='blocked','required AWG prerequisite '+key);
	v.awg[key]=null;ok(m.assess(v).status=='incomplete','unknown required AWG prerequisite '+key);
}
v=fixture();v.commands.nft=false;v.resources.mem_available_kib=null;result=m.assess(v);
ok(result.status=='blocked' && length(result.unknown_checks)>0,'known blockers take priority without hiding unknowns');
v=fixture();v.secret='DO_NOT_REFLECT';v.os.private_key='DO_NOT_REFLECT';v.profiles=[{uri:'DO_NOT_REFLECT'}];
ok(index(sprintf('%J',m.assess(v)),'DO_NOT_REFLECT')<0,'report projects only non-secret observations');
ok(m.flag(null)===false && m.flag('0')===false && m.flag('off')===false,'absent or disabled UCI offload');
ok(m.flag('1')===true && m.flag('true')===true,'enabled UCI offload');
ok(m.flag('invalid')==null && m.flag(0)==null && m.flag([])==null,'unrecognized UCI flags remain unknown');
let release="DISTRIB_ID='OpenWrt'\nDISTRIB_RELEASE='25.12.6'\nDISTRIB_TARGET='mediatek/filogic'\nDISTRIB_ARCH='aarch64_cortex-a53'\n";
ok(m.release(release).release=='25.12.6','release inventory parser');
ok(m.release("DISTRIB_RELEASE='25.12.6'; touch /tmp/forbidden").release==null,'release file is data, never shell code');
ok(m.release(release+"DISTRIB_RELEASE='25.12.6'\n").release==null,'duplicate release values refused');
ok(m.release(release+"DISTRIB_RELEASE='25.12.6'\nDISTRIB_RELEASE='25.12.6'\n").release==null,'third duplicate cannot repair ambiguous release');
let disk='Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/loop0 100000 10000 90000 10% /overlay\ntmpfs 200000 1000 199000 1% /tmp\n';
ok(m.space(disk,'/overlay')==90000 && m.space(disk,'/tmp')==199000,'resource inventory parser');
ok(m.space('tmpfs 1 1 0 100% /tmp','/tmp')==0,'zero space is known insufficient, not unknown');
ok(m.space('garbage','/tmp')==null && m.space(disk,'/missing')==null,'missing mount not accepted');
ok(m.memory('MemAvailable:   98304 kB\n')==98304 && m.memory('MemFree: 100000 kB\n')==null,'available memory, not MemFree');
printf('PASS: %d native platform assertions\n',assertions);
