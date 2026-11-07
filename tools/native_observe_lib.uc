'use strict';

function words(s) { return split(trim(s || ''), /[ \t\r\n]+/); }
function number(s, fallback) { return match(''+s, /^[0-9]+$/) ? +s : (fallback ?? 0); }
function field(text, name) { for(let line in split(text || '', '\n')){let v=words(line);if(v[0]==name+':')return number(v[1]);}return 0; }
function cpu(text) {
	let rows=split(text || '', '\n'),v=words(rows[0]),total=0,cores=0;
	for(let i=1;i<=8;i++)total+=+(v[i] || 0);
	for(let row in rows)if(match(row,/^cpu[0-9]+[ \t]/))cores++;
	return {total,idle:+(v[4] || 0)+ +(v[5] || 0),cores};
}
function cpu_delta(previous, current, process, old_process) {
	let dt=current.total-(previous?.total ?? current.total),idle=current.idle-(previous?.idle ?? current.idle);
	let same=process?.pid && process.pid==old_process?.pid && process.start_ticks==old_process?.start_ticks;
	return {precision:'fractional',system_pct:dt>0?max(0,min(100,100.0*(dt-idle)/dt)):null,
		process_core_pct:dt>0 && same?max(0,100.0*current.cores*(process.cpu_ticks-old_process.cpu_ticks)/dt):null};
}
function process_stat(text) {
	let v=words(replace(text || '', /^[0-9]+ [(].*[)] /, ''));
	return {cpu_ticks:+(v[11] || 0)+ +(v[12] || 0),start_ticks:+(v[19] || 0)};
}
function range(old, value) {
	if(type(value)!='int' && type(value)!='double')return old;
	if(!old)return {min:value,max:value,first:value,last:value,sum:value,n:1};
	return {...old,min:min(old.min,value),max:max(old.max,value),last:value,sum:old.sum+value,n:old.n+1};
}
function aggregate(old, sample) {
	let s={schema:1,samples:0,started_epoch:sample.epoch,resources:{},probes:{},transports:{},events:[],warnings:{},pid_changes:0,active_changes:0,switch_timestamp_changes:0,...(old || {})};
	let previous=s.last;
	s.samples++;s.last_epoch=sample.epoch;s.last=sample;
	if(sample.cpu?.precision=='fractional' && sample.cpu.system_pct!=null)s.cpu_fractional_samples=(s.cpu_fractional_samples || 0)+1;
	for(let k,v in {fd:sample.process?.fd,udp:sample.process?.udp,tcp:sample.process?.tcp,rss_kib:sample.process?.rss_kib,
		cpu_pct:sample.cpu?.system_pct,dns_cpu_core_pct:sample.cpu?.process_core_pct,mem_available_kib:sample.memory?.available_kib,conntrack:sample.conntrack?.count})
		s.resources[k]=range(s.resources[k],v);
	let identity=sample.process?.pid?sample.process.pid+':'+sample.process.start_ticks:null;
	if(identity && s.last_pid && identity!=s.last_pid){s.pid_changes++;push(s.events,{epoch:sample.epoch,event:'dns_pid_changed'});}
	if(identity)s.last_pid=identity;
	if(s.last_active!=null && sample.native.active!=s.last_active){s.active_changes++;push(s.events,{epoch:sample.epoch,event:'active_transport_changed'});}
	s.last_active=sample.native.active;
	if(previous?.native?.health_switch_epoch && sample.native.health_switch_epoch && previous.native.health_switch_epoch!=sample.native.health_switch_epoch)s.switch_timestamp_changes++;
	for(let row in (sample.connections || [])){
		let key=''+row.connection,t=s.transports[key] || {samples:0,up:0,down:0,unknown:0,link_missing:0,probe_down:0,counter_resets:0,rx_delta:0,tx_delta:0};
		t.samples++;t[row.status]++;if(row.up===false)t.link_missing++;if(row.probe=='down')t.probe_down++;
		t.latency_ms=range(t.latency_ms,row.latency_ms);t.handshake_age=range(t.handshake_age,row.handshake_age);t.health_age=range(t.health_age,row.age);
		if(t.last_index && row.ifindex && (row.ifindex!=t.last_index || row.rx_bytes<t.rx_last || row.tx_bytes<t.tx_last))t.counter_resets++;
		else if(t.last_index){t.rx_delta+=max(0,row.rx_bytes-t.rx_last);t.tx_delta+=max(0,row.tx_bytes-t.tx_last);}
		t.last_index=row.ifindex;t.rx_last=row.rx_bytes;t.tx_last=row.tx_bytes;s.transports[key]=t;
	}
	for(let name,result in (sample.probes || {})){
		let p=s.probes[name] || {ok:0,fail:0,skipped:0,consecutive_fail:0,max_consecutive_fail:0};
		p[result]++;p.last=result;p.checked_epoch=sample.epoch;
		p.consecutive_fail=result=='fail'?p.consecutive_fail+1:0;
		p.max_consecutive_fail=max(p.max_consecutive_fail,p.consecutive_fail);s.probes[name]=p;
	}
	for(let name in (sample.warnings || []))s.warnings[name]=(s.warnings[name] || 0)+1;
	if(length(s.events)>32)s.events=slice(s.events,-32);
	return s;
}
function finished(config, now, boot) {
	return boot!=config.boot || now>=config.deadline_mono;
}
function bounded_append(fs, path, line, limit) {
	if(length(line)>limit)die('oversized observation record');
	if((fs.lstat(path)?.size || 0)+length(line)>limit){fs.unlink(path+'.1');if(fs.lstat(path))fs.rename(path,path+'.1');}
	let f=fs.open(path,'a',0o600);if(!f)die('observation log unavailable');f.write(line);f.close();
}
return {words,number,field,cpu,cpu_delta,process_stat,range,aggregate,finished,bounded_append};
