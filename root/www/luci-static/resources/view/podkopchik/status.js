'use strict';
'require view';
'require fs';
'require ui';
'require uci';

var COLORS = {
	ok: {
		background: '#edf7ed',
		border: '#2e7d32',
		text: '#1b5e20'
	},
	warning: {
		background: '#fff8e1',
		border: '#f9a825',
		text: '#7a4f00'
	},
	error: {
		background: '#fdecea',
		border: '#c62828',
		text: '#8a1c1c'
	},
	inactive: {
		background: '#f3f4f6',
		border: '#9ca3af',
		text: '#374151'
	}
};

function runCommand(args) {
	return fs.exec_direct('/usr/bin/podkopchikctl', args).catch(function(err) {
		return err && err.message ? err.message : String(err);
	});
}

function asNumber(value) {
	var n = parseInt(value, 10);
	return isNaN(n) ? 0 : n;
}

function asFlag(value) {
	return value == '1' || value == 'true' || value == 'yes';
}

function proxyRole(p) {
	if (p.role == 'main' || p.role == 'backup' || p.role == 'disabled')
		return p.role;

	return p.enabled == '0' ? 'disabled' : 'backup';
}

function simpleProxyModel() {
	var model = {
		main: [],
		backups: []
	};

	(uci.sections('podkopchik', 'proxy') || []).forEach(function(p) {
		var tag = p.tag || p.name || '';
		var role = proxyRole(p);

		if (!tag || role == 'disabled')
			return;

		if (role == 'main')
			model.main.push(tag);
		else if (role == 'backup')
			model.backups.push(tag);
	});

	return model;
}

function domainGroupModel() {
	var groups = {};
	var ruleCount = 0;

	(uci.sections('podkopchik', 'domain_rule') || []).forEach(function(rule) {
		if ((rule.enabled || '1') == '0')
			return;

		ruleCount++;
		groups[rule.group_tag || ('legacy:' + rule['.name'])] = true;
	});

	return {
		groupCount: Object.keys(groups).length,
		ruleCount: ruleCount
	};
}

function speedLimitModel() {
	var items = [];

	(uci.sections('podkopchik', 'lan_device') || []).forEach(function(device) {
		if ((device.enabled || '1') == '0' || device.speed_limit_enabled != '1')
			return;

		items.push({
			name: device.name || device.source_ip || _('LAN device'),
			sourceIp: device.source_ip || _('unknown IP'),
			download: device.download_mbit || '0',
			upload: device.upload_mbit || '0',
			mode: device.speed_limit_mode || 'always'
		});
	});

	return items;
}

function parseStatus(text) {
	var data = {
		raw: text || '',
		version: '',
		serviceEnabled: false,
		routingApplied: false,
		configuredProxies: 0,
		proxyGroups: 0,
		domainRules: 0,
		ipRules: 0,
		lanDeviceRules: 0,
		xray: 'not running',
		stateText: '',
		state: null,
		stateError: ''
	};

	var lines = data.raw.split('\n');
	var stateLines = [];
	var readingState = false;

	for (var i = 0; i < lines.length; i++) {
		var line = lines[i];

		if (readingState) {
			stateLines.push(line);
			continue;
		}

		var version = line.match(/^Podkopchik\s+(.+)$/);
		if (version) {
			data.version = version[1];
			continue;
		}

		if (line == 'State:') {
			readingState = true;
			continue;
		}

		var state = line.match(/^State:\s*(.*)$/);
		if (state) {
			data.stateText = state[1];
			continue;
		}

		var field = line.match(/^([^:]+):\s*(.*)$/);
		if (!field)
			continue;

		switch (field[1]) {
		case 'Service enabled':
			data.serviceEnabled = asFlag(field[2]);
			break;
		case 'Routing applied':
			data.routingApplied = asFlag(field[2]);
			break;
		case 'Configured proxies':
			data.configuredProxies = asNumber(field[2]);
			break;
		case 'Proxy groups':
			data.proxyGroups = asNumber(field[2]);
			break;
		case 'Domain rules':
			data.domainRules = asNumber(field[2]);
			break;
		case 'IP rules':
			data.ipRules = asNumber(field[2]);
			break;
		case 'LAN device rules':
			data.lanDeviceRules = asNumber(field[2]);
			break;
		case 'Xray':
			data.xray = field[2] || 'not running';
			break;
		}
	}

	if (stateLines.length)
		data.stateText = stateLines.join('\n').trim();

	if (data.stateText && data.stateText != 'not recorded yet') {
		try {
			data.state = JSON.parse(data.stateText);
		}
		catch (e) {
			data.stateError = e.message || String(e);
		}
	}

	return data;
}

