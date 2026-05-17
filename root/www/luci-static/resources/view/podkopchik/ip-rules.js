'use strict';
'require view';
'require form';
'require uci';

function addTargets(o) {
	(uci.sections('podkopchik', 'proxy_group') || []).forEach(function(g) {
		var tag = g.tag || g.name;
		if (tag)
			o.value(tag, (g.name || tag) + ' (group)');
	});
	(uci.sections('podkopchik', 'proxy') || []).forEach(function(p) {
		var tag = p.tag || p.name;
		if (tag)
			o.value(tag, (p.name || tag) + ' (proxy)');
	});
}

return view.extend({
	load: function() {
		return uci.load('podkopchik');
	},

	render: function() {
		var m = new form.Map('podkopchik', _('Podkopchik'));
		var s = m.section(form.GridSection, 'ip_rule', _('IP Rules'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;

		var o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.default = '1';

		o = s.option(form.Value, 'cidr', _('Destination CIDR'));
		o.datatype = 'cidr';
		o.rmempty = false;

		o = s.option(form.Value, 'target', _('Target'));
		addTargets(o);
		o.rmempty = false;

		return m.render();
	}
});
