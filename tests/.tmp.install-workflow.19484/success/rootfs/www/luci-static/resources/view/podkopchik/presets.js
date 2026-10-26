'use strict';
'require view';
'require fs';
'require ui';
'require uci';

var AUTO_GROUP_TAG = 'auto_proxy_group';

var PRESETS = {
	telegram: {
		name: 'Telegram',
		tag: 'telegram',
		domains: [
			'telegram.org',
			't.me',
			'telegram.me',
			'telegram.dog',
			'telegra.ph',
			'tdesktop.com',
			'cdn-telegram.org',
			'telegram-cdn.org'
		],
		ips: [
			'91.108.4.0/22',
			'91.108.8.0/22',
			'91.108.12.0/22',
			'91.108.16.0/22',
			'91.108.20.0/22',
			'91.108.56.0/22',
			'149.154.160.0/20'
		]
	},
	youtube: {
		name: 'YouTube',
		tag: 'youtube',
		domains: [
			'youtube.com',
			'www.youtube.com',
			'm.youtube.com',
			'youtu.be',
			'youtube-nocookie.com',
			'googlevideo.com',
			'ytimg.com',
			'ggpht.com',
			'yt3.googleusercontent.com',
			'youtubei.googleapis.com',
			'youtubeembeddedplayer.googleapis.com',
			'youtube-ui.l.google.com',
			'ytimg.l.google.com',
			'wide-youtube.l.google.com',
			'jnn-pa.googleapis.com'
		],
		ips: []
	},
	instagram: {
		name: 'Instagram',
		tag: 'instagram',
		domains: [
			'instagram.com',
			'www.instagram.com',
			'i.instagram.com',
			'api.instagram.com',
			'graph.instagram.com',
			'ig.me',
			'cdninstagram.com',
			'scontent.cdninstagram.com',
			'facebook.com',
			'facebook.net',
			'fbcdn.net',
			'fbsbx.com',
			'meta.com',
			'threads.net'
		],
		ips: []
	},
	tiktok: {
		name: 'TikTok',
		tag: 'tiktok',
		domains: [
			'tiktok.com',
			'www.tiktok.com',
			'm.tiktok.com',
			'vm.tiktok.com',
			'vt.tiktok.com',
			'tiktokcdn.com',
			'tiktokv.com',
			'tiktokcdn-us.com',
			'byteoversea.com',
			'ibyteimg.com',
			'ibytedtos.com',
			'bytefcdn-oversea.com',
			'muscdn.com',
			'musical.ly'
		],
		ips: []
	},
	twitter: {
		name: 'X / Twitter',
		tag: 'x_twitter',
		domains: [
			'x.com',
			'www.x.com',
			'mobile.x.com',
			'api.x.com',
			'twitter.com',
			'www.twitter.com',
			'mobile.twitter.com',
			'api.twitter.com',
			't.co',
			'twimg.com',
			'pbs.twimg.com',
			'video.twimg.com',
			'abs.twimg.com',
			'tweetdeck.twitter.com',
			'twitteroauth.com',
			'twitterstat.us',
			'twtrdns.net',
			'twttr.com',
			'twttr.net'
		],
		ips: []
	},
	discord: {
		name: 'Discord',
		tag: 'discord',
		domains: [
			'discord.com',
			'www.discord.com',
			'discord.gg',
			'discordapp.com',
			'discordapp.net',
			'discordcdn.com',
			'cdn.discordapp.com',
			'media.discordapp.net',
			'images-ext-1.discordapp.net',
			'images-ext-2.discordapp.net',
			'gateway.discord.gg'
		],
		ips: []
	},
	openai: {
		name: 'OpenAI / ChatGPT / Codex',
		tag: 'openai_chatgpt_codex',
		domains: [
			'openai.com',
			'www.openai.com',
			'chatgpt.com',
			'chat.openai.com',
			'auth.openai.com',
			'api.openai.com',
			'platform.openai.com',
			'cdn.openai.com',
			'oaistatic.com',
			'oaiusercontent.com',
			'chatgpt.livekit.cloud',
			'intercom.io',
			'intercomcdn.com',
			'sentry.io'
		],
		ips: []
	},
	canva: {
		name: 'Canva',
		tag: 'canva',
		domains: [
			'canva.com',
			'www.canva.com',
			'api.canva.com',
			'static.canva.com',
			'content.canva.com',
			'media.canva.com',
			'font.canva.com',
			'canva.cn',
			'canva-apps.com',
			'canva.dev'
		],
		ips: []
	}
};

