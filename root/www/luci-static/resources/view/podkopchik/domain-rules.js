'use strict';
'require view';
'require ui';
'require uci';

var AUTO_GROUP_TAG = 'auto_proxy_group';

function cleanTag(value) {
	var tag = (value || '').toLowerCase().replace(/[^a-z0-9_]+/g, '_').replace(/^_+|_+$/g, '').substr(0, 48);

	if (!tag)
		return '';

	if (/^[0-9]/.test(tag))
		tag = 'g_' + tag;

	return tag;
}

function domainLooksValid(domain) {
	var d = (domain || '').replace(/^\*\./, '');
	var labels = d.split('.');

	if (d.length < 3 || d.length > 253 || labels.length < 2)
		return false;

	for (var i = 0; i < labels.length; i++) {
		if (!/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/i.test(labels[i]))
			return false;
	}

	return true;
}

function normalizeDomains(text) {
	var seen = {};
	var out = [];
	var tokens = (text || '').split(/[\s,;]+/);

	for (var i = 0; i < tokens.length; i++) {
		var raw = tokens[i].trim();
		var domain = raw.toLowerCase();

		if (!domain)
			continue;

		if (!domainLooksValid(domain))
			throw new Error(_('Invalid domain value %d: %s').format(i + 1, raw));

		if (!seen[domain]) {
			seen[domain] = true;
			out.push(domain);
		}
	}

	return out;
}

function domainValues(rule) {
	var value = rule.domain;
	var values = Array.isArray(value) ? value : (value ? [ value ] : []);
	var out = [];

	for (var i = 0; i < values.length; i++) {
		var tokens = String(values[i] || '').split(/[\s,;]+/);

		for (var j = 0; j < tokens.length; j++) {
			var domain = tokens[j].trim().toLowerCase();

			if (domain)
				out.push(domain);
		}
	}

	return out;
}

function addUniqueDomains(group, domains) {
	group.domainSeen = group.domainSeen || {};

	for (var i = 0; i < domains.length; i++) {
		if (!group.domainSeen[domains[i]]) {
			group.domainSeen[domains[i]] = true;
			group.domains.push(domains[i]);
		}
	}
}

function proxyOptions() {
	var out = [];

	(uci.sections('podkopchik', 'proxy') || []).forEach(function(p) {
		var tag = p.tag || p.name;

		if (tag)
			out.push({
				tag: tag,
				label: p.name || tag
			});
	});

	return out;
}

function targetInfo(target) {
	if (target == 'direct')
		return { mode: 'direct', proxy: '' };

	if (target == AUTO_GROUP_TAG || !target)
		return { mode: 'auto', proxy: '' };

	var proxies = proxyOptions();
	for (var i = 0; i < proxies.length; i++)
		if (proxies[i].tag == target)
			return { mode: 'proxy', proxy: target };

	return { mode: 'proxy', proxy: target };
}

function groupSort(a, b) {
	if (a.order != b.order)
		return a.order - b.order;

	return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0);
}

function collectDomainGroups() {
	var groups = {};
	var list = [];
	var index = 0;

	(uci.sections('podkopchik', 'domain_rule') || []).forEach(function(rule) {
		var sid = rule['.name'];
		var domains = domainValues(rule);
		var firstDomain = domains[0] || '';
		var tag = rule.group_tag || '';
		var name = rule.group_name || rule.name || firstDomain || _('Domain group');
		var key = tag ? 'group:' + tag : (rule.group_name ? 'name:' + rule.group_name : 'legacy:' + sid);
		var info = targetInfo(rule.target || AUTO_GROUP_TAG);

		if (!groups[key]) {
			groups[key] = {
				key: key,
				sids: [],
				enabled: rule.enabled != '0',
				name: name,
				tag: tag || cleanTag(rule.tag || rule.group_name || rule.name || firstDomain || sid),
				domains: [],
				domainSeen: {},
				targetMode: info.mode,
				targetProxy: info.proxy,
				order: parseInt(rule.group_order || rule['.index'] || index, 10) || index
			};
			list.push(groups[key]);
		}

		groups[key].sids.push(sid);
		addUniqueDomains(groups[key], domains);

		index++;
	});

	list.sort(groupSort);
	return list;
}

