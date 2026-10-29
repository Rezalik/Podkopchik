'use strict';
'require view';
'require rpc';
'require ui';

var MAX_CONFIG = 65536;
var callList = rpc.declare({ object: 'podkopchik.awg', method: 'list', expect: { '': {} } });
var callImport = rpc.declare({ object: 'podkopchik.awg', method: 'import', params: [ 'name', 'config' ], expect: { '': {} } });
var callReplace = rpc.declare({ object: 'podkopchik.awg', method: 'replace', params: [ 'id', 'name', 'config' ], expect: { '': {} } });
var callRename = rpc.declare({ object: 'podkopchik.awg', method: 'rename', params: [ 'id', 'name' ], expect: { '': {} } });
var callValidate = rpc.declare({ object: 'podkopchik.awg', method: 'validate', params: [ 'id' ], expect: { '': {} } });
var callDelete = rpc.declare({ object: 'podkopchik.awg', method: 'delete', params: [ 'id' ], expect: { '': {} } });
var callStart = rpc.declare({ object: 'podkopchik.awg', method: 'start', params: [ 'id' ], expect: { '': {} } });
var callStop = rpc.declare({ object: 'podkopchik.awg', method: 'stop', params: [ 'id' ], expect: { '': {} } });
var callRestart = rpc.declare({ object: 'podkopchik.awg', method: 'restart', params: [ 'id' ], expect: { '': {} } });
var callCheck = rpc.declare({ object: 'podkopchik.awg', method: 'check', params: [ 'id' ], expect: { '': {} } });
var callAssign = rpc.declare({ object: 'podkopchik.awg', method: 'assign', params: [ 'tag', 'role', 'priority' ], expect: { '': {} } });
var callRecover = rpc.declare({ object: 'podkopchik.awg', method: 'recover', expect: { '': {} } });
var callSetInterception = rpc.declare({ object: 'podkopchik.awg', method: 'set_interception', params: [ 'udp', 'ipv6' ], expect: { '': {} } });
var callSetProbe = rpc.declare({ object: 'podkopchik.awg', method: 'set_probe', params: [ 'id', 'url', 'address', 'timeout' ], expect: { '': {} } });

