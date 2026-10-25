'use strict';
const fs = require('fs'), cp = require('child_process'), path = require('path'), os = require('os'), assert = require('assert');
const ucode = process.env.UCODE || 'ucode';
if (cp.spawnSync(ucode, ['-h']).error) { console.log('SKIP: mixed generator tests need local ucode + fs'); process.exit(0); }
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'podkopchik-awg-gen-'));
const a = '11111111111111111111111111111111', b = '22222222222222222222222222222222';
const ta = 'awg_' + a, tb = 'awg_' + b, cfg = path.join(dir, 'uci.json');
const flags = ['-L', process.env.UCODE_MODULE_DIR || '/usr/lib/ucode', '-L', path.resolve('tests/ucode'), '-L', path.resolve('root/usr/libexec/podkopchik')];
const rows = [
	{'.type':'settings','.name':'main', fakedns_enabled:'1',fail_threshold:'2',restore_threshold:'2'},
	{'.type':'proxy','.name':'ibn',tag:'ibn',role:'main',enabled:'1',
		uri:'vless://11111111-2222-3333-4444-555555555555@203.0.113.1:443?type=tcp&security=reality&sni=example.invalid&pbk=AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE&sid=abcd'},
	{'.type':'proxy','.name':'a',tag:ta,protocol:'amneziawg',awg_id:a,enabled:'1'},
	{'.type':'proxy','.name':'b',tag:tb,protocol:'amneziawg',awg_id:b,enabled:'1'},
	{'.type':'proxy_group','.name':'auto',tag:'auto_proxy_group',enabled:'1',mode:'strict_primary',primary:'ibn',backup1:ta,backup2:tb,auto_return:'1'},
	{'.type':'domain_rule','.name':'yt',domain:['youtube.com','googlevideo.com'],target:'auto_proxy_group',enabled:'1'},
	{'.type':'domain_rule','.name':'x',domain:['x.com','twitter.com','pbs.twimg.com'],target:ta,enabled:'1'},
	{'.type':'ip_rule','.name':'telegram',cidr:'149.154.160.0/20',target:tb,enabled:'1'},
	{'.type':'lan_device','.name':'tablet',source_ip:'192.168.1.50',mode:'full_proxy',target:ta,enabled:'1'}
];
function saveRows() { fs.writeFileSync(cfg, JSON.stringify(rows)); }
function run(mode, file, state) {
	const r = cp.spawnSync(ucode, flags.concat(['root/usr/libexec/podkopchik/generate.uc',mode,file,...(state ? [state] : [])]), {
		encoding:'utf8', env:{...process.env,PODKOPCHIK_TEST_UCI:cfg}
	});
	assert.strictEqual(r.status,0,r.stderr); return JSON.parse(r.stdout);
}
function stateFile(value) { const file=path.join(dir,'state.json');fs.writeFileSync(file,JSON.stringify(value));return file; }
let state = {proxies:{ibn:{status:'up'},[ta]:{status:'up'},[tb]:{status:'up'}},groups:{auto_proxy_group:{active_proxy:'ibn'}}};
function probe(status) {
	const file=path.join(dir,'results.tsv');
	fs.writeFileSync(file,Object.entries(status).map(([tag,value])=>[tag,value,'',85,'192.0.2.8',Math.floor(Date.now()/1000)].join('\t')).join('\n'));
	state=run('state',file,stateFile(state));return state.groups.auto_proxy_group.active_proxy;
}
try {
	saveRows();
	const savedState = structuredClone(state);
	state = {proxies:{ibn:{status:'down',fail_count:2},[ta]:{status:'up',success_count:2},[tb]:{status:'up',success_count:2}},groups:{}};
	assert.strictEqual(probe({ibn:'down',[ta]:'up',[tb]:'up'}),ta);
	assert(state.events.some(x=>x.includes('switched from ibn to '+ta)),'first post-boot backup selection must trigger runtime apply');
	state = savedState;
	let config=run('config-state',stateFile(state));
	for(const domain of ['youtube.com','googlevideo.com','x.com','twitter.com','pbs.twimg.com'])
		assert(config.routing.rules.some(r=>r.domain?.includes('domain:'+domain)));
	assert(config.routing.rules.some(r=>r.ip?.includes('149.154.160.0/20')&&r.outboundTag===tb));
	assert(config.routing.rules.some(r=>r.source?.includes('192.168.1.50/32')&&r.outboundTag===ta));
	assert.strictEqual(config.outbounds.find(x=>x.tag===ta).protocol,'blackhole','unstarted AWG is never plain WAN freedom');
	assert(config.dns.servers.includes('fakedns')&&config.dns.servers.includes('tcp://1.1.1.1'));
	assert(config.routing.rules.some(x=>x.inboundTag?.includes('awg-resolver')&&x.outboundTag==='ibn'));
	assert(!config.routing.rules.some(x=>x.ip?.includes('198.18.0.0/15')));
	assert.strictEqual(config.fakedns.ipPool,'198.18.0.0/15');
	assert.strictEqual(config.api.tag,'podkopchik-api');
	assert.strictEqual(config.inbounds.find(x=>x.port===10085).listen,'127.0.0.1');
	assert.strictEqual(probe({ibn:'down',[ta]:'up',[tb]:'up'}),'ibn','failure threshold retained');
	assert.strictEqual(probe({ibn:'down',[ta]:'up',[tb]:'up'}),ta,'VLESS to AWG');
	probe({ibn:'down',[ta]:'down',[tb]:'up'});
	assert.strictEqual(probe({ibn:'down',[ta]:'down',[tb]:'up'}),tb,'AWG to AWG');
	probe({ibn:'down',[ta]:'down',[tb]:'down'});
	assert.strictEqual(probe({ibn:'down',[ta]:'down',[tb]:'down'}),'blocked','all-down is fail-closed');
	config=run('config-state',stateFile(state));
	assert(config.routing.rules.some(x=>x.domain?.includes('domain:youtube.com')&&x.outboundTag==='blocked'));
	state.proxies[tb]={status:'up',checked_at:Math.floor(Date.now()/1000)};
	let independent=run('config-state',stateFile(state));
	assert(independent.routing.rules.some(x=>x.inboundTag?.includes('awg-resolver')&&x.outboundTag===tb),'independent healthy target can resolve with automatic group blocked');
	assert(independent.routing.rules.some(x=>x.domain?.includes('domain:youtube.com')&&x.outboundTag==='blocked'),'DNS fallback never unblocks automatic data routing');
	state.proxies[tb]={status:'down'};
	assert.strictEqual(probe({ibn:'up',[ta]:'down',[tb]:'down'}),'blocked','restore threshold retained');
	assert.strictEqual(probe({ibn:'up',[ta]:'down',[tb]:'down'}),'ibn','AWG to VLESS / automatic return');
	rows[0].extended_interception='1';saveRows();
	config=run('config-state',stateFile(state));
	assert.deepStrictEqual(config.fakedns.map(x=>x.ipPool),['198.18.0.0/15','2001:2::/48']);
	assert.strictEqual(config.dns.queryStrategy,'UseIP');
	rows.push({...rows[1],'.name':'legacy_awg_named_vless',tag:'awg_existing_vless',role:'rules_only'});saveRows();
	config=run('config-state',stateFile(state));
	assert.strictEqual(config.outbounds.find(x=>x.tag==='awg_existing_vless').protocol,'vless','legacy VLESS tags may use awg_ without a profile ID');
	const r = cp.spawnSync(ucode, flags.concat(['-e','const n=require("awg_network"); printf("%J", n.outbound(n.resources("'+a+'"), true, "10.66.0.2/32, fd00::2/128"));']),{encoding:'utf8'});
	assert.strictEqual(r.status,0,r.stderr);
	const outbound=JSON.parse(r.stdout);
	assert.strictEqual(outbound.protocol,'freedom');
	assert.strictEqual(outbound.streamSettings.sockopt.domainStrategy,'ForceIP');
	assert(outbound.streamSettings.sockopt.interface.startsWith('paw'));
	assert(outbound.streamSettings.sockopt.mark!==0x100000);
	config.outbounds=config.outbounds.map(x=>x.tag===ta?outbound:x);
	if(process.env.PODKOPCHIK_AWG_VALIDATION_CONFIG) fs.writeFileSync(process.env.PODKOPCHIK_AWG_VALIDATION_CONFIG,JSON.stringify(config),{mode:0o600});
	console.log('Native mixed generator/failover MOCK integration OK: domain/IP/LAN, dual FakeDNS, VLESS/AWG/AWG, all-down, restore thresholds');
} finally { fs.rmSync(dir,{recursive:true,force:true}); }
