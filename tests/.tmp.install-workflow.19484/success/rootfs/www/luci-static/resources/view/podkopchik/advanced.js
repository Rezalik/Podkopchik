'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require uci';

function runCommand(args) {
	return fs.exec_direct('/usr/bin/podkopchikctl', args).catch(function(err) {
		return err && err.message ? err.message : String(err);
	});
}

function runRuntime(args) {
	return fs.exec_direct('/usr/bin/podkopchikctl', args);
}

return view.extend({
	load: function() {
		return uci.load('podkopchik');
	},

	render: function() {
		var m = new form.Map('podkopchik', _('Podkopchik'));
		this.map = m;
		var s = m.section(form.NamedSection, 'main', 'settings', _('Advanced'));
		s.anonymous = true;

		var o = s.option(form.Flag, 'enabled', _('Service enabled'));
		o.default = '1';

		o = s.option(form.DummyValue, 'routing_enabled', _('Routing applied'));

		o = s.option(form.Value, 'transparent_port', _('Transparent port'));
			o.datatype = 'port';
			o.default = '12345';

			o = s.option(form.Value, 'lan_ifname', _('LAN interface'));
			o.default = 'br-lan';

		o = s.option(form.Value, 'probe_url', _('Probe URL'));
		o.datatype = 'url';
		o.default = 'https://www.gstatic.com/generate_204';

		o = s.option(form.ListValue, 'probe_method', _('Probe method'));
		o.value('HEAD', 'HEAD');
		o.default = 'HEAD';

		o = s.option(form.Value, 'interval', _('Health interval'));
		o.datatype = 'uinteger';
		o.default = '30';

		o = s.option(form.Value, 'timeout', _('Health timeout'));
		o.datatype = 'uinteger';
		o.default = '5';

		o = s.option(form.Value, 'fail_threshold', _('Fail threshold'));
		o.datatype = 'uinteger';
		o.default = '3';

		o = s.option(form.Value, 'restore_threshold', _('Restore threshold'));
		o.datatype = 'uinteger';
		o.default = '2';

		o = s.option(form.Value, 'github_repo', _('GitHub repository'));
		o.default = 'rezalik/Podkopchik';

		o = s.option(form.Value, 'release_asset_prefix', _('Release asset prefix'));
		o.default = 'luci-app-podkopchik';

		o = s.option(form.ListValue, 'loglevel', _('Xray log level'));
		o.value('debug', 'debug');
		o.value('info', 'info');
		o.value('warning', 'warning');
		o.value('error', 'error');
		o.value('none', 'none');
		o.default = 'warning';

		var buttons = E('div', { 'class': 'cbi-section' }, [
			E('button', {
				'class': 'btn cbi-button',
				'click': ui.createHandlerFn(this, function() {
					return runCommand([ 'validate' ]).then(function(res) {
						ui.addNotification(null, E('pre', { 'style': 'white-space: pre-wrap' }, res));
					});
				})
			}, _('Validate')),
			' ',
			E('button', {
				'class': 'btn cbi-button',
				'click': ui.createHandlerFn(this, function() {
					return runCommand([ 'restart' ]).then(function(res) {
						ui.addNotification(null, E('pre', { 'style': 'white-space: pre-wrap' }, res || _('Restarted.')));
					});
				})
			}, _('Restart')),
			' ',
			E('button', {
				'class': 'btn cbi-button cbi-button-remove',
				'click': ui.createHandlerFn(this, function() {
					return runCommand([ 'cleanup' ]).then(function(res) {
						ui.addNotification(null, E('pre', { 'style': 'white-space: pre-wrap' }, res));
					});
				})
			}, _('Disable Routing'))
		]);

		return m.render().then(function(node) {
			return E([ node, buttons ]);
		});
	},

	handleSave: function() {
		return this.map.save();
	},

	handleSaveApply: function(ev, mode) {
		return this.handleSave(ev).then(function() {
			return ui.changes.apply(mode == '0');
		}).then(function() {
			var enabled = uci.get('podkopchik', 'main', 'enabled');
			var routing = uci.get('podkopchik', 'main', 'routing_enabled');

			if (enabled == '0')
				return runRuntime([ 'cleanup' ]);

			if (routing == '1')
				return runRuntime([ 'apply' ]);

			return '';
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
