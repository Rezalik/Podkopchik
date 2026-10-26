'use strict';
'require view';
'require form';
'require fs';
'require ui';

function runApply() {
	return fs.exec_direct('/usr/bin/podkopchikctl', [ 'apply' ]);
}

function cleanValue(value) {
	return (value || '').trim().toLowerCase().replace(/\.$/, '');
}

function validIPv4(value) {
	var m = value.match(/^([0-9]+)\.([0-9]+)\.([0-9]+)\.([0-9]+)(?:\/([0-9]+))?$/);

	if (!m)
		return false;

	for (var i = 1; i <= 4; i++) {
		var n = parseInt(m[i], 10);
		if (n < 0 || n > 255)
			return false;
	}

	if (m[5] != null) {
		var p = parseInt(m[5], 10);
		if (p < 0 || p > 32)
			return false;
	}

	return true;
}

function validIPv6(value) {
	var parts = value.split('/');
	var addr = parts[0];

	if (parts.length > 2 || addr.indexOf(':') < 0 || !/^[0-9a-f:]+$/i.test(addr))
		return false;

	if (parts.length == 2) {
		if (!/^[0-9]+$/.test(parts[1]))
			return false;

		var p = parseInt(parts[1], 10);
		if (p < 0 || p > 128)
			return false;
	}

	return true;
}

function validDomain(value) {
	if (!/^[a-z0-9.-]+$/i.test(value) || value.indexOf('.') < 0)
		return false;

	var labels = value.split('.');
	for (var i = 0; i < labels.length; i++) {
		if (!/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/i.test(labels[i]))
			return false;
	}

	return value.length <= 253;
}

function validateBypassHost(sectionId, value) {
	value = cleanValue(value);

	if (!value)
		return _('Host/IP/CIDR is required.');

	if (value.indexOf('://') >= 0 || value.indexOf('/') >= 0 && !validIPv4(value) && !validIPv6(value))
		return _('Enter only a domain, IP, or CIDR without scheme, path, or port.');

	if (validIPv4(value) || validIPv6(value) || validDomain(value))
		return true;

	if (value.indexOf(':') >= 0)
		return _('Port-specific exclusions are not supported. Enter only a domain, IP, or CIDR.');

	return _('Enter only a valid domain, IP, or CIDR.');
}

return view.extend({
	render: function() {
		var m = new form.Map('podkopchik', _('Podkopchik'));
		this.map = m;

		var s = m.section(form.GridSection, 'bypass_rule', _('Exclusions'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;
		s.description = _('Add hosts, IP addresses, or CIDR networks that must always bypass the proxy. Use this for 3x-ui panels, VPS addresses, or proxy server domains you need to open directly from LAN.');

		var o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.enabled = '1';
		o.disabled = '0';
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'host', _('Host/IP/CIDR'));
		o.placeholder = 'panel.example.com';
		o.rmempty = false;
		o.validate = validateBypassHost;

		o = s.option(form.Value, 'comment', _('Comment'));
		o.rmempty = true;

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