var PRESET_ORDER = [ 'telegram', 'youtube', 'instagram', 'tiktok', 'twitter', 'discord', 'openai', 'canva' ];

function runApply() {
	return fs.exec_direct('/usr/bin/podkopchikctl', [ 'apply' ]);
}

function presetLabel(key) {
	if (key == 'telegram')
		return _('Telegram');
	if (key == 'youtube')
		return _('YouTube');
	if (key == 'instagram')
		return _('Instagram');
	if (key == 'tiktok')
		return _('TikTok');
	if (key == 'twitter')
		return _('X / Twitter');
	if (key == 'discord')
		return _('Discord');
	if (key == 'openai')
		return _('OpenAI / ChatGPT / Codex');
	if (key == 'canva')
		return _('Canva');

	return key;
}

function sections(type) {
	return uci.sections('podkopchik', type) || [];
}

function targetOf(section, fallback) {
	return section.target || fallback;
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

function existingDomainSet(target) {
	var set = {};

	sections('domain_rule').forEach(function(rule) {
		if (targetOf(rule, AUTO_GROUP_TAG) != target)
			return;

		domainValues(rule).forEach(function(domain) {
			set[domain] = true;
		});
	});

	return set;
}

function existingIpSet(target) {
	var set = {};

	sections('ip_rule').forEach(function(rule) {
		if (targetOf(rule, 'direct') != target)
			return;

		if (rule.cidr)
			set[String(rule.cidr).trim().toLowerCase()] = true;
	});

	return set;
}

function findPresetDomainSection(preset, target) {
	var found = null;

	sections('domain_rule').forEach(function(rule) {
		if (!found && targetOf(rule, AUTO_GROUP_TAG) == target && (rule.group_tag || '') == preset.tag)
			found = rule;
	});

	return found;
}

function groupTagUsed(tag) {
	var used = false;

	sections('domain_rule').forEach(function(rule) {
		if ((rule.group_tag || '') == tag)
			used = true;
	});

	return used;
}

function uniqueGroupTag(base) {
	var tag = base;
	var i = 2;

	while (groupTagUsed(tag)) {
		tag = base + '_' + i;
		i++;
	}

	return tag;
}

function addDomainRules(preset, key, target, missing) {
	var section = findPresetDomainSection(preset, target);
	var sid, current, tag;

	if (!missing.length)
		return;

	if (section) {
		sid = section['.name'];
		current = domainValues(section);
		tag = section.group_tag || preset.tag;
	}
	else {
		sid = uci.add('podkopchik', 'domain_rule');
		current = [];
		tag = uniqueGroupTag(preset.tag);
		uci.set('podkopchik', sid, 'group_order', String(sections('domain_rule').length));
	}

	uci.set('podkopchik', sid, 'enabled', '1');
	uci.set('podkopchik', sid, 'target', target);
	uci.set('podkopchik', sid, 'group_name', presetLabel(key));
	uci.set('podkopchik', sid, 'group_tag', tag);
	uci.unset('podkopchik', sid, 'domain');
	uci.set('podkopchik', sid, 'domain', current.concat(missing));
}

function addIpRules(preset, target, missing) {
	for (var i = 0; i < missing.length; i++) {
		var sid = uci.add('podkopchik', 'ip_rule');

		uci.set('podkopchik', sid, 'enabled', '1');
		uci.set('podkopchik', sid, 'cidr', missing[i]);
		uci.set('podkopchik', sid, 'target', target);
	}
}

function addPresetToUci(key, target) {
	var preset = PRESETS[key];

	if (!preset)
		throw new Error(_('Select a preset service.'));

	if (!target)
		throw new Error(_('Select a target.'));

	var domains = existingDomainSet(target);
	var ips = existingIpSet(target);
	var missingDomains = [];
	var missingIps = [];
	var skipped = 0;

	for (var d = 0; d < preset.domains.length; d++) {
		var domain = preset.domains[d].toLowerCase();

		if (domains[domain]) {
			skipped++;
			continue;
		}

		domains[domain] = true;
		missingDomains.push(domain);
	}

	for (var i = 0; i < preset.ips.length; i++) {
		var cidr = preset.ips[i].toLowerCase();

		if (ips[cidr]) {
			skipped++;
			continue;
		}

		ips[cidr] = true;
		missingIps.push(cidr);
	}

	addDomainRules(preset, key, target, missingDomains);
	addIpRules(preset, target, missingIps);

	return {
		addedDomains: missingDomains.length,
		addedIps: missingIps.length,
		added: missingDomains.length + missingIps.length,
		skipped: skipped
	};
}

function targetOptions() {
	var out = [
		{ value: AUTO_GROUP_TAG, label: _('Automatic: main + backups') },
		{ value: 'direct', label: _('Direct') }
	];

	sections('proxy_group').forEach(function(group) {
		var tag = group.tag || group.name;

		if (tag && tag != AUTO_GROUP_TAG)
			out.push({ value: tag, label: (group.name || tag) + ' (' + _('group') + ')' });
	});

	sections('proxy').forEach(function(proxy) {
		var tag = proxy.tag || proxy.name;

		if (tag)
			out.push({ value: tag, label: (proxy.name || tag) + ' (' + _('proxy') + ')' });
	});

	return out;
}

function option(value, label, selected) {
	return E('option', { value: value, selected: selected ? 'selected' : null }, label);
}

function resultText(result) {
	return [
		_('Rules added') + ': ' + result.added,
		_('Duplicates skipped') + ': ' + result.skipped
	].join('\n');
}

return view.extend({
	load: function() {
		return uci.load('podkopchik');
	},

	render: function() {
		var serviceSelect = E('select', { 'class': 'cbi-input-select', 'id': 'podkopchik-preset-service' },
			PRESET_ORDER.map(function(key) {
				return option(key, presetLabel(key), key == 'telegram');
			}));

		var targetSelect = E('select', { 'class': 'cbi-input-select', 'id': 'podkopchik-preset-target' },
			targetOptions().map(function(item, idx) {
				return option(item.value, item.label, idx == 0);
			}));

		return E([
			E('h2', _('Presets')),
			E('div', { 'class': 'cbi-map-descr' }, _('Presets quickly create ordinary editable domain and IP rules. After adding a preset, you can edit or delete the created rules on the Domain Groups and IP Rules pages.')),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title', 'for': 'podkopchik-preset-service' }, _('Service')),
					E('div', { 'class': 'cbi-value-field' }, serviceSelect)
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title', 'for': 'podkopchik-preset-target' }, _('Target')),
					E('div', { 'class': 'cbi-value-field' }, targetSelect)
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('div', { 'class': 'cbi-value-field' }, [
						E('button', {
							'class': 'btn cbi-button cbi-button-apply',
							'click': ui.createHandlerFn(this, function() {
								var result;
								var service = document.getElementById('podkopchik-preset-service').value;
								var target = document.getElementById('podkopchik-preset-target').value;

								try {
									result = addPresetToUci(service, target);
								}
								catch (e) {
									ui.addNotification(_('Validation error'), E('p', e.message || String(e)), 'error');
									return Promise.reject(e);
								}

								return uci.save().then(function() {
									return ui.changes.apply();
								}).then(function() {
									return runApply();
								}).then(function(res) {
									ui.addNotification(_('Preset added'), E('pre', { 'style': 'white-space: pre-wrap' }, resultText(result) + (res ? '\n\n' + res : '')));
								}).catch(function(err) {
									var message = err && err.message ? err.message : String(err);
									ui.addNotification(_('Failed to add preset'), E('pre', { 'style': 'white-space: pre-wrap' }, resultText(result) + '\n\n' + _('Runtime apply failed') + ': ' + message), 'error');
									return Promise.reject(err);
								});
							})
						}, _('Add preset'))
					])
				])
			])
		]);
	}
});
