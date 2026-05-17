'use strict';
'require view';
'require form';

return view.extend({
	render: function() {
		var m = new form.Map('podkopchik', _('Podkopchik'));
		var s = m.section(form.GridSection, 'proxy', _('Proxy Links'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;

		var o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';

		o = s.option(form.Value, 'name', _('Name'));
		o.rmempty = false;

		o = s.option(form.Value, 'tag', _('Tag'));
		o.datatype = 'uciname';
		o.rmempty = false;

		o = s.option(form.Value, 'uri', _('VLESS URI'));
		o.password = true;
		o.rmempty = false;

		o = s.option(form.Value, 'detected_transport', _('Transport'));
		o.readonly = true;
		o.rmempty = true;

		o = s.option(form.Value, 'detected_security', _('Security'));
		o.readonly = true;
		o.rmempty = true;

		o = s.option(form.Value, 'note', _('Note'));
		o.rmempty = true;

		return m.render();
	}
});