function errorText(result) {
	var errors = {
		size: _('Choose a non-empty .conf file no larger than 64 KiB.'),
		syntax: _('Invalid configuration syntax.'),
		section: _('Only one Interface section followed by Peer sections is supported.'),
		unsupported: _('Unsupported directive. Commands, hooks and file paths are not allowed.'),
		duplicate: _('Duplicate configuration parameter.'),
		value: _('Invalid configuration parameter.'),
		private_key: _('The Interface section must contain a valid PrivateKey.'),
		peer: _('At least one Peer section is required.'),
		required: _('A required Peer parameter is missing.'),
		security: _('AdvancedSecurity cannot be disabled for an AWG connection.'),
		not_awg31: _('No AWG 3.1 parameters found. Plain WireGuard and older AWG profiles are not accepted here.'),
		padding: _('HeaderProtectionKey requires S1, S2, S3 and S4 to be at least 12.'),
		range: _('Jmin must not exceed Jmax.'),
		headers: _('H1, H2, H3 and H4 ranges must not overlap.'),
		name: _('Enter a connection name of at most 128 bytes without control characters.'),
		id: _('Invalid connection identifier.'),
		missing: _('This connection no longer exists. Refresh the list.'),
		storage: _('Could not access protected AWG storage. Check permissions and free space.'),
		busy: _('Another AWG operation is running. Try again.'),
		limit: _('At most 10 AWG interfaces can be started at the same time.'),
		https_or_handshake: _('HTTPS or handshake verification failed.'),
		component: _('Required AWG 3.1 tools or kernel support is unavailable.'),
		rpf: _('Strict global reverse-path filtering is unsupported. No global network setting was changed.'),
		network: _('AWG network operation failed. The new connection was not selected.'),
		conflict: _('An interface, routing table or policy rule is already owned by another service.'),
		address: _('The AWG profile needs an Interface Address.'),
		address_missing: _('A configured AWG address is missing from the interface. Restart the connection and check the profile.'),
		address_conflict: _('The AWG address overlaps an existing LAN, WAN or tunnel network.'),
		ipv6_requires_extension: _('An IPv6-only AWG profile requires IPv6 LAN interception before assigning a role.'),
		ipv6_lan: _('IPv6 interception requires a usable IPv6 address on the LAN interface.'),
		ipv6_unsupported: _('Every enabled AWG profile needs an IPv6 address and AllowedIPs ::/0 before enabling IPv6 interception.'),
		ipv6_route: _('The AWG IPv6 interface address or isolated default route is missing.'),
		ipv6_probe: _('The IPv6 HTTPS check failed. IPv6 interception was not enabled.'),
		probe_settings: _('Use an HTTPS hostname URL, a literal probe IP and a timeout from 1 to 30 seconds.'),
		roles: _('Select one main connection and unique backup priorities from 1 to 3.'),
		unhealthy: _('Handshake and HTTPS must succeed before this connection can be selected.'),
		in_use: _('This profile is in use. Remove its routing assignments and stop it before replacing or deleting it.'),
		apply_failed: _('Connection apply failed. The previous configuration was restored.'),
		rollback_failed: _('Automatic recovery failed. Keep SSH open and restore the saved backup.'),
		recovery_required: _('An interrupted connection change needs recovery. Use Recover connection change.'),
		request: _('Invalid AWG request.')
	};
	var text = errors[result.error] || _('AWG operation failed.');
	if (result.line)
		text += ' ' + _('Line %d.').format(Number(result.line));
	if (result.field)
		text += ' ' + _('Parameter: %s.').format(result.field);
	return text;
}

function readConf(file) {
	if (!file || !/\.conf$/i.test(file.name) || !file.size || file.size > MAX_CONFIG)
		return Promise.reject(new Error(errorText({ error: 'size' })));
	return file.text();
}

function dateText(timestamp) {
	return timestamp ? new Date(Number(timestamp) * 1000).toLocaleString() : _('Not checked yet');
}

function roleText(role, priority) {
	if (role == 'main') return _('Main proxy');
	if (role == 'backup') return _('Backup #%d').format(Number(priority));
	if (role == 'rules_only') return _('Rules only');
	return _('Disabled');
}

function runtimeText(runtime) {
	if (runtime.status == 'up' && runtime.checked_at && Date.now() / 1000 - runtime.checked_at < 300)
		return _('Available');
	if (runtime.status == 'down') return _('Unavailable');
	return _('Not checked yet');
}

