'use strict';
'require view';
'require form';

return view.extend({
	render: function() {
		var m = new form.Map('podkopchik', _('Podkopchik'));
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
	}
});
