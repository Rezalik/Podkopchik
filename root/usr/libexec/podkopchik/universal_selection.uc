'use strict';

function fresh(value, now) {
	return value?.status == 'up' && value.probe_status == 'up' &&
		type(value.checked_at) == 'int' && value.checked_at <= now &&
		now - value.checked_at < 300;
}

// Runtime probes supply the existing fail/restore threshold decisions. This
// selector cannot promote a stale probe or a tunnel without kernel ownership.
function select(group, ready, previous, now, cooldown) {
	if (!group) return { active: 'blocked', reason: 'no_automatic_group' };
	let backups = group.backups || [], fixed = group.mode == 'fixed_proxy';
	let preferred = fixed ? group.fixed_proxy : group.primary;
	let available = tag => tag && ready[tag] == true;
	if (group.manual_override_proxy && !fixed)
		return available(group.manual_override_proxy) ?
			{ active: group.manual_override_proxy, reason: 'manual_override' } :
			{ active: 'blocked', reason: 'manual_override_unavailable' };
	if (!fixed && group.mode != 'strict_primary') die('unsupported automatic group mode');
	if (fixed && group.failure_action != 'switch_to_backup') backups = [];
	let members = [preferred, ...backups], current = previous?.active_proxy;
	let keep = index(members, current) >= 0 && available(current);
	let elapsed = now - (previous?.last_switch_time || 0);
	if (keep && current != preferred && available(preferred) &&
		((!fixed && !group.auto_return) || (elapsed >= 0 && elapsed < cooldown)))
		return { active: current, reason: 'keep_healthy_backup' };
	if (available(preferred)) return { active: preferred, reason: 'preferred_healthy' };
	for (let tag in backups) if (available(tag)) return { active: tag, reason: 'backup_healthy' };
	return { active: 'blocked', reason: 'no_healthy_transport' };
}

return { fresh, select };