function connectionCard(item, actions) {
	var valid = item.status === 'valid';
	var runtime = item.runtime || {};
	return E('article', { 'class': 'cbi-section', 'data-awg-id': item.id,
		'style': 'border:1px solid var(--border-color-medium,#ccc);border-radius:4px;padding:12px;margin:0 0 12px;min-width:0' }, [
		E('h3', { 'style': 'margin:0 0 6px;overflow-wrap:anywhere' }, item.name),
		E('div', {}, 'AmneziaWG 3.1'),
		E('div', { 'style': 'overflow-wrap:anywhere' }, _('Identifier') + ': ' + item.id),
		E('div', { 'style': 'overflow-wrap:anywhere' }, _('Endpoint') + ': ' + (item.endpoints || []).join(', ')),
		E('div', {}, _('Added on') + ': ' + dateText(item.created_at)),
		E('div', { 'style': 'color:' + (valid ? '#2e7d32' : '#c62828') }, valid ? _('Configuration is valid') : _('Configuration needs attention')),
		E('div', {}, _('Last configuration check') + ': ' + dateText(item.checked_at)),
		E('div', {}, _('Role') + ': ' + roleText(item.role, item.priority)),
		E('div', {}, _('Interface') + ': ' + (runtime.running ? _('Started') : _('Stopped'))),
		E('div', { 'style': 'color:' + (runtimeText(runtime) == _('Available') ? '#2e7d32' : runtime.status == 'down' ? '#c62828' : '#6b7280') }, runtimeText(runtime)),
		runtime.reason && runtime.reason != 'stopped' && runtime.reason != 'not_checked' ? E('div', {}, _('Technical details') + ': ' + errorText({ error: runtime.reason })) : '',
		E('div', {}, _('Last handshake') + ': ' + (runtime.handshake_at ? dateText(runtime.handshake_at) : _('No handshake yet'))),
		runtime.latency_ms != null ? E('div', {}, _('HTTPS latency') + ': ' + Number(runtime.latency_ms) + ' ms') : '',
		runtime.external_ip ? E('div', {}, _('External IP') + ': ' + runtime.external_ip) : '',
		E('div', {}, _('Last checked') + ': ' + dateText(runtime.checked_at)),
		E('div', {}, _('Last successful check') + ': ' + dateText(runtime.last_success_at)),
		runtime.rx_bytes != null ? E('div', {}, _('Received / sent') + ': ' + Number(runtime.rx_bytes) + ' / ' + Number(runtime.tx_bytes) + ' B') : '',
		E('div', { 'style': 'display:flex;gap:8px;flex-wrap:wrap;margin-top:10px' }, [
			E('button', { 'class': 'cbi-button', 'click': function() { actions.start(item); } }, _('Start')),
			E('button', { 'class': 'cbi-button', 'click': function() { actions.stop(item); } }, _('Stop')),
			E('button', { 'class': 'cbi-button', 'click': function() { actions.restart(item); } }, _('Restart')),
			E('button', { 'class': 'cbi-button', 'click': function() { actions.check(item); } }, _('Check connection')),
			E('button', { 'class': 'cbi-button', 'click': function() { actions.assign(item); } }, _('Connection role')),
			E('button', { 'class': 'cbi-button', 'click': function() { actions.probe(item); } }, _('Check settings')),
			E('button', { 'class': 'cbi-button', 'click': function() { actions.edit(item); } }, _('Edit')),
			E('button', { 'class': 'cbi-button', 'click': function() { actions.validate(item); } }, _('Check configuration')),
			E('button', { 'class': 'cbi-button cbi-button-negative', 'click': function() { actions.remove(item); } }, _('Delete'))
		])
	]);
}

