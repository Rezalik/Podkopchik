// Test-only file-backed UCI adapter. Production never adds this search path.
import * as fs from 'fs';
function cursor() {
	let path = getenv('PODKOPCHIK_TEST_UCI'), rows = path ? json(fs.readfile(path) || '[]') : [];
	function find(sid) { for (let r in rows) if (r['.name'] == sid) return r; return null; }
	return {
		load: function(config) { return true; },
		foreach: function(config, type, cb) {
			for (let r in [ ...rows ]) if (r['.type'] == type && cb(r) == false) break;
		},
		get: function(config, sid, option) { let r = find(sid); return option ? r?.[option] : r?.['.type']; },
		get_all: function(config, sid) { return find(sid); },
		set: function(config, sid, key, value) {
			let r = find(sid);
			if (value == null) { if (r) return false; push(rows, { '.name': sid, '.type': key }); return true; }
			if (!r) return false; r[key] = value; return true;
		},
		delete: function(config, sid, key) {
			if (key) { let r = find(sid); if (r) delete r[key]; }
			else rows = filter(rows, function(r) { return r['.name'] != sid; });
			return true;
		},
		add: function(config, type) {
			let n = length(rows), sid = 'cfg' + n;
			while (find(sid)) sid = 'cfg' + (++n);
			push(rows, { '.name': sid, '.type': type }); return sid;
		},
		commit: function(config) { return path && fs.writefile(path, sprintf('%J', rows)) > 0; }
	};
}
export { cursor };
