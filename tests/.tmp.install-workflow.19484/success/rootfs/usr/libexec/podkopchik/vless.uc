'use strict';

function urldecode(s) {
	if (s == null)
		return '';

	s = replace('' + s, '+', ' ');

	return replace(s, /%([0-9A-Fa-f][0-9A-Fa-f])/g, function(m, h) {
		return chr(hex(h));
	});
}

function clean_tag(s, fallback) {
	let t = replace(lc('' + (s || fallback || 'podkopchik')), /[^a-z0-9_]+/g, '_');
	t = trim(t, '_');

	if (!length(t))
		t = fallback || 'podkopchik';

	if (!match(t, /^[a-z_]/))
		t = 'p_' + t;

	return substr(t, 0, 48);
}

function query_params(qs) {
	let q = {};

	if (!qs)
		return q;

	for (let p in split(qs, '&')) {
		if (!length(p))
			continue;

		let kv = split(p, '=', 2);
		let k = urldecode(kv[0]);
		let v = length(kv) > 1 ? urldecode(kv[1]) : '';

		if (length(k))
			q[k] = v;
	}

	return q;
}

function require_value(v, name) {
	if (v == null || !length('' + v))
		die('missing required VLESS ' + name);

	return '' + v;
}

function strip_hostport_tail(hostport) {
	let end = length(hostport);

	for (let sep in [ '/', '?', '#' ]) {
		let pos = index(hostport, sep);

		if (pos >= 0 && pos < end)
			end = pos;
	}

	return substr(hostport, 0, end);
}

function parse_host_port(hostport) {
	let host, port;

	hostport = strip_hostport_tail(hostport);

	if (substr(hostport, 0, 1) == '[') {
		let end = index(hostport, ']');

		if (end < 0)
			die('invalid IPv6 host in VLESS URI');

		host = substr(hostport, 1, end - 1);

		if (substr(hostport, end + 1, 1) != ':')
			die('missing port in VLESS URI');

		port = substr(hostport, end + 2);
	}
	else {
		let pos = rindex(hostport, ':');

		if (pos <= 0)
			die('missing host or port in VLESS URI');

		host = substr(hostport, 0, pos);
		port = substr(hostport, pos + 1);
	}

	if (!length(host))
		die('missing host in VLESS URI');

	if (!match(port, /^[0-9]+$/) || int(port) < 1 || int(port) > 65535)
		die('invalid port in VLESS URI');

	return [ host, int(port) ];
}

function parse(uri) {
	if (uri == null || substr(uri, 0, 8) != 'vless://')
		die('URI must start with vless://');

	let rest = substr(uri, 8);
	let fp = split(rest, '#', 2);
	let name = length(fp) > 1 ? urldecode(fp[1]) : '';
	let mp = split(fp[0], '?', 2);
	let path_start = index(mp[0], '/');
	let uri_path = path_start >= 0 ? substr(mp[0], path_start) : '';
	let auth = path_start >= 0 ? substr(mp[0], 0, path_start) : mp[0];
	let params = query_params(length(mp) > 1 ? mp[1] : '');
	let at = index(auth, '@');

	if (at <= 0)
		die('missing UUID or server in VLESS URI');

	let uuid = substr(auth, 0, at);
	let hp = parse_host_port(substr(auth, at + 1));
	let network = lc(params.type || params.network || 'tcp');
	let security = lc(params.security || '');

	if (!match(uuid, /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/))
		die('invalid VLESS UUID');

	if (network != 'tcp' && network != 'xhttp')
		die('unsupported VLESS transport: ' + network);

	if (security != 'reality')
		die('unsupported VLESS security: ' + security);

	let server_name = params.sni || params.serverName || params.servername;
	let public_key = params.pbk || params.publicKey || params.publickey;
	let short_id = params.sid || params.shortId || params.shortid || '';
	let fingerprint = params.fp || params.fingerprint || 'chrome';

	require_value(server_name, 'serverName/sni');
	require_value(public_key, 'publicKey/pbk');

	return {
		uuid: uuid,
		host: hp[0],
		address: hp[0],
		port: hp[1],
		network: network,
		security: security,
		serverName: server_name,
		publicKey: public_key,
		shortId: short_id,
		fingerprint: fingerprint,
		flow: params.flow || null,
		path: params.path ? urldecode(params.path) : (length(uri_path) ? urldecode(uri_path) : null),
		headerHost: params.host ? urldecode(params.host) : null,
		name: name
	};
}

return {
	parse: parse,
	clean_tag: clean_tag,
	urldecode: urldecode
};
