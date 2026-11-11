'use strict';

function requirements() {
	return { schema:1, baseline:'filogic-arm64-25.12.6-v1', distribution:'OpenWrt', release:'25.12.6',
		target:'mediatek/filogic', architecture:'aarch64_cortex-a53', machine:'aarch64', kernel:'6.12.112',
		mem_available_kib:98304, tmp_free_kib:65536, overlay_free_kib:24576,
		commands:['ip','nft','fw4','ucode','uci','ubus','jsonfilter','sha256sum','curl','dnsmasq','xray','rpcd','uhttpd'] };
}
function object(v) { return type(v)=='object' ? v : {}; }
function text(v) { return type(v)=='string' && length(v)>0 && length(v)<=128 && !!match(v,/^[A-Za-z0-9,._\/+:-]+$/) ? v : null; }
function number(v) { return type(v)=='int' && v>=0 ? v : null; }
function flag(v) {
	if (v==null) return false;
	if (type(v)!='string') return null;
	if (index(['0','false','no','off'],v)>=0) return false;
	if (index(['1','true','yes','on'],v)>=0) return true;
	return null;
}
function release(text) {
	let out={}, seen={}, names={DISTRIB_ID:'id',DISTRIB_RELEASE:'release',DISTRIB_TARGET:'target',DISTRIB_ARCH:'architecture'};
	for (let line in split(text || '', '\n')) {
		let key=split(line,'=')[0];
		if (!names[key]) continue;
		let m=match(line,/^(DISTRIB_ID|DISTRIB_RELEASE|DISTRIB_TARGET|DISTRIB_ARCH)='([A-Za-z0-9._\/+:-]+)'$/);
		out[names[key]]=m && !seen[key] ? m[2] : null;
		seen[key]=true;
	}
	return out;
}
function space(text, mount) {
	for (let row in split(text || '', '\n')) {
		let cols=split(trim(row),/[ \t]+/);
		if (length(cols)==6 && cols[5]==mount && match(cols[3],/^[0-9]+$/)) return +cols[3];
	}
	return null;
}
function memory(text) {
	for (let row in split(text || '', '\n')) {
		let m=match(row,/^MemAvailable:[ \t]+([0-9]+)[ \t]+kB$/);
		if (m) return +m[1];
	}
	return null;
}
function assess(input) {
	let v=object(input), os=object(v.os), commands=object(v.commands), fw=object(v.firewall), resources=object(v.resources), awg=object(v.awg);
	let policy=requirements(), checks=[];
	function check(id, actual, expected, reason) {
		push(checks,{id,status:actual==null?'unknown':actual==expected?'pass':'fail',reason,
			observed:actual,required:expected});
	}
	check('inventory_schema',number(v.schema),1,'inventory_schema_required');
	for (let key in ['id','release','target','architecture','machine','kernel'])
		check(key,text(os[key]),policy[key=='id'?'distribution':key],'baseline_not_validated');
	let board=text(os.board);
	check('board_identified',board==null?null:true,true,'board_identity_required');
	for (let name in policy.commands)
		check('command_'+name,type(commands[name])=='bool'?commands[name]:null,true,'required_command_missing');
	check('ip_full',type(v.iproute2)=='bool'?v.iproute2:null,true,'iproute2_required');
	check('bounded_executor',type(v.bounded_commands)=='bool'?v.bounded_commands:null,true,'verified_bounded_helper_required');
	for (let key in ['software_offload','hardware_offload'])
		check(key,type(fw[key])=='bool'?fw[key]:null,false,'offload_must_be_disabled');
	check('live_flowtables',number(fw.flowtables),0,'live_flowtable_prevents_native');
	check('fw4_table',type(fw.fw4_table)=='bool'?fw.fw4_table:null,true,'active_firewall4_required');
	for (let key in ['mem_available_kib','tmp_free_kib','overlay_free_kib']) {
		let value=number(resources[key]);
		check(key,value==null?null:value>=policy[key],true,'insufficient_resource_floor');
		checks[length(checks)-1].observed_kib=value;
		checks[length(checks)-1].minimum_kib=policy[key];
	}
	check('awg_request',type(awg.requested)=='bool'?true:null,true,'awg_requirement_must_be_explicit');
	if (awg.requested===true) {
		check('awg_tools_31',type(awg.tools_31)=='bool'?awg.tools_31:null,true,'awg_31_required');
		check('awg_module_loaded',type(awg.loaded)=='bool'?awg.loaded:null,true,'matching_loaded_awg_required');
	}
	let failed=map(filter(checks,c=>c.status=='fail'),c=>c.id), unknown=map(filter(checks,c=>c.status=='unknown'),c=>c.id);
	return {schema:1,baseline:policy.baseline,status:length(failed)?'blocked':length(unknown)?'incomplete':'requirements_met',
		device:{board,distribution:text(os.id),release:text(os.release),target:text(os.target),architecture:text(os.architecture),machine:text(os.machine),kernel:text(os.kernel)},
		checks,blockers:failed,unknown_checks:unknown,
		requested_capabilities:{awg:type(awg.requested)=='bool'?awg.requested:null},
		current_candidate:{target_board:'xiaomi,redmi-router-ax6000-stock',board_guard:board==null?'unknown':board=='xiaomi,redmi-router-ax6000-stock'?'match':'mismatch'},
		installation_authorized:false,activation_authorized:false,physical_acceptance:'not_assessed',
		limitations:['preliminary_inventory_only','exact_package_and_generation_budget_required','kernel_rule_validation_required',
			'profile_and_network_admission_required','physical_dns_https_udp_failover_acceptance_required']};
}
return {requirements,assess,flag,release,space,memory};
