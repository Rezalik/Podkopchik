'use strict';
const assert=require('assert');
const {manifest,sums,verify,target}=require('../tools/native-package-manifest');
const digest='1'.repeat(64);
const all=[digest+'  ./root/a.uc',digest+'  ./i18n/ru/podkopchik.ru.lmo',
	digest+'  ./root/usr/libexec/podkopchik/podkopchik-native-dns',digest+'  ./native-bin/'+digest].join('\n')+'\n';
const common=sums(all), a=manifest('ax6000',digest,common), f=manifest('flint2',digest,common);
assert(!common.includes('native-bin') && !common.includes('native-dns'));
assert.deepStrictEqual(a.components,f.components);
assert.notStrictEqual(a.platform.board,f.platform.board);
assert.notStrictEqual(a.asset,f.asset);
assert.strictEqual(f.track,'lab_candidate');
assert.throws(()=>target('unlisted'));
assert.throws(()=>manifest('flint2','bad',common));
assert.throws(()=>sums('invalid'));
assert.throws(()=>verify(name=>Buffer.from(name==='./COMMON_SHA256SUMS'?common:
	JSON.stringify({...f,platform:a.platform})),all,digest),/Platform manifest mismatch/);
console.log('PASS: shared components, distinct targets and rejection of inconsistent platform metadata');