function proxyHealth(data) {
	var out = {
		total: data.configuredProxies,
		up: 0,
		down: 0,
		unknown: 0,
		items: []
	};

	var proxies = data.state && data.state.proxies ? data.state.proxies : {};
	var seen = 0;

	for (var tag in proxies) {
		if (!proxies.hasOwnProperty(tag))
			continue;

		var item = proxies[tag] || {};
		var status = item.status || 'unknown';
		seen++;

		if (status == 'up')
			out.up++;
		else if (status == 'down')
			out.down++;
		else
			out.unknown++;

		out.items.push({
			tag: tag,
			status: status,
			lastError: item.last_error || ''
		});
	}

	if (out.total < seen)
		out.total = seen;

	if (out.total > seen)
		out.unknown += out.total - seen;

	return out;
}

function healthByTag(health, tag) {
	for (var i = 0; i < health.items.length; i++)
		if (health.items[i].tag == tag)
			return health.items[i];

	return {
		tag: tag,
		status: 'unknown',
		lastError: ''
	};
}

function summaryState(data, health) {
	var hasProxy = data.configuredProxies > 0;
	var hasRules = data.domainRules + data.ipRules + data.lanDeviceRules > 0;

	if (!data.serviceEnabled)
		return {
			tone: 'inactive',
			title: _('Podkopchik is disabled'),
			detail: _('The service is disabled and will not route traffic.')
		};

	if (!hasProxy || !hasRules)
		return {
			tone: 'error',
			title: _('Podkopchik is not configured'),
			detail: _('Add at least one proxy link and one routing rule before applying traffic routing.')
		};

	if (!data.routingApplied)
		return {
			tone: 'warning',
			title: _('Settings are present, but traffic routing is not applied'),
			detail: _('Traffic is not currently routed through proxy.')
		};

	if (data.xray != 'running' || health.down > 0)
		return {
			tone: 'error',
			title: _('Podkopchik needs attention'),
			detail: _('Traffic routing is enabled, but one or more required parts are not working.')
		};

	return {
		tone: 'ok',
		title: _('Podkopchik is working'),
		detail: _('Traffic routing is active.')
	};
}

function card(title, tone, body, detail) {
	var c = COLORS[tone] || COLORS.inactive;
	var children = [
		E('div', { 'style': 'display:flex; align-items:center; gap:8px; margin-bottom:8px' }, [
			E('span', { 'style': 'width:10px; height:10px; border-radius:50%; background:%s; display:inline-block'.format(c.border) }),
			E('strong', title)
		]),
		E('div', { 'style': 'font-size:15px; line-height:1.4; color:%s'.format(c.text) }, body)
	];

	if (detail)
		children.push(E('div', { 'style': 'margin-top:6px; color:#4b5563; line-height:1.4' }, detail));

	return E('div', {
		'class': 'cbi-section',
		'style': 'box-sizing:border-box; border-left:4px solid %s; background:%s; border-radius:8px; padding:14px; margin:0; min-height:118px'.format(c.border, c.background)
	}, children);
}

function statusLabel(status) {
	if (status == 'up')
		return _('Proxy is available');

	if (status == 'down')
		return _('Proxy is unavailable');

	return _('Proxy has not been checked yet');
}

function countText(n, one, many) {
	return n == 1 ? one : many.format(n);
}

function mainProxySummary(model, health) {
	if (model.main.length == 0)
		return card(_('Main proxy'), 'error', _('Select one main proxy.'), _('Open Proxy Links and mark one VLESS link as the main proxy.'));

	if (model.main.length > 1)
		return card(_('Main proxy'), 'error', _('Only one main proxy can be selected.'), _('Open Proxy Links and leave exactly one VLESS link marked as the main proxy.'));

	var item = healthByTag(health, model.main[0]);

	if (item.status == 'up')
		return card(_('Main proxy'), 'ok', _('Main proxy is available'), model.main[0]);

	if (item.status == 'down')
		return card(_('Main proxy'), 'error', _('Main proxy is unavailable'), _('Open technical details to see the raw proxy error.'));

	return card(_('Main proxy'), 'warning', _('Main proxy has not been checked yet'), _('Run a proxy availability check after adding or changing proxy links.'));
}

