'use strict';
import * as fs from 'fs';
const platform=require('native_platform'), probe=require('native_platform_probe');
let fixture=null, awg=false, helper_selected=false, helper='/usr/libexec/podkopchik/podkopchik-native-dns';
for (let i=0;i<length(ARGV);i++) {
	if (ARGV[i]=='--awg') awg=true;
	else if (ARGV[i]=='--fixture' && fixture==null && i+1<length(ARGV)) fixture=ARGV[++i];
	else if (ARGV[i]=='--helper' && !helper_selected && i+1<length(ARGV)) { helper=ARGV[++i]; helper_selected=true; }
	else die('Usage: native_platform_check.uc [--awg] [--helper VERIFIED_HELPER] | --fixture INVENTORY.json\n');
}
if (fixture && (awg || helper_selected)) die('Fixture contains its own capability observations\n');
let inventory;
if (fixture) {
	let stat=fs.lstat(fixture);
	if (stat?.type!='file' || stat.size>65536) die('Invalid inventory fixture\n');
	inventory=json(fs.readfile(fixture,65537));
} else inventory=probe.probe(helper).collect(awg);
let result=platform.assess(inventory);
result.source=fixture?'fixture':'live_read_only';
printf('%J\n',result);
exit(result.status=='requirements_met'?0:result.status=='blocked'?2:3);