return view.extend({
	load: function() { return callList(); },

	perform: function(operation, success) {
		var self = this;
		if (this.busy) return Promise.resolve();
		this.busy = true;
		return Promise.resolve().then(operation).then(function(result) {
			if (!result.ok) throw new Error(errorText(result));
			ui.hideModal();
			ui.addNotification(null, E('p', {}, success), 'info');
			return callList().then(function(data) { self.updateList(data); });
		}).catch(function(error) {
			ui.addNotification(null, E('p', {}, error.message || _('AWG operation failed.')), 'error');
		}).finally(function() { self.busy = false; });
	},

	editConnection: function(item) {
		var self = this;
		var name = E('input', { 'type': 'text', 'value': item ? item.name : '', 'maxlength': 128, 'style': 'width:100%' });
		var file = E('input', { 'type': 'file', 'accept': '.conf', 'style': 'max-width:100%' });
		ui.showModal(item ? _('Edit AWG connection') : _('Import AWG connection'), [
			E('label', {}, [ _('Name'), name ]),
			E('label', { 'style': 'display:block;margin-top:12px' }, [ item ? _('Replacement .conf file (optional)') : _('Configuration file (.conf)'), file ]),
			E('p', {}, _('Private keys are stored only on the router. Existing keys are never displayed.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', { 'class': 'cbi-button cbi-button-positive', 'click': function() {
					self.perform(function() {
						var displayName = name.value.trim();
						if (!displayName || new TextEncoder().encode(displayName).length > 128)
							throw new Error(errorText({ error: 'name' }));
						if (item && !file.files.length) return callRename(item.id, displayName);
						return readConf(file.files[0]).then(function(config) {
							return item ? callReplace(item.id, displayName, config) : callImport(displayName, config);
						});
					}, item ? _('AWG connection saved.') : _('AWG configuration imported. No tunnel was started.'));
				} }, item ? _('Save') : _('Import'))
			])
		]);
	},

	assignConnection: function(item) {
		var self = this;
		var role = E('select', {}, [
			E('option', { value: 'main' }, _('Main proxy')),
			E('option', { value: 'backup' }, _('Backup proxy')),
			E('option', { value: 'rules_only' }, _('Rules only')),
			E('option', { value: 'disabled' }, _('Disabled'))
		]);
		var priority = E('select', {}, [1, 2, 3].map(function(n) { return E('option', { value: String(n) }, String(n)); }));
		role.value = item.role || 'rules_only';
		priority.value = String(item.priority || 1);
		var priorityRow = E('label', { style: 'display:block;margin-top:8px' }, [ _('Backup priority'), priority ]);
		function toggle() { priorityRow.style.display = role.value == 'backup' ? '' : 'none'; }
		role.addEventListener('change', toggle);
		toggle();
		ui.showModal(_('Connection role'), [
			E('p', {}, item.name),
			E('label', {}, [ _('Role'), role ]), priorityRow,
			E('p', {}, _('Main and backup selection requires a successful check. Domain and IP rules keep their existing targets.')),
			E('div', { class: 'right' }, [
				E('button', { class: 'cbi-button', click: ui.hideModal }, _('Cancel')), ' ',
				E('button', { class: 'cbi-button cbi-button-positive', click: function() {
					self.perform(function() { return callAssign(item.tag || 'awg_' + item.id, role.value, priority.value); }, _('Connection role applied.'));
				} }, _('Apply settings'))
			])
		]);
	},

	probeSettings: function(item) {
		var self = this, probe = item.probe || {};
		var url = E('input', { type: 'text', value: probe.url || 'https://one.one.one.one/cdn-cgi/trace', style: 'width:100%' });
		var defaultIP = item.runtime && item.runtime.addresses && item.runtime.addresses.indexOf('.') < 0 ? '2606:4700:4700::1111' : '1.1.1.1';
		var address = E('input', { type: 'text', value: probe.address || defaultIP, style: 'width:100%' });
		var timeout = E('input', { type: 'number', min: 1, max: 30, value: probe.timeout || 10 });
		ui.showModal(_('Check settings'), [
			E('label', {}, [ _('Probe URL'), url ]),
			E('label', { style: 'display:block;margin-top:8px' }, [ _('Probe IP address'), address ]),
			E('label', { style: 'display:block;margin-top:8px' }, [ _('Health timeout'), timeout ]),
			E('p', {}, _('The probe IP is pinned to avoid WAN DNS. HTTPS certificate verification remains enabled.')),
			E('div', { class: 'right' }, [
				E('button', { class: 'cbi-button', click: ui.hideModal }, _('Cancel')), ' ',
				E('button', { class: 'cbi-button cbi-button-positive', click: function() {
					self.perform(function() { return callSetProbe(item.id, url.value, address.value, timeout.value); }, _('Check settings saved.'));
				} }, _('Save'))
			])
		]);
	},

	updateList: function(data) {
		var self = this;
		this.list.replaceChildren();
		if (!data.ok) {
			this.list.appendChild(E('p', { 'class': 'alert-message warning' }, errorText(data)));
			return;
		}
		if (!(data.connections || []).length)
			this.list.appendChild(E('p', {}, _('No AWG configurations imported.')));
		(data.connections || []).forEach(function(item) {
			self.list.appendChild(connectionCard(item, {
				start: function(entry) { self.perform(function() { return callStart(entry.id); }, _('AWG interface started. Check the connection before using it.')); },
				stop: function(entry) { self.perform(function() { return callStop(entry.id); }, _('AWG interface stopped. Selected traffic remains blocked until failover.')); },
				restart: function(entry) { self.perform(function() { return callRestart(entry.id); }, _('AWG interface restarted.')); },
				check: function(entry) { self.perform(function() { return callCheck(entry.id); }, _('Connection check completed. See the measured result.')); },
				assign: function(entry) { self.assignConnection(entry); },
				probe: function(entry) { self.probeSettings(entry); },
				edit: function(entry) { self.editConnection(entry); },
				validate: function(entry) { self.perform(function() { return callValidate(entry.id); }, _('Configuration is valid')); },
				remove: function(entry) {
					ui.showModal(_('Delete AWG connection'), [
						E('p', {}, _('Delete this AWG configuration? This cannot be undone.')),
						E('p', { 'style': 'overflow-wrap:anywhere' }, entry.name),
						E('div', { 'class': 'right' }, [
							E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')), ' ',
							E('button', { 'class': 'cbi-button cbi-button-negative', 'click': function() {
								self.perform(function() { return callDelete(entry.id); }, _('AWG connection deleted.'));
							} }, _('Delete'))
						])
					]);
				}
			}));
		});
		(data.routing_connections || []).filter(function(item) { return item.protocol != 'amneziawg'; }).forEach(function(item) {
			self.list.appendChild(E('div', { style: 'display:flex;gap:12px;flex-wrap:wrap;align-items:center;margin-bottom:8px' }, [
				E('span', {}, item.name + ' · VLESS · ' + roleText(item.role, item.priority)),
				E('span', {}, runtimeText(item.health || {})),
				item.health && item.health.latency_ms != null ? E('span', {}, _('HTTPS latency') + ': ' + Number(item.health.latency_ms) + ' ms') : '',
				item.traffic ? E('span', {}, _('Received / sent') + ': ' + Number(item.traffic.downlink) + ' / ' + Number(item.traffic.uplink) + ' B') :
					E('span', {}, _('Traffic counters unavailable')),
				E('button', { class: 'cbi-button', click: function() { self.assignConnection(item); } }, _('Connection role'))
			]));
		});
	},

	render: function(data) {
		var self = this;
		this.list = E('div', { 'class': 'podkopchik-awg-list' });
		this.updateList(data);
		// Boolean HTML attributes are true even when their text is "false".
		// Set DOM properties after creation, never checked=false attributes.
		var udp = E('input', { type: 'checkbox' }), ipv6 = E('input', { type: 'checkbox' });
		function sync(current) {
			udp.checked = current.udp_interception === true;
			ipv6.checked = current.ipv6_interception === true;
		}
		sync(data);
		function change() {
			udp.disabled = ipv6.disabled = true;
			self.perform(function() { return callSetInterception(udp.checked ? '1' : '0', ipv6.checked ? '1' : '0'); }, _('Interception settings applied.')).then(function() {
				return callList().then(sync);
			}).finally(function() { udp.disabled = ipv6.disabled = false; });
		}
		udp.addEventListener('change', change);
		ipv6.addEventListener('change', change);
		return E('div', {}, [
			E('h2', {}, 'Podkopchik'),
			E('h3', {}, _('AmneziaWG')),
			E('p', { 'class': 'alert-message warning' }, _('Experimental AWG integration. UDP and IPv6 interception are off by default and can be enabled independently. Disabled protocols are not protected by transparent routing.')),
			E('div', {}, E('label', {}, [ udp, ' ', _('UDP LAN interception (experimental)') ])),
			E('div', {}, E('label', {}, [ ipv6, ' ', _('IPv6 LAN interception (experimental)') ])),
			this.list,
			E('button', { 'class': 'cbi-button cbi-button-add', 'click': function() { self.editConnection(null); } }, _('Import .conf')),
			' ',
			E('button', { class: 'cbi-button', click: function() { self.perform(function() { return callRecover(); }, _('Connection change recovered.')); } }, _('Recover connection change'))
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
