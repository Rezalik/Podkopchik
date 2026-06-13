'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require uci';

function runApply() {
	return fs.exec_direct('/usr/bin/podkopchikctl', [ 'apply' ]);
}

function addProxyValues(o) {
	var proxies = uci.sections('podkopchik', 'proxy') || [];
	o.value('', _('None'));
	proxies.forEach(function(p) {
		var tag = p.tag || p.name;
		if (tag)
			o.value(tag, p.name || tag);
	});
}

return view.extend({
	load: function() {
		return uci.load('podkopchik');
	},

	render: function() {
		var m = new form.Map('podkopchik', _('Podkopchik'));
		this.map = m;
		var s = m.section(form.GridSection, 'proxy_group', _('Advanced proxy groups'));
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

		o = s.option(form.Value, 'tag', _('Tag'));
		o.datatype = 'uciname';
		o.rmempty = false;

		o = s.option(form.ListValue, 'mode', _('Mode'));
		o.value('strict_primary', _('Strict primary'));
		o.value('fixed_proxy', _('Fixed proxy'));
		o.default = 'strict_primary';

		o = s.option(form.Value, 'primary', _('Primary proxy'));
		addProxyValues(o);
		o.depends('mode', 'strict_primary');

		o = s.option(form.Value, 'fixed_proxy', _('Fixed proxy'));
		addProxyValues(o);
		o.depends('mode', 'fixed_proxy');

		o = s.option(form.Value, 'backup1', _('Backup 1'));
		addProxyValues(o);

		o = s.option(form.Value, 'backup2', _('Backup 2'));
		addProxyValues(o);

		o = s.option(form.Value, 'backup3', _('Backup 3'));
		addProxyValues(o);

		o = s.option(form.Flag, 'auto_return', _('Auto-return'));
		o.default = '1';
		o.depends('mode', 'strict_primary');

		o = s.option(form.Value, 'manual_override_proxy', _('Manual override'));
		addProxyValues(o);
		o.depends('mode', 'strict_primary');

		o = s.option(form.DummyValue, '_manual_override_warning', _('Override warning'));
		o.cfgvalue = function(section_id) {
			return uci.get('podkopchik', section_id, 'manual_override_proxy')
				? _('Manual override is active for this group.')
				: '';
		};
		o.depends('mode', 'strict_primary');

		o = s.option(form.ListValue, 'failure_action', _('Failure action'));
		o.value('warn_only', _('Warn only'));
		o.value('switch_to_backup', _('Switch to backup'));
		o.default = 'warn_only';
		o.depends('mode', 'fixed_proxy');

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
