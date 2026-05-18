'use strict';
'require view';
'require fs';
'require ui';

function runCommand(args) {
	return fs.exec_direct('/usr/bin/podkopchikctl', args).catch(function(err) {
		return err && err.message ? err.message : String(err);
	});
}

function localizeStatus(text) {
	var labels = {
		'Service enabled': _('Service enabled'),
		'Routing applied': _('Routing applied'),
		'Configured proxies': _('Configured proxies'),
		'Proxy groups': _('Proxy groups'),
		'Domain rules': _('Domain rules'),
		'IP rules': _('IP rules'),
		'LAN device rules': _('LAN device rules'),
		'Xray': _('Xray'),
		'State': _('State')
	};

	var values = {
		'running': _('running'),
		'not running': _('not running'),
		'not recorded yet': _('not recorded yet')
	};

	return (text || '').split('\n').map(function(line) {
		var m = line.match(/^([^:]+):(?:\s*)(.*)$/);
		if (!m || !labels[m[1]])
			return line;

		return labels[m[1]] + ': ' + (values[m[2]] || m[2]);
	}).join('\n');
}

return view.extend({
	load: function() {
		return runCommand([ 'status' ]);
	},

	render: function(status) {
		var output = E('pre', { 'class': 'cbi-section', 'style': 'white-space: pre-wrap' }, localizeStatus(status));

		function action(args) {
			return runCommand(args).then(function(res) {
				ui.addNotification(null, E('pre', { 'style': 'white-space: pre-wrap' }, res));
				return runCommand([ 'status' ]).then(function(next) {
					output.textContent = localizeStatus(next);
				});
			});
		}

		return E([
			E('h2', _('Podkopchik')),
			E('div', { 'class': 'cbi-section' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'click': ui.createHandlerFn(this, action, [ 'apply' ])
				}, _('Apply')),
				' ',
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, action, [ 'health' ])
				}, _('Health check')),
				' ',
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, action, [ 'restart' ])
				}, _('Restart')),
				' ',
				E('button', {
					'class': 'btn cbi-button cbi-button-remove',
					'click': ui.createHandlerFn(this, action, [ 'cleanup' ])
				}, _('Disable Routing'))
			]),
			output
		]);
	}
});