function backupProxySummary(model, health) {
	var up = 0;
	var down = 0;
	var unknown = 0;

	for (var i = 0; i < model.backups.length; i++) {
		var item = healthByTag(health, model.backups[i]);

		if (item.status == 'up')
			up++;
		else if (item.status == 'down')
			down++;
		else
			unknown++;
	}

	if (model.backups.length == 0)
		return card(_('Backup proxies'), 'inactive', _('No backup proxies selected.'), _('Backups are optional, but they help keep routing working if the main proxy is unavailable.'));

	if (up > 0)
		return card(_('Backup proxies'), 'ok', countText(model.backups.length, _('1 backup proxy selected'), _('%d backup proxies selected')), _('%d backup proxies are available').format(up));

	if (down == model.backups.length)
		return card(_('Backup proxies'), 'error', _('All backup proxies are unavailable'), _('Open technical details to see the raw proxy errors.'));

	return card(_('Backup proxies'), 'warning', countText(model.backups.length, _('1 backup proxy selected'), _('%d backup proxies selected')), unknown > 0 ? _('Some backup proxies have not been checked yet.') : _('Backup proxies need attention.'));
}

function ruleDetails(data) {
	var parts = [];

	if (data.domainRules > 0)
		parts.push(countText(data.domainRules, _('1 domain routing rule configured'), _('%d domain routing rules configured')));

	if (data.ipRules > 0)
		parts.push(countText(data.ipRules, _('1 IP routing rule configured'), _('%d IP routing rules configured')));

	if (data.lanDeviceRules > 0)
		parts.push(countText(data.lanDeviceRules, _('1 LAN device rule configured'), _('%d LAN device rules configured')));

	return parts.join('\n');
}

function speedLimitSummary(items) {
	if (!items.length)
		return card(_('Speed limits'), 'inactive', _('No speed limits configured'), _('Speed limit diagnostics are available with podkopchikctl shaping-status.'));

	var names = items.map(function(item) {
		return '%s (%s, %s)'.format(item.name, item.sourceIp, _('diagnostics only'));
	}).join(', ');

	return card(_('Speed limits'), 'warning',
		countText(items.length, _('1 speed limit rule configured'), _('%d speed limit rules configured')),
		[
			_('Speed limits configured, diagnostics only'),
			_('Enforcement is not active in this beta.'),
			_('Configured devices: %s').format(names)
		].join('\n'));
}

function lastCheckText(data) {
	if (data.state && data.state.updated_at)
		return _('Last proxy check: %s').format(new Date(data.state.updated_at * 1000).toLocaleString());

	if (data.stateText && data.stateText != 'not recorded yet')
		return _('Last check data is not readable.');

	return _('Proxy availability has not been checked yet.');
}

function technicalDetails(data, health) {
	var rows = [];

	if (health.items.length) {
		rows.push(E('h4', _('Proxy details')));
		rows.push(E('ul', { 'style': 'margin-top:0' }, health.items.map(function(item) {
			var text = '%s: %s'.format(item.tag, statusLabel(item.status));
			if (item.lastError)
				text += ' - %s: %s'.format(_('Technical details'), item.lastError);
			return E('li', text);
		})));
	}

	if (data.stateError)
		rows.push(E('p', [ _('State data could not be parsed.'), ' ', data.stateError ]));

	rows.push(E('h4', _('Raw status output')));
	rows.push(E('pre', { 'style': 'white-space:pre-wrap; overflow:auto; max-height:240px' }, data.raw || ''));

	if (data.stateText && data.stateText != 'not recorded yet') {
		rows.push(E('h4', _('Raw state JSON')));
		rows.push(E('pre', { 'style': 'white-space:pre-wrap; overflow:auto; max-height:320px' }, data.stateText));
	}

	return rows;
}

