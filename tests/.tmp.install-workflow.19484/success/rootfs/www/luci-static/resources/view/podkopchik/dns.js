'use strict';
'require view';
'require form';
'require fs';
'require ui';

function runApply() {
	return fs.exec_direct('/usr/bin/podkopchikctl', [ 'apply' ]);
}

function validatePort(_sectionId, value) {
	var n = Number(value);

	if (!/^[0-9]+$/.test(String(value || '')) || n < 1 || n > 65535)
		return _('Enter a port from 1 to 65535.');

	return true;
}

function validatePositiveInteger(_sectionId, value) {
	var n = Number(value);

	if (!/^[0-9]+$/.test(String(value || '')) || n < 1)
		return _('Enter a positive number.');

	return true;
}

function validateIpv4Cidr(_sectionId, value) {
	var match = String(value || '').trim().match(/^([0-9]{1,3}(?:\.[0-9]{1,3}){3})\/([0-9]{1,2})$/);

	if (!match)
		return _('Enter an IPv4 CIDR, for example 198.18.0.0/15.');

	var octets = match[1].split('.');
	var prefix = Number(match[2]);

	if (prefix < 0 || prefix > 32)
		return _('Enter an IPv4 CIDR, for example 198.18.0.0/15.');

	for (var i = 0; i < octets.length; i++) {
		var octet = Number(octets[i]);
		if (octet < 0 || octet > 255)
			return _('Enter an IPv4 CIDR, for example 198.18.0.0/15.');
	}

	return true;
}

return view.extend({
	render: function() {
		var m = new form.Map('podkopchik', _('Podkopchik'));
		this.map = m;
		var s = m.section(form.NamedSection, 'main', 'settings', _('DNS'));
		s.anonymous = true;

		var o = s.option(form.Flag, 'dns_redirect', _('Redirect LAN DNS to router'));
		o.default = '0';

		o = s.option(form.DummyValue, '_dns_warning', _('Warning'));
		o.rawhtml = true;
		o.cfgvalue = function() {
			return _('DoH, DoT, and Apple Private Relay can bypass normal DNS redirect.');
		};

		o = s.option(form.Flag, 'fakedns_enabled', _('Enable FakeDNS'));
		o.default = '0';
		o.description = _('FakeDNS helps apps that do not route reliably with domain-only rules. For example, X/Twitter app may require FakeDNS.');

		o = s.option(form.Flag, 'fakedns_hijack_dns', _('Hijack LAN DNS queries'));
		o.default = '0';
		o.description = _('When enabled, LAN device DNS queries to port 53 are redirected to Xray FakeDNS. This is usually needed for apps to work through FakeDNS.');
		o.depends('fakedns_enabled', '1');

		o = s.option(form.Value, 'fakedns_port', _('FakeDNS port'));
		o.default = '1053';
		o.placeholder = '1053';
		o.validate = validatePort;
		o.depends('fakedns_enabled', '1');

		o = s.option(form.Value, 'fakedns_pool_v4', _('FakeDNS IPv4 pool'));
		o.default = '198.18.0.0/15';
		o.placeholder = '198.18.0.0/15';
		o.validate = validateIpv4Cidr;
		o.depends('fakedns_enabled', '1');

		o = s.option(form.Value, 'fakedns_pool_size', _('FakeDNS pool size'));
		o.default = '65535';
		o.placeholder = '65535';
		o.validate = validatePositiveInteger;
		o.depends('fakedns_enabled', '1');

		o = s.option(form.Value, 'fakedns_listen', _('FakeDNS listen address'));
		o.default = '';
		o.placeholder = _('empty means automatic');
		o.description = _('Leave empty for automatic selection. DNS hijack usually uses 0.0.0.0, otherwise loopback.');
		o.depends('fakedns_enabled', '1');

		o = s.option(form.DummyValue, '_fakedns_notice', _('FakeDNS notes'));
		o.rawhtml = true;
		o.depends('fakedns_enabled', '1');
		o.cfgvalue = function() {
			return [
				_('Fake IP addresses from 198.18.0.0/15 are expected when FakeDNS is enabled.'),
				_('Private DNS, DoH, iCloud Private Relay, or another VPN may bypass router DNS.')
			].join('<br />');
		};

		return m.render();
	},

	handleSave: function() {
		return this.map.save();
	},

	handleSaveApply: function(ev, mode) {
		return this.handleSave(ev).then(function() {
			return ui.changes.apply(mode == '0');
		}).then(function() {
			return runApply();
		}).then(function(res) {
			if (res)
				ui.addNotification(null, E('pre', { 'style': 'white-space: pre-wrap' }, res));
		}).catch(function(err) {
			var message = err && err.message ? err.message : String(err);
			ui.addNotification(_('Apply'), E('pre', { 'style': 'white-space: pre-wrap' }, message), 'error');
			return Promise.reject(err);
		});
	}
});
