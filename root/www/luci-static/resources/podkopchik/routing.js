'use strict';
'require baseclass';
'require ui';

function flag(value) {
	return value === true || value === 1 || value === '1' || value === 'true';
}

function fromSettings(get) {
	var mode = get('native_classification_mode');
	var action = get('native_unknown_action');
	mode = mode == null ? 'compatible' : mode;
	action = action == null ? 'protected' : action;
	if (['compatible', 'strict'].indexOf(mode) < 0 || ['protected', 'block'].indexOf(action) < 0)
		return null;
	var migration = flag(get('native_migration_restrict_unknown'));
	return {
		mode: mode, migration_restrict_unknown: migration,
		direct_grants_confirmed: flag(get('native_direct_grants_confirmed')),
		unknown_action: action,
		unknown: mode === 'strict' || migration ? (action === 'block' ? 'drop' : 'protected') : 'direct'
	};
}

function activePolicy(status) {
	var value = status && status.classification;
	if (value && ['direct', 'protected', 'drop'].indexOf(value.unknown) >= 0)
		return value;
	// Older status endpoints can prove Direct, but all-down is not a policy.
	var fallback = status && status.unknown_fallback;
	var values = [];
	['4', '6'].forEach(function(family) {
		['tcp', 'udp', 'other'].forEach(function(protocol) {
			values.push(fallback && fallback[family] && fallback[family][protocol]);
		});
	});
	return values.every(function(v) { return v === 'direct'; })
		? { mode: 'compatible', migration_restrict_unknown: false, unknown: 'direct' } : null;
}

function label(value) {
	if (!value) return _('Routing policy unavailable');
	if (value.migration_restrict_unknown) return _('Migration restriction');
	if (value.unknown === 'direct') return _('Selective routing (rules only)');
	return value.unknown === 'drop' ? _('Strict routing with blocking') : _('Strict routing');
}

function description(value) {
	if (!value) return _('Active routing policy is unavailable.');
	if (value.unknown === 'direct')
		return _('Only enabled rules and presets use their selected transport. All other traffic goes directly.');
	if (value.unknown === 'drop')
		return _('Traffic outside the rules is blocked. Explicit direct exceptions still apply.');
	return _('Traffic outside the rules also uses an available main or backup transport. If none is suitable, it is blocked.');
}

function differs(active, configured) {
	return !!active && !!configured && (active.unknown !== configured.unknown ||
		active.mode !== configured.mode || !!active.migration_restrict_unknown !== !!configured.migration_restrict_unknown ||
		active.direct_grants_confirmed != null && configured.direct_grants_confirmed != null &&
			active.direct_grants_confirmed !== configured.direct_grants_confirmed);
}

function notifyApply(result) {
	var parsed = result;
	if (typeof result === 'string') {
		try { parsed = JSON.parse(result); } catch (e) { parsed = null; }
	}
	if (parsed && parsed.engine === 'native' && parsed.confirmation_required === true &&
		/^[a-f0-9]{32}$/.test(parsed.pending || '')) {
		ui.addNotification(_('Apply'), E('div', {}, [
			E('p', {}, parsed.recovery_policy === 'repair'
				? _('Native Apply is pending. Open Status, verify connectivity and confirm. Emergency recovery remains active.')
				: _('Native Apply is pending. Open Status and confirm the configuration before the rollback deadline.')),
			E('a', { href: L.url('admin', 'services', 'podkopchik', 'status') }, _('Open Status'))
		]), 'warning');
	}
	else if (result) {
		ui.addNotification(null, E('pre', { style: 'white-space: pre-wrap' },
			typeof result === 'string' ? result : JSON.stringify(result)));
	}
	return result;
}

return baseclass.extend({
	fromSettings: fromSettings,
	activePolicy: activePolicy,
	label: label,
	description: description,
	differs: differs,
	notifyApply: notifyApply
});
