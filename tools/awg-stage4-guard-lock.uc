'use strict';
import * as fs from 'fs';
let mode=ARGV[0], dir=ARGV[1];
if (!match(dir || '', /^\/root\/podkopchik-stage4-[A-Za-z0-9._-]+$/) || index(['restore','commit'],mode)<0) exit(1);
let parent=fs.lstat(dir), path=dir+'/action.lock', old=fs.lstat(path);
if (!parent || parent.type!='directory' || parent.uid!=0 || (parent.mode&0o077)) exit(1);
if (old && (old.type!='file' || old.uid!=0 || (old.mode&0o077) || old.nlink!=1)) exit(1);
let lock=fs.open(path,'a+',0o600);
if (!lock || !lock.lock('xn')) exit(75);
if (mode=='commit') {
	if (fs.lstat(dir+'/restored') || fs.lstat(dir+'/restore-failed') || fs.lstat(dir+'/recover-now')) exit(1);
	if (!fs.writefile(dir+'/committed',''+time()+'\n')) exit(1);
}
else if (!fs.lstat(dir+'/committed') && !fs.lstat(dir+'/restored')) {
	// Restricted fixed paths only; the OS releases flock if either process dies.
	let p=fs.popen('/bin/sh '+dir+'/watchdog.sh restore-locked '+dir, 'r');
	let ok=false;
	if (p) { let out=p.read('all'); if(out) warn(out); ok=p.close()==0; }
	fs.writefile(dir+(ok?'/restored':'/restore-failed'),''+time()+'\n');
	if (!ok) exit(1);
}
lock.close();
