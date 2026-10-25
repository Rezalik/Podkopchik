'use strict';
// Real native UCI/FS, MOCK network/apply, private config/savedir only.
import * as fs from 'fs';
import { cursor } from 'uci';
const awg = require('awg'), backend = require('awg_manage');
let work = ARGV[0];
if (!match(work || '', /^\/tmp\/podkopchik-awg-uci\.[a-zA-Z0-9]+$/) ||
	trim(fs.readfile('/tmp/sysinfo/board_name') || '') != 'xiaomi,redmi-router-ax6000-stock') die('wrong environment');
let pending = fs.lstat('/tmp/.uci/podkopchik');
if (pending && (pending.type != 'file' || pending.size > 0)) die('pending live UCI delta; isolated test refused');
fs.mkdir(work + '/savedir'); fs.mkdir(work + '/conf2');
let cfg = work + '/podkopchik', active = work + '/active.json';
fs.writefile(cfg, "config settings 'main'\n option enabled '1'\n option routing_enabled '1'\n" +
	"config proxy 'ibn_section'\n option enabled '1'\n option role 'main'\n option tag 'ibn'\n option uri 'SYNTHETIC_UNCHANGED'\n");
fs.writefile(active, '{"outbounds":[{"tag":"ibn","protocol":"vless"}]}');
fs.writefile(work + '/state.json', '{}');
let current = function() { return cursor(work, work + '/savedir', work + '/conf2'); };
let db = awg.store(work + '/profiles', 0), running = {}, apply_fail = false;
let profile = db.run('import', { name: 'Synthetic native UCI profile', config:
	'[Interface]\nPrivateKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=\nAddress = 10.66.0.2/32\nRandomTrailers = on\n[Peer]\nPublicKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=\nEndpoint = vpn.example:443\nAllowedIPs = 0.0.0.0/0\n'
}).connection;
let tag = 'awg_' + profile.id;
let manager = backend.create({ root: work + '/profiles', tmp: work, owner: 0, uci_file: cfg, active: active,
	cursor: current, store: db, traffic: function() { return {}; },
	network: { run: function(action, id) {
		if (action == 'start' || action == 'restart') running[id] = true;
		if (action == 'stop' || action == 'remove') running[id] = false;
		return { running: !!running[id], status: action == 'check' ? 'up' : 'down', checked_at: time(), latency_ms: 85 };
	} },
	shell: function(args) {
		if (index(join(' ', args), 'connection_check.sh') >= 0) return sprintf('%J', {status:'up',checked_at:time()});
		if (apply_fail) { apply_fail = false; awg.fail('apply_failed'); }
		let c = current(), out = [];
		c.foreach('podkopchik', 'proxy', function(p) { if(p.enabled!='0') push(out, {tag:p.tag,protocol:p.protocol||'vless'}); });
		fs.writefile(active, sprintf('%J', {outbounds:out}));
		return '';
	}
});
manager.run('assign', { tag: tag, role: 'main', priority: '' });
let c = current(), auto = null;
c.foreach('podkopchik', 'proxy_group', function(g) { if(g.tag=='auto_proxy_group')auto=g; });
if (c.get('podkopchik', tag, 'role') != 'main' || c.get('podkopchik', tag, 'enabled') != '1' || auto?.primary != tag)
	die('native UCI role/group commit failed');
if (c.get('podkopchik', 'ibn_section', 'uri') != 'SYNTHETIC_UNCHANGED') die('VLESS changed');
let before = fs.readfile(cfg), before_active = fs.readfile(active), before_state = fs.readfile(work + '/state.json');
apply_fail = true;
let failed = false;
try { manager.run('assign', {tag:'ibn',role:'main',priority:''}); } catch(e) { failed = awg.error(e).code == 'apply_failed'; }
if (!failed || fs.readfile(cfg)!=before || fs.readfile(active)!=before_active || fs.readfile(work+'/state.json')!=before_state)
	die('native UCI rollback failed');
manager.run('assign', { tag: 'ibn', role: 'main', priority: '' });
manager.run('assign', { tag: tag, role: 'disabled', priority: '' });
manager.run('stop', { id: profile.id });
manager.run('delete', { id: profile.id });
if (current().get('podkopchik', tag) != null || length(db.run('list', {}).connections) != 0) die('native UCI removal failed');
print('NATIVE_UCI_ROLE_GROUP_COMMIT_ROLLBACK_DELETE_PASS; NETWORK_AND_APPLY_MOCKED; PRIVATE_CONFIG_ONLY\n');
