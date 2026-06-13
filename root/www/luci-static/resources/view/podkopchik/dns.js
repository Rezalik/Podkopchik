'use strict';
'require view';
'require form';
'require fs';
'require ui';

function runApply() {
	return fs.exec_direct('/usr/bin/podkopchikctl', [ 'apply' ]);
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
