'use strict';
'require view';
'require fs';
'require ui';
'require uci';

var AUTO_GROUP_TAG = 'auto_proxy_group';
var MAX_SIMPLE_PROXIES = 10;
var MAX_ACTIVE_BACKUPS = 3;
var CHECK_VALID_FOR = 300;
var checks = Object.create(null);
var probeQueue = Promise.resolve();

function freshCheck(item) {
	var age = Math.floor(Date.now() / 1000) - Number(item && item.checked_at || 0);
	return item && item.checked_at && age >= 0 && age < Number(item.valid_for || CHECK_VALID_FOR);
}

function checkReason(reason) {
	var labels = {
		invalid_configuration: _('Invalid connection configuration'),
		missing_component: _('A required component is missing'),
		busy: _('Another connection check is running'),
		port_in_use: _('The local check port is busy'),
		probe_start_failed: _('The isolated connection check could not start'),
		server_unavailable: _('The proxy server could not be reached'),
		internet_unavailable: _('Internet access through this connection failed'),
		timeout: _('Connection check timed out'),
		dns_error: _('Connection check DNS error'),
		external_ip_error: _('Could not verify the external IP address')
	};
	return labels[reason] || _('Connection has not been checked yet');
}

function checkUri(uri) {
	probeQueue = probeQueue.catch(function() {}).then(function() {
		return fs.exec('/usr/bin/podkopchikctl', [ 'probe-vless' ], { PODKOPCHIK_PROBE_URI: uri });
	}).then(function(res) {
		if (res.code !== 0)
			throw new Error(_('The isolated connection check could not start'));
		var result = JSON.parse(res.stdout || '{}');
		checks[uri] = result;
		return result;
	}).catch(function() {
		var result = { status: 'unknown', reason: 'probe_start_failed', checked_at: Math.floor(Date.now() / 1000), valid_for: CHECK_VALID_FOR };
		checks[uri] = result;
		return result;
	});
	return probeQueue;
}

function checkBeforeSave(items) {
	return items.reduce(function(chain, item) {
		return chain.then(function() {
			if (freshCheck(checks[item.uri]))
				return;
			return checkUri(item.uri);
		});
	}, Promise.resolve());
}

function runApply() {
	return fs.exec_direct('/usr/bin/podkopchikctl', [ 'apply' ]);
}

function proxyTag(p) {
	return p.tag || p.name || '';
}

function proxyRole(p) {
	if (p.role == 'main' || p.role == 'backup' || p.role == 'disabled' || p.role == 'rules_only')
		return p.role;

	return p.enabled == '0' ? 'disabled' : 'backup';
}

function backupPriority(p) {
	var n = parseInt(p.backup_priority || '1', 10);
	return n >= 1 && n <= MAX_ACTIVE_BACKUPS ? n : 1;
}

