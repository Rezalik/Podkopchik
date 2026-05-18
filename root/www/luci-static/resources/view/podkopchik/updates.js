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

return view.extend({
	load: function() {
		return runCommand([ 'update-check' ]);
	},

	render: function(info) {
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
			output
		]);
	}
});
