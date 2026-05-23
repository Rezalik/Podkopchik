'use strict';
'require view';
'require form';
'require uci';

function addTargets(o) {
	o.value('auto_proxy_group', _('Automatic: main + backups'));
	(uci.sections('podkopchik', 'proxy') || []).forEach(function(p) {
		var tag = p.tag || p.name;
		if (tag)
			o.value(tag, (p.name || tag) + ' (' + _('proxy') + ')');
	});
	o.value('direct', _('Direct'));
}

function validatePositiveRate(section_id, value) {
	if (value == null || value === '')
		return _('Speed limit must be a positive number in Mbit/s.');

	if (!/^[0-9]+(\.[0-9]+)?$/.test(value) || parseFloat(value) <= 0)
		return _('Speed limit must be a positive number in Mbit/s.');

	return true;
}

function validateHours(section_id, value) {
	if (value == null || value === '')
		return _('Temporary limit duration must be a positive number of hours.');

	if (!/^[0-9]+(\.[0-9]+)?$/.test(value) || parseFloat(value) <= 0)
		return _('Temporary limit duration must be a positive number of hours.');

	return true;
}

function validateTime(section_id, value) {
	if (value == null || value === '')
		return true;

	if (!/^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(value))
		return _('Use HH:MM time, for example 18:00.');

	return true;
}

return view.extend({
	load: function() {
		return uci.load('podkopchik');
	},

	render: function() {
		var m = new form.Map('podkopchik', _('Podkopchik'));
		var s = m.section(form.GridSection, 'lan_device', _('LAN Devices'));
		s.description = _('Speed limit enforcement is not active in this beta. Configuration and diagnostics are available for testing.');
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
		o.default = 'auto_proxy_group';
		o.modalonly = true;

		o = s.option(form.Flag, 'speed_limit_enabled', _('Speed limit enabled'));
		o.enabled = '1';
		o.disabled = '0';
		o.default = '0';
		o.rmempty = false;
		o.modalonly = true;

		o = s.option(form.Value, 'download_mbit', _('Download limit, Mbit/s'));
		o.placeholder = '10';
		o.validate = validatePositiveRate;
		o.depends('speed_limit_enabled', '1');
		o.modalonly = true;

		o = s.option(form.Value, 'upload_mbit', _('Upload limit, Mbit/s'));
		o.placeholder = '3';
		o.validate = validatePositiveRate;
		o.depends('speed_limit_enabled', '1');
		o.modalonly = true;

		o = s.option(form.ListValue, 'speed_limit_mode', _('Speed limit mode'));
		o.value('always', _('Always limited'));
		o.value('duration', _('Limit for N hours'));
		o.value('schedule', _('Schedule'));
		o.value('unlimited_window', _('Unlimited during time window'));
		o.default = 'always';
		o.depends('speed_limit_enabled', '1');
		o.modalonly = true;

		o = s.option(form.Value, 'speed_limit_hours', _('Temporary limit duration'));
		o.description = _('Use 1, 3, 6, or any custom number of hours.');
		o.placeholder = '3';
		o.validate = validateHours;
		o.depends({
			speed_limit_enabled: '1',
			speed_limit_mode: 'duration'
		});
		o.modalonly = true;

		o = s.option(form.Value, 'schedule_days', _('Schedule days'));
		o.description = _('Use day names such as: mon tue wed thu fri');
		o.placeholder = 'mon tue wed thu fri';
		o.depends({
			speed_limit_enabled: '1',
			speed_limit_mode: 'schedule'
		});
		o.modalonly = true;

		o = s.option(form.Value, 'schedule_start', _('Schedule start'));
		o.placeholder = '18:00';
		o.validate = validateTime;
		o.depends({
			speed_limit_enabled: '1',
			speed_limit_mode: 'schedule'
		});
		o.modalonly = true;

		o = s.option(form.Value, 'schedule_end', _('Schedule end'));
		o.placeholder = '22:00';
		o.validate = validateTime;
		o.depends({
			speed_limit_enabled: '1',
			speed_limit_mode: 'schedule'
		});
		o.modalonly = true;

		o = s.option(form.Value, 'unlimited_window_start', _('Unlimited window start'));
		o.placeholder = '00:00';
		o.validate = validateTime;
		o.depends({
			speed_limit_enabled: '1',
			speed_limit_mode: 'unlimited_window'
		});
		o.modalonly = true;

		o = s.option(form.Value, 'unlimited_window_end', _('Unlimited window end'));
		o.placeholder = '06:00';
		o.validate = validateTime;
		o.depends({
			speed_limit_enabled: '1',
			speed_limit_mode: 'unlimited_window'
		});
		o.modalonly = true;

		o = s.option(form.DummyValue, '_speed_limit_phase', _('Speed limit status'));
		o.cfgvalue = function() {
			return _('Speed limit enforcement is diagnostic-only in this beta.');
		};
		o.depends('speed_limit_enabled', '1');
		o.modalonly = true;

		return m.render();
	}
});
