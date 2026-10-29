'use strict';

const awg = require('awg');

function settings(main) {
	main = main || {};
	// Old explicit opt-in remains readable until either new flag is saved.
	let legacy = main.extended_interception == '1';
	return {
		udp: exists(main, 'udp_interception') ? main.udp_interception == '1' : legacy,
		ipv6: exists(main, 'ipv6_interception') ? main.ipv6_interception == '1' : legacy
	};
}

function lan_ipv6(links, name) {
	for (let link in links || []) if (link.ifname == name)
		for (let a in link.addr_info || [])
			if (a.family == 'inet6' && a.scope == 'global' &&
				!a.tentative && !a.dadfailed &&
				index(a.flags || [], 'tentative') < 0 && index(a.flags || [], 'dadfailed') < 0)
				return true;
	return false;
}

function profile_ipv6(profile) {
	let address = false, route = false;
	for (let value in split(profile.interface.Address || '', ',')) {
		let cidr = trim(value);
		if (index(cidr, ':') >= 0 && !awg.overlap(cidr, 'fe80::/10') &&
			!awg.overlap(cidr, 'ff00::/8') && !awg.overlap(cidr, '::1/128')) address = true;
	}
	// Conservative MVP: partial IPv6 AllowedIPs are not full IPv6 support.
	// Per-interface terminal routes still block destinations outside AllowedIPs.
	for (let peer in profile.peers || [])
		for (let cidr in split(peer.AllowedIPs || '', ','))
			if (trim(cidr) == '::/0') route = true;
	return address && route;
}

return { settings: settings, lan_ipv6: lan_ipv6, profile_ipv6: profile_ipv6 };
