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

function migrationPanel() {
	var status = E('div', { 'aria-live': 'polite' });
	var check = E('button', { 'class': 'btn cbi-button' }, _('Check Native readiness'));
	var validate = E('button', { 'class': 'btn cbi-button', disabled: true }, _('Validate migration'));
	var migrate = E('button', { 'class': 'btn cbi-button cbi-button-apply', disabled: true }, _('Migrate to Native'));
	var reasons = {
		not_legacy: _('Migration requires Legacy without an existing Native generation.'),
		transactional_required: _('Migration requires transactional recovery.'),
		pool_required: _('Save a Native synthetic pool first.'),
		helper_required: _('Install the Native DNS component for this router architecture before enabling Universal Routing Engine.'),
		platform_not_supported: _('This board or firmware is not supported by the Native candidate.'),
		platform_requirements: _('Native platform requirements are not met.')
	};
	check.addEventListener('click', ui.createHandlerFn(null, function() {
		validate.disabled = migrate.disabled = true;
		return runRuntime(['native-migration-readiness']).then(function(res) {
			var data = JSON.parse(res);
			var issues = (data.issues || []).map(function(code) { return reasons[code] || code; });
			(data.checks || []).forEach(function(item) { issues.push(item.id + ': ' + item.status); });
			status.textContent = (data.target ? data.target + ': ' : '') +
				(data.ready ? _('Platform checks passed. Validate the saved configuration next.') : issues.join(' '));
			validate.disabled = !data.ready;
		}).catch(function() { status.textContent = _('Native readiness check unavailable.'); });
	}));
	validate.addEventListener('click', ui.createHandlerFn(null, function() {
		migrate.disabled = true;
		return runRuntime(['native-migrate-check']).then(function(res) {
			if (JSON.parse(res).valid !== true) throw new Error();
			status.textContent = _('Saved migration configuration validated.');
			migrate.disabled = false;
		}).catch(function() { status.textContent = _('Migration validation failed. Check the saved LAN, profiles, pools and port reservations.'); });
	}));
	migrate.addEventListener('click', ui.createHandlerFn(null, function() {
		ui.showModal(_('Migrate to Native'), [
			E('p', {}, _('Apply the saved settings to the LAN and enable Native routing? Verify DNS and internet access, then confirm on Status.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', click: ui.hideModal }, _('Cancel')),
				' ', E('button', { 'class': 'btn cbi-button-apply', click: ui.createHandlerFn(null, function() {
					ui.hideModal();
					check.disabled = validate.disabled = migrate.disabled = true;
					return runRuntime(['native-migrate']).then(function(res) {
						if (!JSON.parse(res).pending) throw new Error();
						status.textContent = _('Native Apply is pending. Open Status and confirm the configuration before the rollback deadline.');
						return routing.notifyApply(res);
					}).catch(function() {
						check.disabled = false;
						status.textContent = _('Migration did not return an Apply token. Check Status before retrying.');
					});
				}) }, _('Migrate to Native'))
			])
		]);
	}));
	return E('div', { 'class': 'cbi-section' }, [
		E('h3', _('Legacy to Native migration')), check, ' ', validate, ' ', migrate, status
	]);
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
		var live = data && data[1] || {};
		var legacy = uci.get('podkopchik', 'main', 'routing_engine') !== 'native' && live.engine !== 'native' && !live.pending;
		var staging = legacy && live.available;
		function nativeDepends(option, conditions) {
			if (conditions) option.depends(Object.assign(staging ? {} : {routing_engine: 'native'}, conditions));
			else if (!staging) option.depends('routing_engine', 'native');
		}

		var o = s.option(form.Flag, 'enabled', _('Service enabled'));
		o.default = '1';

		o = s.option(form.DummyValue, 'routing_enabled', _('Routing requested'));

		o = s.option(form.ListValue, 'routing_engine', _('Routing engine'));
		o.value('legacy', _('Legacy'));
		if (!legacy)
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
		nativeDepends(o);
		o.description = _('Use a separately admitted pool. Apply checks live addresses, routes, VPN endpoints and issued FakeDNS pools before activation.');

		o = s.option(form.Value, 'native_pool_v6', _('Native synthetic IPv6 pool'));
		o.datatype = 'cidr6';
		o.retain = true;
		nativeDepends(o);

		if (uci.get('podkopchik', 'main', 'native_recovery_policy') === 'repair') {
			o = s.option(form.DummyValue, '_native_recovery_policy', _('Recovery policy'));
			nativeDepends(o);
			o.cfgvalue = function() { return _('Repair in place; emergency recovery is reserved for management loss or a critical failure.'); };
		}
		else {
			o = s.option(form.Value, 'native_confirm_seconds', _('Apply confirmation timeout (seconds)'));
			o.datatype = 'range(60,900)';
			o.default = '300';
			o.retain = true;
			nativeDepends(o);
		}

		o = s.option(form.ListValue, 'native_classification_mode', _('Base routing policy'));
		o.value('compatible', _('Selective routing (rules only)'));
		o.value('strict', _('Strict routing'));
		o.default = 'compatible';
		o.rmempty = false;
		o.retain = true;
		nativeDepends(o);
		o.description = _('Selective routing is the default: only enabled rules and presets choose a proxy. Main and backup roles alone do not route all traffic.');

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
		nativeDepends(o, {native_classification_mode: 'strict'});
		nativeDepends(o, {native_migration_restrict_unknown: '1'});
		o.description = _('Unknown traffic uses an available Main or Backup transport supporting the protocol. If none is available, it is blocked. This does not identify its domain.');

		o = s.option(form.DummyValue, '_native_compatible_warning', _('Warning'));
		nativeDepends(o, {native_classification_mode: 'compatible', native_migration_restrict_unknown: '0'});
		o.cfgvalue = function() { return _('Selective routing depends on router DNS. Cached real IPs, third-party DoH and literal IPs can bypass domain-only rules.'); };

		o = s.option(form.Flag, 'native_migration_restrict_unknown', _('Migration restriction (overrides selective routing)'));
		o.default = '0';
		o.rmempty = false;
		o.retain = true;
		nativeDepends(o);
		o.description = _('When enabled, traffic outside the rules is protected or blocked even when the base policy is selective.');

		o = s.option(form.DummyValue, '_native_migration_warning', _('Warning'));
		nativeDepends(o, {native_migration_restrict_unknown: '1'});
		o.cfgvalue = function() { return _('Migration restriction is enabled. Unmatched traffic is not direct.'); };

		o = s.option(form.Flag, 'native_direct_grants_confirmed', _('Confirm whole-address and whole-device direct exceptions'));
		o.default = '0';
		o.rmempty = false;
		o.retain = true;
		nativeDepends(o, {native_classification_mode: 'strict'});
		nativeDepends(o, {native_migration_restrict_unknown: '1'});
		o.description = _('Direct IP/CIDR, endpoint and LAN-device exceptions override domain protection for that address or device. Confirm them only after reviewing the complete exception list.') + ' ' +
			_('A shared CDN IP may serve multiple domains; a direct IP exception covers all of them.');

		o = s.option(form.DummyValue, '_native_strict_warning', _('Strict direct policy'));
		nativeDepends(o, {native_classification_mode: 'strict'});
		nativeDepends(o, {native_migration_restrict_unknown: '1'});
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
			return E(legacy ? [ node, migrationPanel(), buttons ] : [ node, buttons ]);
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
