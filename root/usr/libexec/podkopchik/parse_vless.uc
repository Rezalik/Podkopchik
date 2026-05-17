#!/usr/bin/env ucode
'use strict';

push(REQUIRE_SEARCH_PATH, '/usr/libexec/podkopchik/*.uc');
push(REQUIRE_SEARCH_PATH, './root/usr/libexec/podkopchik/*.uc');

const vless = require('vless');

if (length(ARGV) != 1) {
	die('usage: parse_vless.uc <vless-uri>');
}

let parsed = vless.parse(ARGV[0]);
printf('%J\n', parsed);
