'use strict';
'require view';
'require form';
'require fs';
'require ui';
'require uci';
'require podkopchik.routing as routing';

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

		o = s.option(form.DummyValue, 'routing_enabled', _('Routing requested'));

		o = s.option(form.ListValue, 'routing_engine', _('Routing engine'));
		o.value('legacy', _('Legacy'));
		if (data && data[1] && data[1].available || uci.get('podkopchik', 'main', 'routing_engine') === 'native')
			o.value('native', _('Universal Routing Engine'));
		o.default = 'legacy';
		o.rmempty = false;
		o.description = uci.get('podkopchik', 'main', 'native_recovery_policy') === 'repair'
			? _('Native Apply switches the configured LAN and requires explicit confirmation on Status. Emergency recovery remains active.')
			: _('Native Apply switches the configured LAN and requires explicit confirmation before the rollback deadline.');
		if (!data || !data[1] || !data[1].available)
			o.description += ' ' + _('Install the Native DNS component for this router architecture before enabling Universal Routing Engine.');

		o = s.option(form.Value, 'native_pool_v4', _('Native synthetic IPv4 pool'));
		o.datatype = 'cidr4';
		o.retain = true;
		o.depends('routing_engine', 'native');
		o.description = _('Use a separately admitted pool. Apply checks live addresses, routes, VPN endpoints and issued FakeDNS pools before activation.');

		o = s.option(form.Value, 'native_pool_v6', _('Native synthetic IPv6 pool'));
		o.datatype = 'cidr6';
		o.retain = true;
		o.depends('routing_engine', 'native');

		if (uci.get('podkopchik', 'main', 'native_recovery_policy') === 'repair') {
			o = s.option(form.DummyValue, '_native_recovery_policy', _('Recovery policy'));
			o.depends('routing_engine', 'native');
			o.cfgvalue = function() { return _('Repair in place; emergency recovery is reserved for management loss or a critical failure.'); };
		}
		else {
			o = s.option(form.Value, 'native_confirm_seconds', _('Apply confirmation timeout (seconds)'));
			o.datatype = 'range(60,900)';
			o.default = '300';
			o.retain = true;
			o.depends('routing_engine', 'native');
		}

		o = s.option(form.ListValue, 'native_classification_mode', _('Base routing policy'));
		o.value('compatible', _('Selective routing (rules only)'));
		o.value('strict', _('Strict routing'));
		o.default = 'compatible';
		o.rmempty = false;
		o.retain = true;
		o.depends('routing_engine', 'native');
		o.description = _('Selective routing is the default: only enabled rules and presets choose a proxy. Main and backup roles alone do not route all traffic.');

		var live = data && data[1] || {};
		var configured = routing.fromSettings(function(name) { return uci.get('podkopchik', 'main', name); });
		var active = routing.activePolicy(live);
		o = s.option(form.DummyValue, '_native_saved_policy', _('Saved routing policy'));
		o.depends('routing_engine', 'native');
		o.cfgvalue = function() { return routing.label(configured) + ': ' + routing.description(configured); };

		o = s.option(form.DummyValue, '_native_active_policy', _('Active routing policy'));
		o.depends('routing_engine', 'native');
		o.cfgvalue = function() {
			return live.engine === 'native' && ['active', 'recovery'].indexOf(live.phase) >= 0
				? routing.label(active) + ': ' + routing.description(active) : _('Native routing is not active.');
		};

		o = s.option(form.DummyValue, '_native_policy_state', _('Policy application'));
		o.depends('routing_engine', 'native');
		o.cfgvalue = function() {
			if (live.pending) return live.recovery_policy === 'repair'
				? _('Native Apply is pending. Open Status, verify connectivity and confirm. Emergency recovery remains active.')
				: _('Native Apply is pending. Open Status and confirm the configuration before the rollback deadline.');
			if (!configured) return _('Saved routing policy is invalid.');
			if (!active) return _('Active routing policy is unavailable.');
			return routing.differs(active, configured) ? _('Saved routing policy differs from the active policy. Apply is required.') : _('Saved and active routing policies match.');
		};

		o = s.option(form.ListValue, 'native_unknown_action', _('Other traffic in Strict or migration mode'));
		o.value('protected', _('Main or backup transport'));
		o.value('block', _('Block'));
		o.default = 'protected';
		o.rmempty = false;
		o.retain = true;
		o.depends({routing_engine: 'native', native_classification_mode: 'strict'});
		o.depends({routing_engine: 'native', native_migration_restrict_unknown: '1'});
		o.description = _('Unknown traffic uses an available Main or Backup transport supporting the protocol. If none is available, it is blocked. This does not identify its domain.');

		o = s.option(form.DummyValue, '_native_compatible_warning', _('Warning'));
		o.depends({routing_engine: 'native', native_classification_mode: 'compatible', native_migration_restrict_unknown: '0'});
		o.cfgvalue = function() { return _('Selective routing depends on router DNS. Cached real IPs, third-party DoH and literal IPs can bypass domain-only rules.'); };

		o = s.option(form.Flag, 'native_migration_restrict_unknown', _('Migration restriction (overrides selective routing)'));
		o.default = '0';
		o.rmempty = false;
		o.retain = true;
		o.depends('routing_engine', 'native');
		o.description = _('When enabled, traffic outside the rules is protected or blocked even when the base policy is selective.');

		o = s.option(form.DummyValue, '_native_migration_warning', _('Warning'));
		o.depends({routing_engine: 'native', native_migration_restrict_unknown: '1'});
		o.cfgvalue = function() { return _('Migration restriction is enabled. Unmatched traffic is not direct.'); };

		o = s.option(form.Flag, 'native_direct_grants_confirmed', _('Confirm whole-address and whole-device direct exceptions'));
		o.default = '0';
		o.rmempty = false;
		o.retain = true;
		o.depends({routing_engine: 'native', native_classification_mode: 'strict'});
		o.depends({routing_engine: 'native', native_migration_restrict_unknown: '1'});
		o.description = _('Direct IP/CIDR, endpoint and LAN-device exceptions override domain protection for that address or device. Confirm them only after reviewing the complete exception list.') + ' ' +
			_('A shared CDN IP may serve multiple domains; a direct IP exception covers all of them.');

		o = s.option(form.DummyValue, '_native_strict_warning', _('Strict direct policy'));
		o.depends({routing_engine: 'native', native_classification_mode: 'strict'});
		o.depends({routing_engine: 'native', native_migration_restrict_unknown: '1'});
		o.cfgvalue = function() { return _('Domain-only direct rules and shared cached IP addresses are not authenticated. Without a confirmed address or LAN-device exception, the unknown-traffic policy applies.'); };

		o = s.option(form.Value, 'transparent_port', _('Transparent port'));
			o.datatype = 'port';
			o.default = '12345';
			o.retain = true;
			o.depends('routing_engine', 'legacy');

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
			return routing.notifyApply(res);
		}).catch(function(err) {
			var message = err && err.message ? err.message : String(err);
			ui.addNotification(_('Apply'), E('pre', { 'style': 'white-space: pre-wrap' }, message), 'error');
			return Promise.reject(err);
		});
	}
});
