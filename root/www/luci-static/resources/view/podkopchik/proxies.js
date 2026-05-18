'use strict';
'require view';
'require form';
'require uci';
'require ui';

var AUTO_GROUP_TAG = 'auto_proxy_group';

function proxyTag(p) {
	return p.tag || p.name || '';
}

function proxyRole(p) {
	if (p.role == 'main' || p.role == 'backup' || p.role == 'disabled')
		return p.role;

	return p.enabled == '0' ? 'disabled' : 'backup';
}

function roleState() {
	var main = [];
	var backups = [];

	(uci.sections('podkopchik', 'proxy') || []).forEach(function(p) {
		var tag = proxyTag(p);
		var role = proxyRole(p);

		if (!tag || role == 'disabled')
			return;

		if (role == 'main')
			main.push(tag);
		else if (role == 'backup')
			backups.push({
				tag: tag,
				priority: parseInt(p.backup_priority || '1', 10) || 1
			});
	});

	backups.sort(function(a, b) {
		if (a.priority != b.priority)
			return a.priority - b.priority;

		return a.tag < b.tag ? -1 : (a.tag > b.tag ? 1 : 0);
	});

	return {
		main: main,
		backups: backups.slice(0, 3)
	};
}

function findAutoGroup() {
	var found = null;

	(uci.sections('podkopchik', 'proxy_group') || []).forEach(function(g) {
		if ((g.tag || '') == AUTO_GROUP_TAG)
			found = g['.name'];
	});

	return found;
}

function ensureAutoGroup() {
	var sid = findAutoGroup();

	if (!sid)
		sid = uci.add('podkopchik', 'proxy_group');

	return sid;
}

function setAutoGroupEnabled(sid, enabled) {
	uci.set('podkopchik', sid, 'enabled', enabled ? '1' : '0');
	uci.set('podkopchik', sid, 'name', 'Automatic proxy group');
	uci.set('podkopchik', sid, 'tag', AUTO_GROUP_TAG);
	uci.set('podkopchik', sid, 'mode', 'strict_primary');
	uci.set('podkopchik', sid, 'auto_return', '1');
	uci.set('podkopchik', sid, 'failure_action', 'switch_to_backup');
	uci.unset('podkopchik', sid, 'manual_override_proxy');
	uci.unset('podkopchik', sid, 'fixed_proxy');
}

function maintainAutoGroup() {
	var state = roleState();
	var sid = ensureAutoGroup();

	setAutoGroupEnabled(sid, state.main.length == 1);

	if (state.main.length == 1)
		uci.set('podkopchik', sid, 'primary', state.main[0]);
	else
		uci.unset('podkopchik', sid, 'primary');

	for (var i = 0; i < 3; i++) {
		if (state.backups[i])
			uci.set('podkopchik', sid, 'backup%d'.format(i + 1), state.backups[i].tag);
		else
			uci.unset('podkopchik', sid, 'backup%d'.format(i + 1));
	}

	if (state.main.length == 0)
		return _('Select one main proxy.');

	if (state.main.length > 1)
		return _('Only one main proxy can be selected.');

	return null;
}

function roleWarning() {
	var state = roleState();

	if (state.main.length == 0)
		return _('Select one main proxy.');

	if (state.main.length > 1)
		return _('Only one main proxy can be selected.');

	return null;
}

function warningNode() {
	var warning = roleWarning();

	if (!warning)
		return '';

	return E('div', {
		'class': 'alert-message warning',
		'style': 'margin-bottom:12px'
	}, warning);
}

return view.extend({
	load: function() {
		return uci.load('podkopchik');
	},

	render: function() {
		var m = new form.Map('podkopchik', _('Podkopchik'),
			_('Add your VLESS links, choose one main proxy, and optionally choose up to three backup proxies.'));
		var s = m.section(form.GridSection, 'proxy', _('Proxy Links'));
		s.anonymous = true;
		s.addremove = true;
		s.sortable = true;

		var originalSave = m.save.bind(m);
		m.save = function(cb, silent) {
			return originalSave(function() {
				var warning = maintainAutoGroup();

				if (warning)
					ui.addNotification(null, E('p', warning), 'warning');

				if (cb)
					return cb();
			}, silent);
		};

		var o = s.option(form.Value, 'name', _('Name'));
		o.rmempty = false;

		o = s.option(form.Value, 'tag', _('Tag'));
		o.datatype = 'uciname';
		o.rmempty = false;

		o = s.option(form.Value, 'uri', _('VLESS URI'));
		o.password = true;
		o.rmempty = false;

		o = s.option(form.ListValue, 'role', _('Role'));
		o.value('main', _('Main proxy'));
		o.value('backup', _('Backup proxy'));
		o.value('disabled', _('Disabled / not used'));
		o.default = 'backup';
		o.rmempty = false;
		o.cfgvalue = function(section_id) {
			return proxyRole(uci.get('podkopchik', section_id) || {});
		};
		o.write = function(section_id, value) {
			uci.set('podkopchik', section_id, 'role', value);
			uci.set('podkopchik', section_id, 'enabled', value == 'disabled' ? '0' : '1');
		};

		o = s.option(form.ListValue, 'backup_priority', _('Backup priority'));
		o.value('1', '1');
		o.value('2', '2');
		o.value('3', '3');
		o.default = '1';
		o.rmempty = false;
		o.depends('role', 'backup');

		o = s.option(form.DummyValue, 'detected_transport', _('Detected transport'));
		o.modalonly = false;
		o.rmempty = true;

		o = s.option(form.DummyValue, 'detected_security', _('Detected security'));
		o.modalonly = false;
		o.rmempty = true;

		o = s.option(form.Value, 'note', _('Note'));
		o.rmempty = true;

		return m.render().then(function(node) {
			return E([ warningNode(), node ]);
		});
	}
});
