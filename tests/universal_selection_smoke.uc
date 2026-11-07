'use strict';

const s = require('universal_selection');
function ok(value) { if (!value) die('incorrect native transport decision'); }
const now = 1000, cooldown = 60;
const g = { mode: 'strict_primary', primary: 'a', backups: ['b', 'c'], auto_return: true };
ok(s.fresh({ status: 'up', probe_status: 'up', checked_at: 999 }, now));
ok(!s.fresh({ status: 'up', probe_status: 'up', checked_at: 700 }, now));
ok(!s.fresh({ status: 'up', probe_status: 'up', checked_at: 1001 }, now));
ok(!s.fresh({ status: 'up', probe_status: 'down', checked_at: 999 }, now));
ok(s.select(g, { a: true, b: true }, {}, now, cooldown).active == 'a');
ok(s.select(g, { b: true, c: true }, {}, now, cooldown).active == 'b');
ok(s.select(g, {}, { active_proxy: 'b', last_switch_time: 999 }, now, cooldown).active == 'blocked');
ok(s.select(g, { a: true, b: true }, { active_proxy: 'b', last_switch_time: 999 }, now, cooldown).active == 'b');
ok(s.select(g, { a: true, b: true }, { active_proxy: 'b', last_switch_time: 900 }, now, cooldown).active == 'a');
ok(s.select({ ...g, auto_return: false }, { a: true, b: true }, { active_proxy: 'b' }, now, cooldown).active == 'b');
ok(s.select(g, { a: true, rules_only: true }, { active_proxy: 'rules_only', last_switch_time: 999 }, now, cooldown).active == 'a');
ok(s.select({ ...g, manual_override_proxy: 'c' }, { a: true }, {}, now, cooldown).active == 'blocked');
ok(s.retained({status:'up',probe_status:'down',checked_at:999},now));
ok(!s.retained({status:'up',probe_status:'unknown',checked_at:999},now));
ok(!s.retained({status:'up',probe_status:'down',checked_at:700},now));
ok(s.select(g,{b:true},{active_proxy:'a'},now,cooldown,{a:true}).reason=='probe_hysteresis');
ok(s.select({...g,mode:'fixed_proxy',fixed_proxy:'a',failure_action:'block'},{},{active_proxy:'b'},now,cooldown,{b:true}).active=='blocked');
ok(s.select({...g,manual_override_proxy:'c'},{c:true},{active_proxy:'a'},now,cooldown,{a:true}).active=='c');
print('Native selection PASS: probe freshness, priorities, all-down, cooldown and role isolation\n');
