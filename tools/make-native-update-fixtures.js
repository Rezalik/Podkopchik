'use strict';
// Workstation-only adversarial tar fixtures for the installed ucode validator.
const fs = require('fs'), zlib = require('zlib'), path = require('path'), crypto = require('crypto');
const out = process.argv[2];
fs.mkdirSync(out, {recursive:true});
function header(name, options = {}) {
 const h = Buffer.alloc(512);
 const oct = (n, size) => n.toString(8).padStart(size - 1, '0') + '\0';
 h.write(name); h.write(oct(options.mode ?? 0o644, 8), 100);
 h.write(oct(options.uid ?? 0, 8), 108); h.write(oct(0, 8), 116);
 h.write(oct(options.size ?? 0, 12), 124); h.write(oct(0, 12), 136);
 h.fill(32, 148, 156); h.write(options.type || '0', 156);
 if (options.link) h.write(options.link, 157);
 h.write('ustar\0', 257); h.write('00', 263);
 const sum = h.reduce((a,b) => a+b, 0);
 h.write(sum.toString(8).padStart(6, '0') + '\0 ', 148);
 return h;
}
const files = ['./SHA256SUMS', './TARGET', './NATIVE_DNS_SHA256', './install-native-dns.sh', './tools/install-native-rc-files.sh'];
const sums = Buffer.from(files.slice(1).map(n => crypto.createHash('sha256').update('').digest('hex')+'  '+n+'\n').join(''));
const base = [header('./SHA256SUMS', {size:sums.length}), Buffer.concat([sums,Buffer.alloc((512-sums.length%512)%512)]), ...files.slice(1).map(n => header(n))], end = Buffer.alloc(1024);
function write(name, blocks) { fs.writeFileSync(path.join(out, name+'.tar.gz'), zlib.gzipSync(Buffer.concat(blocks))); }
write('valid', [...base, end]);
write('traversal', [header('./../outside'), end]);
write('absolute', [header('/etc/config/network'), end]);
write('symlink', [header('./link', {type:'2',link:'/etc'}), end]);
write('hardlink', [header('./link', {type:'1',link:'./TARGET'}), end]);
write('owner', [header('./TARGET', {uid:501}), end]);
write('writable', [header('./TARGET', {mode:0o666}), end]);
write('setuid', [header('./TARGET', {mode:0o4755}), end]);
write('duplicate', [...base, base[0], end]);
write('alias', [header('././TARGET'), ...base, end]);
write('large', [header('./huge', {size:25*1024*1024}), end]);
write('truncated', [header('./TARGET', {size:100})]);
const corrupt = Buffer.from(base[0]); corrupt[0] = 42;
write('checksum', [corrupt, end]);
write('trailer', [...base, end, header('./hidden'), end]);
write('missing', [base[0], end]);
write('unmanifested', [...base, header('./extra'), end]);
const repo = 'Rezalik/Podkopchik';
function release(tag, date, changes = {}) {
 return {tag_name:tag, prerelease:true, draft:false, published_at:date,
  assets:[{name:'podkopchik-native-ax6000-candidate.tar.gz',size:100,digest:'sha256:'+'1'.repeat(64),
   browser_download_url:`https://github.com/${repo}/releases/download/${tag}/podkopchik-native-ax6000-candidate.tar.gz`}], ...changes};
}
const old = release('native-rc-old','2026-11-01'), latest = release('native-rc-new','2026-11-08');
fs.writeFileSync(path.join(out,'releases.json'),JSON.stringify([old,release('native-rc-draft','2026-11-09',{draft:true}),latest,release('v9','2026-11-10',{prerelease:false})]));
fs.writeFileSync(path.join(out,'bad-releases.json'),JSON.stringify([release('native-rc-bad','2026-11-09',{assets:[{...latest.assets[0],digest:null}]})]));
const flint='podkopchik-native-flint2-candidate.tar.gz', flintTag='native-rc-flint-lab';
fs.writeFileSync(path.join(out,'releases-flint2.json'),JSON.stringify([latest,
	release(flintTag,'2026-11-07',{assets:[{...latest.assets[0],name:flint,
		browser_download_url:`https://github.com/${repo}/releases/download/${flintTag}/${flint}`}]})]));
