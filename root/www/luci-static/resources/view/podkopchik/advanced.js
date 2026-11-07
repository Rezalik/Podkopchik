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
		return Promise.all([uci.load('podkopchik'), fs.exec_direct('/usr/bin/podkopchikctl', ['native-status'])
			.then(function(text) { return JSON.parse(text); }).catch(function() { return {available:false}; })]);
	},

	render: function(data) {
		var m = new form.Map('podkopchik', _('Podkopchik'));
		this.map = m;
		var s = m.section(form.NamedSection, 'main', 'settings', _('Advanced'));
		s.anonymous = true;

		var o = s.option(form.Flag, 'enabled', _('Service enabled'));
		o.default = '1';

		o = s.option(form.DummyValue, 'routing_enabled', _('Routing applied'));

		o = s.option(form.ListValue, 'routing_engine', _('Routing engine'));
		o.value('legacy', _('Legacy'));
		if (data && data[1] && data[1].available || uci.get('podkopchik', 'main', 'routing_engine') === 'native')
			o.value('native', _('Universal Routing Engine'));
		o.default = 'legacy';
		o.rmempty = false;
		o.description = _('Native Apply switches the configured LAN and requires explicit confirmation before the rollback deadline.');
		if (!data || !data[1] || !data[1].available)
			o.description += ' ' + _('Install the Native DNS component for this router architecture before enabling Universal Routing Engine.');

		o = s.option(form.Value, 'native_pool_v4', _('Native synthetic IPv4 pool'));
		o.datatype = 'cidr4';
		o.depends('routing_engine', 'native');
		o.description = _('Use a separately admitted pool. Apply checks live addresses, routes, VPN endpoints and issued FakeDNS pools before activation.');

		o = s.option(form.Value, 'native_pool_v6', _('Native synthetic IPv6 pool'));
		o.datatype = 'cidr6';
		o.depends('routing_engine', 'native');

		o = s.option(form.Value, 'native_confirm_seconds', _('Apply confirmation timeout (seconds)'));
		o.datatype = 'range(60,900)';
		o.default = '300';
		o.depends('routing_engine', 'native');

		o = s.option(form.ListValue, 'native_classification_mode', _('Native routing classification'));
		o.value('strict', _('Strict'));
		o.value('compatible', _('Compatible'));
		o.default = 'strict';
		o.rmempty = false;
		o.description = _('Applies to Universal Routing Engine only; legacy routing is unchanged.');

		o = s.option(form.ListValue, 'native_unknown_action', _('Unknown traffic'));
		o.value('protected', _('Protected transport (recommended)'));
		o.value('block', _('Block'));
		o.default = 'protected';
		o.rmempty = false;
		o.depends('native_classification_mode', 'strict');
		o.depends('native_migration_restrict_unknown', '1');
		o.description = _('Unknown traffic uses an available Main or Backup transport supporting the protocol. If none is available, it is blocked. This does not identify its domain.');

		o = s.option(form.DummyValue, '_native_compatible_warning', _('Warning'));
		o.depends('native_classification_mode', 'compatible');
		o.cfgvalue = function() { return _('Compatible mode allows unknown traffic directly. Strict domain fail-closed is not guaranteed.'); };

		o = s.option(form.Flag, 'native_migration_restrict_unknown', _('Restrict unknown traffic during native migration'));
		o.default = '1';
		o.rmempty = false;
		o.description = _('During migration, unknown traffic stays off direct WAN even in Compatible mode. The protected fallback or block policy applies. Direct exceptions grant the whole address or device.');

		o = s.option(form.Flag, 'native_direct_grants_confirmed', _('Confirm whole-address and whole-device direct exceptions'));
		o.default = '0';
		o.rmempty = false;
		o.depends('native_classification_mode', 'strict');
		o.depends('native_migration_restrict_unknown', '1');
		o.description = _('Direct IP/CIDR, endpoint and LAN-device exceptions override domain protection for that address or device. Confirm them only after reviewing the complete exception list.') + ' ' +
			_('A shared CDN IP may serve multiple domains; a direct IP exception covers all of them.');

		o = s.option(form.DummyValue, '_native_strict_warning', _('Strict direct policy'));
		o.depends('native_classification_mode', 'strict');
		o.depends('native_migration_restrict_unknown', '1');
		o.cfgvalue = function() { return _('Domain-only direct rules and shared cached IP addresses are not authenticated. Without a confirmed address or LAN-device exception, the unknown-traffic policy applies.'); };

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

			if (enabled == '0' || routing == '0')
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