function label(text) {
	return E('label', { 'class': 'cbi-value-title', 'style': 'display:block; margin-bottom:4px' }, text);
}

function field(labelText, input) {
	return E('div', { 'class': 'cbi-value', 'style': 'margin-bottom:12px' }, [
		label(labelText),
		E('div', { 'class': 'cbi-value-field' }, input)
	]);
}

function selectOption(value, text, selected) {
	return E('option', { 'value': value, 'selected': selected ? 'selected' : null }, text);
}

function updateProxySelectVisibility(card) {
	var mode = card.querySelector('[data-field="target-mode"]').value;
	var proxyRow = card.querySelector('[data-field-row="target-proxy"]');

	proxyRow.style.display = mode == 'proxy' ? '' : 'none';
}

function renderDomainGroup(group) {
	group = group || {
		sids: [],
		enabled: true,
		name: '',
		tag: '',
		domains: [],
		targetMode: 'auto',
		targetProxy: '',
		order: 0
	};

	var targetMode = E('select', {
		'class': 'cbi-input-select',
		'data-field': 'target-mode',
		'change': function(ev) {
			updateProxySelectVisibility(ev.currentTarget.closest('.podkopchik-domain-group'));
		}
	}, [
		selectOption('auto', _('Automatic: main + backups'), group.targetMode == 'auto'),
		selectOption('proxy', _('Specific proxy'), group.targetMode == 'proxy'),
		selectOption('direct', _('Direct'), group.targetMode == 'direct')
	]);

	var proxySelect = E('select', { 'class': 'cbi-input-select', 'data-field': 'target-proxy' },
		proxyOptions().map(function(p) {
			return selectOption(p.tag, p.label, group.targetProxy == p.tag);
		}));

	var card = E('div', {
		'class': 'cbi-section podkopchik-domain-group',
		'data-sids': group.sids.join(','),
		'style': 'border-left:4px solid #9ca3af; border-radius:8px; padding:14px; margin-bottom:12px'
	}, [
		E('div', { 'style': 'display:flex; justify-content:space-between; gap:12px; align-items:center; margin-bottom:10px' }, [
			E('strong', group.name || _('New domain group')),
			E('button', {
				'class': 'btn cbi-button cbi-button-remove',
				'click': function(ev) {
					ev.preventDefault();
					ev.currentTarget.closest('.podkopchik-domain-group').remove();
				}
			}, _('Remove'))
		]),
		field(_('Enabled'), E('input', {
			'type': 'checkbox',
			'data-field': 'enabled',
			'checked': group.enabled ? 'checked' : null
		})),
		field(_('Name'), E('input', {
			'class': 'cbi-input-text',
			'data-field': 'name',
			'value': group.name || '',
			'placeholder': _('YouTube')
		})),
		field(_('Tag'), E('input', {
			'class': 'cbi-input-text',
			'data-field': 'tag',
			'value': group.tag || '',
			'placeholder': 'youtube'
		})),
		field(_('Domains'), E('textarea', {
			'class': 'cbi-input-textarea',
			'data-field': 'domains',
			'rows': 7,
			'placeholder': 'youtube.com\nyoutu.be\ngooglevideo.com\nytimg.com'
		}, group.domains.join('\n'))),
		field(_('Target'), targetMode),
		E('div', { 'class': 'cbi-value', 'data-field-row': 'target-proxy', 'style': 'margin-bottom:12px' }, [
			label(_('Specific proxy')),
			E('div', { 'class': 'cbi-value-field' }, proxySelect)
		])
	]);

	updateProxySelectVisibility(card);
	return card;
}

