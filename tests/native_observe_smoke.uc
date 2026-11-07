'use strict';
const m=require('native_observe_lib');
function ok(v,label){if(!v)die(label+'\n');}
ok(m.field('MemTotal: 1024 kB\nMemAvailable: 321 kB\n','MemAvailable')==321,'memory field extraction');
ok(m.field('VmRSS:\t13000 kB\n','VmRSS')==13000,'RSS field extraction');
let c=m.cpu('cpu  100 20 30 400 10 5 6 0 0 0\ncpu0 0 0 0 0\ncpu1 0 0 0 0\n');
ok(c.total==571&&c.idle==410&&c.cores==2,'CPU excludes double-counted guest ticks');
let p={pid:12,start_ticks:10,cpu_ticks:100},n={pid:12,start_ticks:10,cpu_ticks:120};
let d=m.cpu_delta({total:100,idle:20},{total:300,idle:120,cores:4},n,p);
ok(d.system_pct==50&&d.process_core_pct==40,'CPU percentages use shared kernel tick units');
let small=m.cpu_delta({total:100,idle:20},{total:1100,idle:919,cores:4},{...n,cpu_ticks:101},p);
ok(small.system_pct>10&&small.system_pct<11&&small.process_core_pct==0.4,'CPU does not truncate sub-percent load');
ok(m.cpu_delta({total:100,idle:20},{total:300,idle:120,cores:4},{...n,pid:13},p).process_core_pct==null,'PID changes invalidate CPU deltas');
ok(m.finished({boot:'one',deadline_mono:200},201,'one'),'fixed deadline');
ok(m.finished({boot:'one',deadline_mono:200},10,'two'),'reboot must not extend lifetime');
let s=null;
for(let i=0;i<10000;i++)s=m.aggregate(s,{epoch:1000+i,process:{pid:12,start_ticks:10,fd:11+i%8,udp:2,tcp:2,rss_kib:13000},
	cpu:{system_pct:20,process_core_pct:0.5},memory:{available_kib:200000},conntrack:{count:500},native:{active:i%3},
	probes:i%15==0?{dns_udp_tcp:i%30==0?'fail':'ok'}:{},warnings:i%30==0?['probe_dns_udp_tcp']:[]});
ok(s.samples==10000&&s.resources.fd.min==11&&s.resources.fd.max==18,'resource ranges retain the full window');
ok(s.resources.udp.min==2&&s.resources.udp.max==2,'UDP counters');
ok(length(s.events)==32&&length(sprintf('%J',s))<32768,'summary memory bounded independently of sample count');
ok(s.probes.dns_udp_tcp.ok+s.probes.dns_udp_tcp.fail==667,'probe totals survive log rotation');
ok(s.pid_changes==0,'stable process not counted as a restart');
for(let i=0;i<3;i++)s=m.aggregate(s,{epoch:12000+i,native:{active:1},connections:[{connection:1,status:'up',probe:'up',up:true,ifindex:i==2?4:3,rx_bytes:100+i*10,tx_bytes:200+i*10}],probes:{},warnings:[]});
ok(s.transports['1'].up==3&&s.transports['1'].rx_delta==10&&s.transports['1'].counter_resets==1,'transport history does not treat reset counters as negative traffic');
let files={},fake={lstat:p=>files[p]!=null?{size:length(files[p])}:null,unlink:p=>{delete files[p];},rename:(a,b)=>{files[b]=files[a];delete files[a];},open:p=>({write:line=>{files[p]=(files[p] || '')+line;},close:()=>true})};
for(let i=0;i<1000;i++)m.bounded_append(fake,'samples','bounded sample\n',128);
ok(length(keys(files))==2&&length(files.samples)<=128&&length(files['samples.1'])<=128,'actual log writer retains at most two bounded files');
print('PASS: bounded observation model, CPU, resource aggregation, probes and fixed deadline\n');
