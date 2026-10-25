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

function connectionCard(item, actions) {
	var valid = item.status === 'valid';
	return E('article', { 'class': 'cbi-section', 'data-awg-id': item.id,
		'style': 'border:1px solid var(--border-color-medium,#ccc);border-radius:4px;padding:12px;margin:0 0 12px;min-width:0' }, [
		E('h3', { 'style': 'margin:0 0 6px;overflow-wrap:anywhere' }, item.name),
		E('div', {}, 'AmneziaWG 3.1'),
		E('div', { 'style': 'overflow-wrap:anywhere' }, _('Identifier') + ': ' + item.id),
		E('div', { 'style': 'overflow-wrap:anywhere' }, _('Endpoint') + ': ' + (item.endpoints || []).join(', ')),
		E('div', {}, _('Added on') + ': ' + dateText(item.created_at)),
		E('div', { 'style': 'color:' + (valid ? '#2e7d32' : '#c62828') }, valid ? _('Configuration is valid') : _('Configuration needs attention')),
		E('div', {}, _('Last configuration check') + ': ' + dateText(item.checked_at)),
		E('div', { 'style': 'display:flex;gap:8px;flex-wrap:wrap;margin-top:10px' }, [
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
	},

	render: function(data) {
		var self = this;
		this.list = E('div', { 'class': 'podkopchik-awg-list' });
		this.updateList(data);
		return E('div', {}, [
			E('h2', {}, 'Podkopchik'),
			E('h3', {}, _('AmneziaWG')),
			E('p', { 'class': 'alert-message warning' }, _('Configuration management only. AWG tunnels, connectivity checks and routing are not enabled in this phase.')),
			this.list,
			E('button', { 'class': 'cbi-button cbi-button-add', 'click': function() { self.editConnection(null); } }, _('Import .conf'))
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