function renderCards(statusText) {
	var data = parseStatus(statusText);
	var health = proxyHealth(data);
	var model = simpleProxyModel();
	var domainGroups = domainGroupModel();
	var speedLimits = speedLimitModel();
	var summary = summaryState(data, health);
	var hasRules = data.domainRules + data.ipRules + data.lanDeviceRules > 0;
	var xrayTone = data.xray == 'running' ? 'ok' : (data.routingApplied ? 'error' : 'inactive');
	var technical = E('div', { 'style': 'display:none; margin-top:12px' }, technicalDetails(data, health));
	var techButton = E('button', {
		'class': 'btn cbi-button',
		'click': function() {
			var hidden = technical.style.display == 'none';
			technical.style.display = hidden ? '' : 'none';
			techButton.textContent = hidden ? _('Hide technical details') : _('Show technical details');
		}
	}, _('Show technical details'));

	return E([
		card(_('Overall status'), summary.tone, summary.title, summary.detail),
		E('div', {
			'style': 'display:grid; grid-template-columns:repeat(auto-fit, minmax(220px, 1fr)); gap:12px; margin:12px 0'
		}, [
			card(_('Service'), data.serviceEnabled ? 'ok' : 'inactive',
				data.serviceEnabled ? _('Podkopchik service is enabled') : _('Podkopchik service is disabled'),
				data.serviceEnabled ? _('The background service can start when needed.') : _('Enable the service before applying traffic routing.')),
			card(_('Traffic routing'), data.routingApplied ? 'ok' : (hasRules ? 'warning' : 'inactive'),
				data.routingApplied ? _('Traffic routing is active') : _('Traffic is not currently routed through proxy'),
				data.routingApplied ? _('LAN traffic matching your rules is being redirected to Xray.') : _('Settings exist, but traffic routing is not applied.')),
			card(_('Xray'), xrayTone,
				data.xray == 'running' ? _('Xray is running') : (data.routingApplied ? _('Xray is not running although routing is enabled') : _('Xray is stopped; this is normal while routing is disabled')),
				data.xray == 'running' ? _('Proxy traffic can be handled by Xray.') : ''),
			mainProxySummary(model, health),
			backupProxySummary(model, health),
			card(_('Domain groups'), domainGroups.groupCount > 0 ? 'ok' : 'inactive',
				domainGroups.groupCount > 0 ? countText(domainGroups.groupCount, _('1 domain group configured'), _('%d domain groups configured')) : _('No domain groups configured.'),
				_('Traffic for domains without rules goes direct by default.')),
				card(_('Routing rules'), hasRules ? 'ok' : 'error',
					hasRules ? ruleDetails(data) : _('No routing rules configured.'),
					hasRules ? _('Only matching traffic is routed through proxy.') : _('Add a domain, IP, or LAN device rule before applying traffic routing.')),
				speedLimitSummary(speedLimits)
			]),
		card(_('Last check'), data.state && data.state.updated_at ? (health.down > 0 ? 'error' : 'ok') : 'inactive',
			lastCheckText(data),
			data.state && data.state.events && data.state.events.length ? data.state.events.join('\n') : ''),
		E('div', { 'class': 'cbi-section', 'style': 'margin-top:12px' }, [
			techButton,
			technical
		])
	]);
}

return view.extend({
	load: function() {
		return Promise.all([
			runCommand([ 'status' ]),
			uci.load('podkopchik')
		]);
	},

	render: function(data) {
		var status = data[0];
		var content = E('div', renderCards(status));

		function refresh() {
			return runCommand([ 'status' ]).then(function(next) {
				while (content.firstChild)
					content.removeChild(content.firstChild);
				content.appendChild(renderCards(next));
			});
		}

		function action(args) {
			return runCommand(args).then(function(res) {
				ui.addNotification(null, E('pre', { 'style': 'white-space: pre-wrap' }, res));
				return refresh();
			});
		}

		return E([
			E('h2', _('Podkopchik')),
			E('div', { 'class': 'cbi-section' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'click': ui.createHandlerFn(this, action, [ 'apply' ])
				}, _('Apply settings')),
				' ',
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, action, [ 'health' ])
				}, _('Check proxy availability')),
				' ',
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, action, [ 'restart' ])
				}, _('Restart service')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-remove',
					'click': ui.createHandlerFn(this, action, [ 'cleanup' ])
				}, _('Disable traffic routing'))
			]),
			content
		]);
	}
});
