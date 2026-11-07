'use strict';
const assert = require('assert');
const {report}=require('../tools/native-observe-report.js');
const c={started_epoch:1794072100,deadline_epoch:1794244900,started_mono:100,interval:60};
const s={samples:2,last_epoch:1794072160,last:{uptime:160},pid_changes:1,resources:{fd:{min:11,max:20,n:2}},
	probes:{protected_dot:{ok:1,fail:1,max_consecutive_fail:1}},raw_dns:'private-client-query.invalid',password:'SENSITIVE_TEST_VALUE'};
const text=report(c,s);
assert(text.includes('продолжается'));
assert(text.includes('11–20'));
assert(text.includes('МСК'));
assert(text.includes('Смен PID DNS: 1'));
assert(!text.includes(s.raw_dns)&&!text.includes(s.password));
assert(!text.includes('завершён по дедлайну'));
assert(report(c,{...s,monitor_finished:true,complete:false}).includes('прерван'));
assert(report(c,{...s,monitor_finished:true,complete:true}).includes('завершён по дедлайну'));
console.log('PASS: private observation report, Moscow time, incomplete window and PID-change caveats');
