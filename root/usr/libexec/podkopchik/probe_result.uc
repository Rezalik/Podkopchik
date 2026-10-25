#!/usr/bin/env ucode
'use strict';
import { readfile } from 'fs';
let ip = trim(readfile(ARGV[0]) || '');
let parts = split(ip, '.');
if (length(parts) != 4)
	die('invalid IPv4 result');
for (let p in parts)
	if (!match(p, /^[0-9]{1,3}$/) || int(p) > 255)
		die('invalid IPv4 result');
print(ip);
