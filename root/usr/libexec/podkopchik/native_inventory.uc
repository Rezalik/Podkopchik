'use strict';
const pool=require('native_pool'), awg=require('awg');
function uint(v) {
	if(type(v)=='int'&&v>=0&&v<=4294967295) return v;
	if(type(v)=='string'&&match(v,/^0x[0-9a-fA-F]{1,8}$/)) return hex(substr(v,2));
	if(type(v)=='string'&&match(v,/^[0-9]{1,10}$/)&&+v<=4294967295) return +v;
	return null;
}
function sockets(text,tcp) {
	if(type(text)!='string'||!match(text,/^[ \t]*sl[ \t]+local_address[ \t]+/)) return null;
	let ports={};
	for(let row in slice(split(trim(text),'\n'),1)) {
		let v=split(trim(row),/[ \t]+/), m=match(v[1] || '',/^[0-9A-Fa-f]+:([0-9A-Fa-f]{4})$/);
		if(!m||!match(v[3] || '',/^[0-9A-Fa-f]{2}$/)) return null;
		if(!tcp||v[3]=='0A') ports[hex(m[1])]=true;
	}
	return map(keys(ports),p=>+p);
}
function assess(v) {
	let issues={}, profiles={vless:0,amneziawg:0}, roles={main:0,backup:0,rules_only:0,other:0}, reserved=[], seen_tags={}, seen_ports={};
	function note(code) { issues[code]=(issues[code] || 0)+1; }
	function add_port(p) {
		if(seen_ports[p]) note('internal_port_overlap');
		seen_ports[p]=true;
	}
	let links=type(v?.addresses)=='array'?v.addresses:[], routes=type(v?.routes)=='array'?v.routes:[], rules=type(v?.rules)=='array'?v.rules:[];
	let lan=filter(links,l=>l.ifname==v?.lan), families={ipv4:0,ipv6:0};
	if(type(v?.lan)!='string'||!match(v.lan,/^[A-Za-z0-9_.-]{1,15}$/)||length(lan)!=1) note('lan_interface_not_identified');
	else for(let a in lan[0].addr_info || []) if(a.scope!='link'&&a.scope!='host'&&awg.ip(a.local)) {
		if(a.family=='inet') families.ipv4++;
		if(a.family=='inet6') families.ipv6++;
	}
	if(!families.ipv4&&!families.ipv6) note('lan_has_no_usable_address');
	let dns=uint(v?.dns_port);
	if(!dns||dns>65535) note('invalid_dns_port'); else add_port(dns);
	if(type(v?.profiles)!='array'||!length(v.profiles)||length(v.profiles)>64) note('profile_inventory_unavailable');
	else for(let p in v.profiles) {
		if(index(['vless','amneziawg'],p?.protocol)<0||!p.valid) { note('invalid_or_unsupported_profile'); continue; }
		profiles[p.protocol]++;
		roles[index(['main','backup','rules_only'],p.role)>=0?p.role:'other']++;
		if(seen_tags[p.tag]) note('duplicate_profile_tag');
		seen_tags[p.tag]=true;
		if(p.unresolved) note('named_endpoint_requires_resolution');
		if(p.protocol=='amneziawg') {
			if(!p.resource) note('invalid_awg_resource'); else push(reserved,p.resource);
			if(p.listen_port!=null) {
				let port=uint(p.listen_port);
				if(port==null||port>65535) note('invalid_awg_listen_port');
				else if(port) add_port(port);
			}
		}
	}
	// Check every slot: a saved VLESS registry may retain earlier allocations.
	if(profiles.vless) for(let i=0;i<32;i++) {
		add_port(23000+i); add_port(23032+i);
		push(reserved,{table:43000+i,priority:12000+i,mark:67109120+i});
	}
	let table_ids={}, priorities={}, marks={}, ifaces={};
	for(let r in reserved) {
		if(table_ids[r.table]||priorities[r.priority]||marks[r.mark]||r.interface&&ifaces[r.interface]) note('internal_namespace_overlap');
		table_ids[r.table]=true; priorities[r.priority]=true; marks[r.mark]=true;
		if(r.interface) ifaces[r.interface]=true;
	}
	if(type(v?.routes)!='array'||type(v?.rules)!='array'||type(v?.addresses)!='array') note('network_inventory_incomplete');
	for(let l in links) if(ifaces[l.ifname]) note('existing_awg_interface_requires_ownership_review');
	for(let r in routes) if(table_ids[uint(r.table)]) note('existing_route_table_requires_ownership_review');
	for(let r in rules) {
		let mark=uint(r.fwmark), mask=r.fwmask==null?4294967295:uint(r.fwmask);
		if(r.fwmark!=null&&(mark==null||mask==null)) { note('policy_mark_unreadable'); continue; }
		if(priorities[uint(r.priority)]||table_ids[uint(r.table)]||
			mark!=null&&length(filter(reserved,a=>(a.mark&mask)==(mark&mask)))) note('existing_policy_rule_requires_ownership_review');
	}
	if(type(v?.ports)!='array') note('socket_inventory_incomplete');
	else for(let p in v.ports) if(seen_ports[p]) note('occupied_listener_port');
	if(type(v?.nft_tables)!='array') note('nft_namespace_inventory_incomplete');
	else for(let t in v.nft_tables) if(t.family=='inet'&&index([
		'podkopchik_native','podkopchik_native_gate','podkopchik_native_transition','podkopchik_native_uninitialized'
	],t.name)>=0) note('existing_native_table_requires_ownership_review');
	if(v?.endpoint_inventory_complete!==true) note('endpoint_inventory_incomplete');
	if(type(v?.issued)!='array') note('issued_namespace_inventory_incomplete');
	if(type(v?.pools)!='array'||!length(v.pools)) note('native_pool_not_configured');
	else {
		let occupied;
		try { occupied=pool.inventory(v,true); }
		catch(e) { note('address_inventory_incomplete'); }
		if(occupied) for(let raw in v.pools) try {
			let cidr=pool.prefix(raw), private_pool=pool.private_v4(cidr)?cidr:null;
			if(!pool.allowed(cidr,private_pool)) note('native_pool_outside_supported_ranges');
			if(pool.overlaps(cidr,occupied)) note('native_pool_overlap_or_existing_ownership');
			push(occupied,cidr);
		} catch(e) { note('invalid_native_pool'); }
	}
	return {schema:1,status:length(keys(issues))?'review_required':'no_observed_conflicts',
		installation_authorized:false,activation_authorized:false,physical_acceptance:'not_assessed',
		lan_families:families,profiles,roles,issues,
		counts:{interfaces:length(links),routes:length(routes),policy_rules:length(rules),reserved_namespaces:length(reserved)},
		limits:['snapshot_only','no_endpoint_resolution','no_socket_ownership_attribution','apply_validation_still_required']};
}
return {sockets, assess};
