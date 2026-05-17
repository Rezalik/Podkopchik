'use strict';
'require view';
'require fs';
'require ui';

function runCommand(args) {
	return fs.exec_direct('/usr/bin/podkopchikctl', args).catch(function(err) {
		return err && err.message ? err.message : String(err);
	});
}

return view.extend({
	load: function() {
		return runCommand([ 'status' ]);
	},

	render: function(status) {
		var output = E('pre', { 'class': 'cbi-section', 'style': 'white-space: pre-wrap' }, status);

		function action(args) {
			return runCommand(args).then(function(res) {
				ui.addNotification(null, E('pre', { 'style': 'white-space: pre-wrap' }, res));
				return runCommand([ 'status' ]).then(function(next) {
					output.textContent = next;
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
				}, _('Health')),
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
