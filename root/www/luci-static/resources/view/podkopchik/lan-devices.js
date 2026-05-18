'use strict';
'require view';
'require form';
'require uci';

function addTargets(o) {
	o.value('direct', _('Direct'));
	(uci.sections('podkopchik', 'proxy_group') || []).forEach(function(g) {
		var tag = g.tag || g.name;
		if (tag)
			o.value(tag, (g.name || tag) + ' (' + _('group') + ')');
	});
	(uci.sections('podkopchik', 'proxy') || []).forEach(function(p) {
		var tag = p.tag || p.name;
		if (tag)
			o.value(tag, (p.name || tag) + ' (' + _('proxy') + ')');
	});
}

return view.extend({
	load: function() {
		return uci.load('podkopchik');
	},

	render: function() {
		var m = new form.Map('podkopchik', _('Podkopchik'));
		var s = m.section(form.GridSection, 'lan_device', _('LAN Devices'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;

		var o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.enabled = '1';
		o.disabled = '0';
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'name', _('Name'));
		o.rmempty = false;

		o = s.option(form.Value, 'source_ip', _('Source IP'));
		o.datatype = 'ipaddr';
		o.rmempty = false;

		o = s.option(form.ListValue, 'mode', _('Mode'));
		o.value('full_proxy', _('Full proxy'));
		o.value('rules_only', _('Rules only'));
		o.value('direct', _('Direct'));
		o.default = 'rules_only';

		o = s.option(form.Value, 'target', _('Target'));
		addTargets(o);
		o.depends('mode', 'full_proxy');

		return m.render();
	}
});
