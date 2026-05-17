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
		return runCommand([ 'update-check' ]);
	},

	render: function(info) {
		var output = E('pre', { 'class': 'cbi-section', 'style': 'white-space: pre-wrap' }, info);

		function action(args) {
			return runCommand(args).then(function(res) {
				output.textContent = res;
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
			output
		]);
	}
});
