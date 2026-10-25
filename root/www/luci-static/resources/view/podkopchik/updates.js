'use strict';
'require view';
'require fs';
'require ui';

function runCommand(args) {
	return fs.exec_direct('/usr/bin/podkopchikctl', args).catch(function(err) {
		return err && err.message ? err.message : String(err);
	});
}

function localizeInfo(text) {
	var labels = {
		'current': _('Current version'),
		'channel': _('Update channel'),
		'repo': _('Repository'),
		'branch': _('Branch'),
		'latest': _('Latest version'),
		'archive_url': _('Archive URL'),
		'sha256_url': _('SHA256 URL'),
		'changelog': _('Changelog'),
		'warning': _('Warning')
	};

	var values = {
		'Development update from branch; no release checksum available.': _('Development update from branch; no release checksum available.')
	};

	return (text || '').split('\n').map(function(line) {
		var m = line.match(/^([^=:]+)(=|:)(.*)$/);
		if (!m || !labels[m[1]])
			return line == 'No changelog provided.' ? _('No changelog provided.') : line;

		return labels[m[1]] + m[2] + (values[m[3]] || m[3]);
	}).join('\n');
}

function isMainChannel(text) {
	return /(^|\n)channel=main(\n|$)/.test(text || '');
}

function coreFields(text) {
	var out = {};
	String(text || '').split('\n').forEach(function(line) {
		var pos = line.indexOf('=');
		if (pos > 0)
			out[line.slice(0, pos)] = line.slice(pos + 1);
	});
	return out;
}

function renderCore(info) {
	var data = coreFields(info);
	var buttons = [];
	var labels = {
		package: _('OpenWrt package (opkg)'),
		system: _('System Xray (package ownership unverified)'),
		official: _('Official Xray release'),
		rollback: _('Restored executable')
	};
	var statuses = {
		not_checked: _('Not checked yet'),
		updating: _('Updating Xray...'),
		verified: _('Xray update verified'),
		rolled_back: _('Previous Xray executable restored'),
		rollback_failed: _('Xray recovery needs attention'),
		failed: _('Xray update failed; active executable was preserved')
	};
	var source = E('select', { 'class': 'cbi-input-select' }, [
		E('option', { value: 'package' }, labels.package),
		E('option', { value: 'official' }, labels.official)
	]);
	var details = E('dl', { 'style': 'display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:6px 16px;overflow-wrap:anywhere' });
	var output = E('pre', { 'style': 'white-space:pre-wrap;overflow-wrap:anywhere' });
	function refresh() {
		while (details.firstChild)
			details.removeChild(details.firstChild);
		var checked = Number(data[source.value + '_checked_at'] || 0);
		[
			[ _('Installed Xray version'), data.installed || _('Not available') ],
			[ _('Latest version'), data[source.value + '_latest'] || _('Not checked yet') ],
			[ _('Installed source'), labels[data.source] || data.source || _('Not available') ],
			[ _('Architecture'), data.architecture || _('Not available') ],
			[ _('Last update check'), checked ? new Date(checked * 1000).toLocaleString() : _('Not checked yet') ],
			[ _('Update status'), statuses[data.status] || _('Not checked yet') ]
		].forEach(function(row) {
			details.appendChild(E('dt', row[0]));
			details.appendChild(E('dd', { 'style': 'margin:0;overflow-wrap:anywhere' }, row[1]));
		});
	}
	source.addEventListener('change', refresh);
	function action(command) {
		buttons.forEach(function(button) { button.disabled = true; });
		output.textContent = command == 'xray-check' ? _('Checking Xray updates...') : _('Updating Xray...');
		var start = command.replace('xray-', 'xray-start-');
		var args = command == 'xray-rollback' ? [ start ] : [ start, source.value ];
		function poll(jobId) {
			return fs.exec_direct('/usr/bin/podkopchikctl', [ 'xray-status' ]).then(function(result) {
				data = coreFields(result);
				output.textContent = result;
				refresh();
				if (data.job_id != jobId)
					throw new Error(_('Xray operation status changed; refresh this page.'));
				if (data.job_status == 'running')
					return new Promise(function(resolve) { window.setTimeout(resolve, 1500); }).then(function() { return poll(jobId); });
				if (data.job_status != 'done')
					throw new Error(data.job_message || _('Xray operation failed. See technical details below.'));
			});
		}
		return fs.exec_direct('/usr/bin/podkopchikctl', args).then(function(result) {
			return poll(coreFields(result).job_id);
		}).catch(function(err) {
			output.textContent = err.message || String(err);
			ui.addNotification(_('Xray Core'), E('p', _('Xray operation failed. See technical details below.')), 'error');
		}).then(function() {
			return fs.exec_direct('/usr/bin/podkopchikctl', [ 'xray-status' ]);
		}).then(function(result) {
			data = coreFields(result);
			refresh();
		}).finally(function() {
			buttons.forEach(function(button) { button.disabled = false; });
		});
	}
	function button(label, command) {
		var node = E('button', { 'class': 'btn cbi-button', click: function(ev) {
			ev.preventDefault();
			return action(command);
		} }, label);
		buttons.push(node);
		return node;
	}
	refresh();
	return E('section', { 'class': 'cbi-section' }, [
		E('h3', _('Xray Core')),
		details,
		E('label', [ _('Update source'), ' ', source ]),
		E('p', _('Xray and Podkopchik updates are independent. An Xray update briefly restarts the proxy; failed verification restores the previous executable.')),
		E('div', { 'style': 'display:flex;gap:8px;flex-wrap:wrap' }, [
			button(_('Check for updates'), 'xray-check'),
			button(_('Update Xray'), 'xray-install'),
			button(_('Restore previous Xray'), 'xray-rollback')
		]),
		E('details', [ E('summary', _('Technical details')), output ])
	]);
}

return view.extend({
	load: function() {
		return Promise.all([
			runCommand([ 'update-check' ]),
			runCommand([ 'xray-status' ])
		]);
	},

	render: function(data) {
		var info = data[0];
		var output = E('pre', { 'class': 'cbi-section', 'style': 'white-space: pre-wrap' }, localizeInfo(info));
		var warning = E('div', {
			'class': 'alert-message warning',
			'style': isMainChannel(info) ? '' : 'display: none'
		}, _('Main branch update is for development/testing. Stable releases are safer.'));

		function action(args) {
			return runCommand(args).then(function(res) {
				output.textContent = args[0] == 'update-check' ? localizeInfo(res) : res;
				if (args[0] == 'update-check')
					warning.style.display = isMainChannel(res) ? '' : 'none';
				ui.addNotification(null, E('pre', { 'style': 'white-space: pre-wrap' }, res));
			});
		}

		return E([
			E('h2', _('Podkopchik Updates')),
			E('div', { 'class': 'cbi-section' }, [
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, action, [ 'update-check' ])
				}, _('Check')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'click': ui.createHandlerFn(this, action, [ 'update-install' ])
				}, _('Install Update')),
				' ',
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, action, [ 'rollback' ])
				}, _('Rollback'))
			]),
			warning,
			output,
			renderCore(data[1])
		]);
	}
});
