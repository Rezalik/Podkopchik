'use strict';
'require view';
'require fs';
'require ui';

function readLogs() {
	return fs.exec_direct('/sbin/logread', [ '-e', 'podkopchik' ]).catch(function() {
		return fs.exec_direct('/usr/bin/logread', [ '-e', 'podkopchik' ]).catch(function(err) {
			return err && err.message ? err.message : String(err);
		});
	});
}

return view.extend({
	load: readLogs,

	render: function(logs) {
		var output = E('pre', { 'class': 'cbi-section', 'style': 'white-space: pre-wrap' }, logs || _('No Podkopchik log entries.'));

		return E([
			E('h2', _('Podkopchik Logs')),
			E('div', { 'class': 'cbi-section' }, [
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, function() {
						return readLogs().then(function(next) {
							output.textContent = next || _('No Podkopchik log entries.');
						});
					})
				}, _('Refresh'))
			]),
			output
		]);
	}
});
