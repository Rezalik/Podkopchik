'use strict';
const platform=require('native_platform');
const fields=['distribution','release','target','architecture','machine','kernel'];
function fail(code) { die('Native package: '+code+'\n'); }
function target(catalog,id) {
	let t=catalog?.targets?.[id], p=platform.requirements();
	if (catalog?.schema!==1 || catalog.baseline!==p.baseline || !t ||
		!match(id || '',/^[a-z0-9]+$/) || !match(t.board || '',/^[a-z0-9,_.-]+$/) ||
		t.asset!=='podkopchik-native-'+id+'-candidate.tar.gz' ||
		index(['existing_rc','lab_candidate'],t.track)<0 || catalog.helper?.abi!=='linux-arm64' ||
		catalog.helper.capability_schema!==3) fail('unsupported_target_catalog');
	for (let k in fields) if (catalog.platform?.[k]!==p[k]) fail('catalog_baseline_mismatch');
	return t;
}
function device_target(catalog,os) {
	for (let k in fields) {
		if(k=='machine') continue; // Checked by the verified helper before static writes.
		if(os?.[k=='distribution'?'id':k]!==catalog.platform?.[k]) fail('unsupported_device_platform');
	}
	for (let id in keys(catalog.targets || {})) if(target(catalog,id).board===os.board) return id;
	fail('unsupported_board');
}
function validate(catalog,m) {
	let t=target(catalog,m?.target_id), h=m?.components?.helper;
	if (m?.schema!==2 || m.baseline!==catalog.baseline || m.platform?.board!==t.board ||
		m.asset!==t.asset || m.track!==t.track || m.activation!=='explicit-ordinary-apply' ||
		!match(m.components?.common?.sha256 || '',/^[a-f0-9]{64}$/) ||
		h?.abi!==catalog.helper.abi || h.capability_schema!==catalog.helper.capability_schema ||
		!match(h.sha256 || '',/^[a-f0-9]{64}$/) || h.path!=='native-bin/'+h.sha256) fail('invalid_platform_manifest');
	for (let k in fields) if (m.platform[k]!==catalog.platform[k]) fail('manifest_baseline_mismatch');
	return m;
}
function admit(catalog,m,inventory) {
	validate(catalog,m);
	if(device_target(catalog,inventory?.os)!==m.target_id) fail('package_target_mismatch');
	let report=platform.assess(inventory);
	if(report.status!=='requirements_met') fail(report.status+': '+join(', ',[...report.blockers,...report.unknown_checks]));
	return report;
}
return {target, device_target, validate, admit, fail};