function readGroupsFromPage() {
	var groups = [];
	var tags = {};
	var cards = document.querySelectorAll('.podkopchik-domain-group');

	for (var i = 0; i < cards.length; i++) {
		var card = cards[i];
		var name = card.querySelector('[data-field="name"]').value.trim();
		var tag = cleanTag(card.querySelector('[data-field="tag"]').value || name);
		var domains = normalizeDomains(card.querySelector('[data-field="domains"]').value);
		var targetMode = card.querySelector('[data-field="target-mode"]').value;
		var proxy = card.querySelector('[data-field="target-proxy"]').value;

		if (!name)
			throw new Error(_('Domain group name is required.'));

		if (!tag)
			throw new Error(_('Domain group tag is required.'));

		if (tags[tag])
			throw new Error(_('Duplicate domain group tag: %s').format(tag));

		if (domains.length == 0)
			throw new Error(_('Add at least one domain to %s.').format(name));

		if (targetMode == 'proxy' && !proxy)
			throw new Error(_('Select a proxy for %s.').format(name));

		tags[tag] = true;

		groups.push({
			sids: (card.getAttribute('data-sids') || '').split(',').filter(function(sid) { return sid; }),
			enabled: card.querySelector('[data-field="enabled"]').checked,
			name: name,
			tag: tag,
			domains: domains,
			target: targetMode == 'direct' ? 'direct' : (targetMode == 'proxy' ? proxy : AUTO_GROUP_TAG),
			order: i
		});
	}

	return groups;
}

function writeGroupsToUci(groups) {
	var keep = {};
	var original = {};
	var container = document.getElementById('podkopchik-domain-groups');
	var originalSids = ((container && container.getAttribute('data-original-sids')) || '').split(',');

	for (var o = 0; o < originalSids.length; o++)
		if (originalSids[o])
			original[originalSids[o]] = true;

	for (var i = 0; i < groups.length; i++) {
		var group = groups[i];
		var sid = group.sids[0] || uci.add('podkopchik', 'domain_rule');
		var target = group.target || (group.targetMode == 'direct' ? 'direct' : (group.targetMode == 'proxy' ? group.targetProxy : AUTO_GROUP_TAG));

		keep[sid] = true;
		uci.set('podkopchik', sid, 'enabled', group.enabled ? '1' : '0');
		uci.unset('podkopchik', sid, 'domain');
		uci.set('podkopchik', sid, 'domain', group.domains);
		uci.set('podkopchik', sid, 'target', target);
		uci.set('podkopchik', sid, 'group_name', group.name);
		uci.set('podkopchik', sid, 'group_tag', group.tag);
		uci.set('podkopchik', sid, 'group_order', String(group.order));

		for (var k = 1; k < group.sids.length; k++)
			uci.remove('podkopchik', group.sids[k]);
	}

	(uci.sections('podkopchik', 'domain_rule') || []).forEach(function(rule) {
		var sid = rule['.name'];

		if (original[sid] && !keep[sid])
			uci.remove('podkopchik', sid);
	});
}

return view.extend({
	load: function() {
		return uci.load('podkopchik');
	},

	render: function() {
		var groups = collectDomainGroups();
		var originalSids = [];

		for (var i = 0; i < groups.length; i++)
			originalSids = originalSids.concat(groups[i].sids);

		var container = E('div', {
			'id': 'podkopchik-domain-groups',
			'data-original-sids': originalSids.join(',')
		},
			groups.length ? groups.map(renderDomainGroup) : [ renderDomainGroup() ]);

		return E([
			E('h2', _('Domain Groups')),
			E('div', { 'class': 'cbi-map-descr' }, _('Create groups of domains and choose whether each group uses automatic main/backup routing, a specific proxy, or direct connection. Traffic for domains not listed here goes direct by default.')),
			container,
			E('div', { 'class': 'cbi-section' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-add',
					'click': function(ev) {
						ev.preventDefault();
						container.appendChild(renderDomainGroup());
					}
				}, _('Add domain group'))
			])
		]);
	},

	handleSave: function() {
		try {
			writeGroupsToUci(readGroupsFromPage());
		}
		catch (e) {
			ui.addNotification(_('Validation error'), E('p', e.message || String(e)), 'error');
			return Promise.reject(e);
		}

		return uci.save();
	},

	handleSaveApply: function(ev, mode) {
		return this.handleSave(ev).then(function() {
			ui.changes.apply(mode == '0');
		});
	},

	handleReset: function() {
		window.location.reload();
	}
});