function shortUri(uri) {
	var m = (uri || '').match(/^vless:\/\/[^@]+@([^?#]+)/i);

	return m ? 'vless://••••••@' + m[1] : _('VLESS link saved');
}

function detectedText(p) {
	var parts = [];

	if (p.detected_transport)
		parts.push(String(p.detected_transport).toUpperCase());

	if (p.detected_security)
		parts.push(String(p.detected_security).charAt(0).toUpperCase() + String(p.detected_security).slice(1));

	return parts.join(' · ');
}

function readState() {
	return fs.read_direct('/tmp/podkopchik/state.json').then(function(text) {
		try {
			return JSON.parse(text || '{}');
		}
		catch (e) {
			return {};
		}
	}).catch(function() {
		return {};
	});
}

function healthFor(state, tag) {
	var canonical = String(tag || '').toLowerCase().replace(/[^a-z0-9_]+/g, '_');
	var item = state && state.proxies && tag ? state.proxies[canonical] : null;
	var fresh = freshCheck(item);
	var status = fresh && item.status ? item.status : 'unknown';

	return {
		status: status,
		latency: fresh && item.latency_ms != null ? item.latency_ms : null,
		external_ip: fresh && item.external_ip || '',
		checked_at: item && item.checked_at || 0,
		stale: !!item && !fresh
	};
}

function healthLabel(health) {
	if (health.status == 'up')
		return _('Available');

	if (health.status == 'down')
		return _('Unavailable');

	return _('Not checked yet');
}

function healthTone(health) {
	if (health.status == 'up')
		return '#2e7d32';

	if (health.status == 'down')
		return '#c62828';

	return '#6b7280';
}

function roleLabel(role) {
	if (role == 'rules_only') return _('Rules only');
	if (role == 'main')
		return _('Main proxy');

	if (role == 'backup')
		return _('Backup proxy');

	return _('Disabled');
}

function priorityLabel(priority) {
	return _('Backup #%d').format(priority);
}

function collectProxyItems(state) {
	return (uci.sections('podkopchik', 'proxy') || []).filter(function(p) {
		return p.protocol != 'amneziawg';
	}).map(function(p, idx) {
		var tag = proxyTag(p);
		var role = proxyRole(p);

		return {
			sid: p['.name'] || '',
			name: p.name || tag || _('Proxy link'),
			tag: tag,
			uri: p.uri || '',
			role: role,
			enabled: role == 'disabled' ? '0' : '1',
			backup_priority: String(backupPriority(p)),
			note: p.note || '',
			detected_transport: p.detected_transport || '',
			detected_security: p.detected_security || '',
			health: healthFor(state, tag),
			index: idx
		};
	});
}

function readCard(card) {
	var role = card.querySelector('[data-field="role"]').value;

	return {
		sid: card.getAttribute('data-sid') || '',
		name: card.querySelector('[data-field="name"]').value.trim(),
		tag: card.querySelector('[data-field="tag"]').value.trim(),
		uri: card.querySelector('[data-field="uri"]').value.trim(),
		role: role,
		enabled: role == 'disabled' ? '0' : '1',
		backup_priority: role == 'backup' ? card.querySelector('[data-field="backup_priority"]').value : '',
		note: card.querySelector('[data-field="note"]').value.trim()
	};
}

function readCards() {
	var items = Array.prototype.map.call(document.querySelectorAll('.podkopchik-proxy-card'), readCard).filter(function(item) {
		return item.sid || item.name || item.tag || item.uri || item.note;
	});
	var tags = {};

	items.forEach(function(item) {
		if (!item.name)
			throw new Error(_('Proxy name is required.'));

		if (!item.tag)
			throw new Error(_('Proxy tag is required.'));

		if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(item.tag))
			throw new Error(_('Proxy tag can contain only letters, numbers, and underscores, and must not start with a number.'));

		if (tags[item.tag])
			throw new Error(_('Duplicate proxy tag: %s').format(item.tag));

		if (!item.uri)
			throw new Error(_('VLESS URI is required.'));

		if (!/^vless:\/\//i.test(item.uri))
			throw new Error(_('VLESS URI must start with vless://.'));

		tags[item.tag] = true;
	});

	return items;
}

function roleState(items) {
	items = items.concat((uci.sections('podkopchik', 'proxy') || []).filter(function(p) {
		return p.protocol == 'amneziawg';
	}).map(function(p) {
		return { tag: p.tag, role: p.enabled == '0' ? 'disabled' : p.role, backup_priority: p.backup_priority };
	}));
	var main = [];
	var backups = [];
	var priorities = {};
	var duplicatePriority = false;

	items.forEach(function(p) {
		if (!p.tag || p.role == 'disabled')
			return;

		if (p.role == 'main') {
			main.push(p.tag);
			return;
		}

		if (p.role != 'backup') return;
		var priority = parseInt(p.backup_priority || '1', 10) || 1;
		backups.push({
			tag: p.tag,
			priority: priority
		});

		if (priorities[priority])
			duplicatePriority = true;

		priorities[priority] = true;
	});

	backups.sort(function(a, b) {
		if (a.priority != b.priority)
			return a.priority - b.priority;

		return a.tag < b.tag ? -1 : (a.tag > b.tag ? 1 : 0);
	});

	return {
		main: main,
		backups: backups,
		duplicatePriority: duplicatePriority
	};
}

function warningMessages(items) {
	var state = roleState(items);
	var warnings = [];

	if (items.length > MAX_SIMPLE_PROXIES)
		warnings.push(_('Simple mode supports up to 10 proxy links. Disable or delete unused links.'));

	if (state.main.length == 0)
		warnings.push(_('Select one main proxy.'));
	else if (state.main.length > 1)
		warnings.push(_('Only one main proxy can be selected.'));

	if (state.duplicatePriority)
		warnings.push(_('Backup priorities must be unique.'));

	if (state.backups.length > MAX_ACTIVE_BACKUPS)
		warnings.push(_('Current backend supports up to 3 active backup proxies. Disable extra backups or keep them unused.'));

	return warnings;
}

function canMaintainAutoGroup(items) {
	return warningMessages(items).filter(function(w) {
		return w != _('Simple mode supports up to 10 proxy links. Disable or delete unused links.');
	}).length == 0;
}

function findAutoGroup() {
	var found = null;

	(uci.sections('podkopchik', 'proxy_group') || []).forEach(function(g) {
		if ((g.tag || '') == AUTO_GROUP_TAG && !found)
			found = g['.name'];
	});

	return found;
}

function removeDuplicateAutoGroups(primary_sid) {
	(uci.sections('podkopchik', 'proxy_group') || []).forEach(function(g) {
		var sid = g['.name'];

		if ((g.tag || '') == AUTO_GROUP_TAG && sid != primary_sid)
			uci.remove('podkopchik', sid);
	});
}

function clearAutoGroup(sid) {
	uci.set('podkopchik', sid, 'enabled', '0');
	uci.set('podkopchik', sid, 'name', 'Automatic proxy group');
	uci.set('podkopchik', sid, 'tag', AUTO_GROUP_TAG);
	uci.set('podkopchik', sid, 'mode', 'strict_primary');
	uci.set('podkopchik', sid, 'auto_return', '1');
	uci.set('podkopchik', sid, 'failure_action', 'switch_to_backup');
	uci.unset('podkopchik', sid, 'primary');
	uci.unset('podkopchik', sid, 'manual_override_proxy');
	uci.unset('podkopchik', sid, 'fixed_proxy');

	for (var i = 1; i <= MAX_ACTIVE_BACKUPS; i++)
		uci.unset('podkopchik', sid, 'backup%d'.format(i));
}

function maintainAutoGroup(items) {
	var existing = findAutoGroup();

	if (!canMaintainAutoGroup(items)) {
		if (existing) {
			removeDuplicateAutoGroups(existing);
			clearAutoGroup(existing);
		}

		return;
	}

	var state = roleState(items);
	var sid = existing || uci.add('podkopchik', 'proxy_group');

	removeDuplicateAutoGroups(sid);
	clearAutoGroup(sid);
	uci.set('podkopchik', sid, 'enabled', '1');
	uci.set('podkopchik', sid, 'primary', state.main[0]);

	for (var i = 0; i < MAX_ACTIVE_BACKUPS; i++) {
		if (state.backups[i])
			uci.set('podkopchik', sid, 'backup%d'.format(i + 1), state.backups[i].tag);
	}
}

function updatePriorityVisibility(card) {
	var role = card.querySelector('[data-field="role"]').value;
	var row = card.querySelector('[data-field-row="backup_priority"]');

	row.style.display = role == 'backup' ? '' : 'none';
}

function updateWarnings() {
	var box = document.getElementById('podkopchik-proxy-warnings');
	var warnings = warningMessages(readCards());

	if (!box)
		return;

	while (box.firstChild)
		box.removeChild(box.firstChild);

	box.style.display = warnings.length ? '' : 'none';

	warnings.forEach(function(warning) {
		box.appendChild(E('div', warning));
	});
}

function input(field, value, type) {
	return E('input', {
		'class': 'cbi-input-text',
		'data-field': field,
		'type': type || 'text',
		'value': value || ''
	});
}

function formRow(label, node, fieldName) {
	return E('div', {
		'class': 'cbi-value',
		'data-field-row': fieldName || null,
		'style': 'margin-bottom:10px'
	}, [
		E('label', { 'class': 'cbi-value-title', 'style': 'display:block; margin-bottom:4px' }, label),
		E('div', { 'class': 'cbi-value-field' }, node)
	]);
}

function option(value, label, selected) {
	return E('option', {
		'value': value,
		'selected': selected ? 'selected' : null
	}, label);
}

function renderCard(item, open) {
	var role = item.role || 'backup';
	var health = item.health || { status: 'unknown' };
	var meta = detectedText(item);
	var editPanel;
	var availability = E('span', { 'style': 'color:%s'.format(healthTone(health)) }, healthLabel(health));
	var metrics = E('span', { 'style': 'display:inline-flex;gap:8px;flex-wrap:wrap;color:#6b7280' }, [
		health.latency != null ? E('span', _('HTTPS check latency: %d ms').format(health.latency)) : '',
		health.external_ip ? E('span', _('External IP: %s').format(health.external_ip)) : '',
		health.checked_at ? E('span', (health.stale ? _('Check result is outdated') + ': ' : '') + new Date(health.checked_at * 1000).toLocaleString()) : ''
	]);
	if (health.checked_at && !health.stale) {
		window.setTimeout(function() {
			availability.textContent = _('Check result is outdated');
			availability.style.color = '#6b7280';
			metrics.textContent = '';
		}, Math.max(0, (health.checked_at + CHECK_VALID_FOR) * 1000 - Date.now()));
	}
	var roleSelect = E('select', {
		'class': 'cbi-input-select',
		'data-field': 'role',
		'change': function(ev) {
			var card = ev.currentTarget.closest('.podkopchik-proxy-card');
			updatePriorityVisibility(card);
			updateWarnings();
		}
	}, [
		option('main', _('Main proxy'), role == 'main'),
		option('backup', _('Backup proxy'), role == 'backup'),
		option('rules_only', _('Rules only'), role == 'rules_only'),
		option('disabled', _('Disabled'), role == 'disabled')
	]);

	var prioritySelect = E('select', { 'class': 'cbi-input-select', 'data-field': 'backup_priority' }, [
		option('1', '1', item.backup_priority == '1'),
		option('2', '2', item.backup_priority == '2'),
		option('3', '3', item.backup_priority == '3')
	]);

	var card = E('div', {
		'class': 'cbi-section podkopchik-proxy-card',
		'data-sid': item.sid || '',
		'style': 'border-left:4px solid #9ca3af; border-radius:8px; padding:14px; margin-bottom:12px'
	}, [
		E('div', { 'style': 'display:flex; justify-content:space-between; gap:12px; align-items:flex-start; flex-wrap:wrap' }, [
			E('div', { 'style': 'min-width:180px; max-width:100%' }, [
				E('div', { 'style': 'font-weight:700; font-size:15px; overflow-wrap:anywhere' }, item.name || _('Proxy link')),
				E('div', { 'style': 'color:#6b7280; margin-top:3px; overflow-wrap:anywhere' }, item.tag || _('No tag')),
				E('div', { 'style': 'color:#6b7280; margin-top:3px; overflow-wrap:anywhere' }, shortUri(item.uri)),
				meta ? E('div', { 'style': 'color:#6b7280; margin-top:3px' }, meta) : ''
			]),
			E('div', { 'style': 'display:flex; gap:8px; flex-wrap:wrap; align-items:center' }, [
				E('span', { 'class': 'badge', 'style': 'background:#eef2ff; color:#3730a3; padding:3px 7px; border-radius:999px' }, roleLabel(role)),
				role == 'backup' ? E('span', { 'class': 'badge', 'style': 'background:#fef3c7; color:#92400e; padding:3px 7px; border-radius:999px' }, priorityLabel(item.backup_priority || '1')) : '',
				availability,
				metrics
			]),
			E('div', { 'style': 'display:flex; gap:6px; flex-wrap:wrap' }, [
				E('button', {
					'class': 'btn cbi-button',
					'click': function(ev) {
						ev.preventDefault();
						editPanel.style.display = editPanel.style.display == 'none' ? '' : 'none';
					}
				}, _('Edit')),
				E('button', {
					'class': 'btn cbi-button cbi-button-remove',
					'click': function(ev) {
						ev.preventDefault();
						ev.currentTarget.closest('.podkopchik-proxy-card').remove();
						updateWarnings();
					}
				}, _('Delete'))
			])
		])
	]);

	var checkOutput = E('div', { 'class': 'cbi-value-description', 'style': 'margin-bottom:10px' }, _('Connection has not been checked yet'));
	var checkButton;
	function runCheck() {
		var uri = card.querySelector('[data-field="uri"]').value.trim();
		if (!uri)
			return Promise.resolve();
		checkButton.disabled = true;
		checkOutput.textContent = _('Checking connection...');
		return checkUri(uri).then(function(result) {
			// Discard a result when the user edited the URI while the request ran.
			if (card.querySelector('[data-field="uri"]').value.trim() != uri)
				return;
			checkOutput.style.color = result.status == 'up' ? '#2e7d32' : (result.status == 'down' ? '#c62828' : '#6b7280');
			checkOutput.textContent = result.status == 'up'
				? _('Connection works') + '. ' + _('HTTPS check latency: %d ms').format(result.latency_ms) + '. ' + _('External IP: %s').format(result.external_ip)
				: checkReason(result.reason) + '. ' + _('You can still save this connection.');
			checkOutput.textContent += ' ' + _('Last checked: %s').format(new Date(result.checked_at * 1000).toLocaleString());
			window.setTimeout(function() {
				if (checks[uri] === result) {
					checkOutput.textContent = _('Check result is outdated');
					checkOutput.style.color = '#6b7280';
				}
			}, CHECK_VALID_FOR * 1000);
		}).finally(function() { checkButton.disabled = false; });
	}
	checkButton = E('button', { 'class': 'btn cbi-button', 'click': function(ev) {
		ev.preventDefault();
		return runCheck();
	} }, _('Check again'));

	editPanel = E('div', {
		'class': 'podkopchik-proxy-edit',
		'style': open ? 'margin-top:14px' : 'display:none; margin-top:14px'
	}, [
		formRow(_('Name'), input('name', item.name)),
		formRow(_('Tag'), input('tag', item.tag)),
		formRow(_('VLESS URI'), E('textarea', {
			'class': 'cbi-input-text',
			'data-field': 'uri',
			'rows': '6',
			'wrap': 'soft',
			'spellcheck': 'false',
			'change': runCheck,
			'paste': function() { window.setTimeout(runCheck, 0); },
			'style': 'width:100%; max-width:100%; min-height:128px; box-sizing:border-box; font-family:monospace; resize:vertical'
		}, item.uri || '')),
		E('div', { 'style': 'margin-bottom:10px' }, [ checkButton, checkOutput ]),
		formRow(_('Role'), roleSelect),
		formRow(_('Backup priority'), prioritySelect, 'backup_priority'),
		formRow(_('Note'), input('note', item.note)),
		detectedText(item) ? E('div', { 'class': 'cbi-value-description' }, _('Detected connection: %s').format(detectedText(item))) : ''
	]);

	card.appendChild(editPanel);
	updatePriorityVisibility(card);
	return card;
}

function writeProxiesToUci(items) {
	var original = {};

	(uci.sections('podkopchik', 'proxy') || []).forEach(function(p) {
		if (p.protocol != 'amneziawg') original[p['.name']] = true;
	});

	items.forEach(function(item) {
		var sid = item.sid || uci.add('podkopchik', 'proxy');

		delete original[sid];
		uci.set('podkopchik', sid, 'name', item.name);
		uci.set('podkopchik', sid, 'tag', item.tag);
		uci.set('podkopchik', sid, 'uri', item.uri);
		uci.set('podkopchik', sid, 'role', item.role);
		uci.set('podkopchik', sid, 'enabled', item.role == 'disabled' ? '0' : '1');
		uci.set('podkopchik', sid, 'note', item.note || '');

		if (item.role == 'backup')
			uci.set('podkopchik', sid, 'backup_priority', item.backup_priority || '1');
		else
			uci.unset('podkopchik', sid, 'backup_priority');
	});

	for (var sid in original)
		uci.remove('podkopchik', sid);

	maintainAutoGroup(items);
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('podkopchik'),
			readState()
		]);
	},

	render: function(data) {
		var state = data[1] || {};
		var items = collectProxyItems(state);
		var list = E('div', {
			'id': 'podkopchik-proxy-list',
			'data-renderer': 'compact-proxy-cards'
		}, items.map(function(item) {
			return renderCard(item, false);
		}));
		var warnings = E('div', {
			'id': 'podkopchik-proxy-warnings',
			'class': 'alert-message warning',
			'style': 'display:none; margin-bottom:12px'
		});
		var addButton = E('button', {
			'class': 'btn cbi-button cbi-button-add',
			'click': function(ev) {
				ev.preventDefault();

				if (document.querySelectorAll('.podkopchik-proxy-card').length >= MAX_SIMPLE_PROXIES) {
					updateWarnings();
					return;
				}

				list.appendChild(renderCard({
					sid: '',
					name: '',
					tag: '',
					uri: '',
					role: 'backup',
					backup_priority: '1',
					note: '',
					health: { status: 'unknown' }
				}, true));
				updateWarnings();
			}
		}, _('Add proxy link'));

		window.setTimeout(updateWarnings, 0);

		return E([
			E('h2', _('Proxy Links')),
			E('div', { 'class': 'cbi-map-descr' }, _('Add VLESS links, choose one main proxy and backups. Podkopchik will use the main proxy and switch to an available backup if needed.')),
			warnings,
			list,
			E('div', { 'class': 'cbi-section' }, addButton)
		]);
	},

	handleSave: function() {
		var items;
		try {
			items = readCards();
			var awgEnabled = (uci.sections('podkopchik', 'proxy') || []).some(function(p) { return p.protocol == 'amneziawg' && p.enabled != '0'; });
			if (awgEnabled && !canMaintainAutoGroup(items))
				throw new Error(_('Select one main connection and unique backup priorities from 1 to 3.'));
		}
		catch (e) {
			ui.addNotification(_('Validation error'), E('p', e.message || String(e)), 'error');
			return Promise.reject(e);
		}

		return checkBeforeSave(items).then(function() {
			writeProxiesToUci(items);
			var warnings = warningMessages(items);
			if (items.some(function(item) { return !checks[item.uri] || checks[item.uri].status != 'up'; }))
				warnings.push(_('Some connections could not be verified. Their settings will still be saved.'));
			if (warnings.length)
				ui.addNotification(_('Warning'), E('ul', warnings.map(function(w) { return E('li', w); })), 'warning');
			return uci.save();
		});
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
	},

	handleReset: function() {
		window.location.reload();
	}
});
