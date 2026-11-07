'use strict';
const fs = require('fs');
const path = require('path');

function time(epoch) {
	return new Intl.DateTimeFormat('ru-RU', {timeZone:'Europe/Moscow', dateStyle:'short', timeStyle:'medium'}).format(new Date(epoch*1000));
}
function span(v, scale=1, digits=1) {
	return v?.n ? `${(v.min/scale).toFixed(digits)}–${(v.max/scale).toFixed(digits)}` : 'нет данных';
}
function report(config, s) {
	const elapsed = Math.max(0, (s.last?.uptime ?? config.started_mono) - config.started_mono);
	const expected = Math.max(1, Math.floor(elapsed/config.interval)+1);
	const lines = ['# Native RC: Эксплуатационное Наблюдение', '',
		`Начало: ${time(config.started_epoch)} МСК. Дедлайн: ${time(config.deadline_epoch)} МСК.`,
		`Последний снимок: ${s.last_epoch ? time(s.last_epoch)+' МСК' : 'нет данных'}.`,
		`Длительность измерений: ${(elapsed/3600).toFixed(2)} ч. Снимков: ${s.samples || 0}; ожидаемо около ${expected}.`,
		`Сбор: ${s.monitor_finished ? (s.complete ? 'завершён по дедлайну' : 'прерван') : 'продолжается'}. Ошибок сбора: ${s.collection_failures || 0}.`, '',
		'| Показатель | Измеренный диапазон |', '| --- | --- |',
		`| CPU системы, % | ${span(s.resources?.cpu_pct)} |`,
		`| CPU DNS-процесса, % одного ядра | ${span(s.resources?.dns_cpu_core_pct)} |`,
		`| Доступная RAM, МиБ | ${span(s.resources?.mem_available_kib,1024)} |`,
		`| RSS DNS, МиБ | ${span(s.resources?.rss_kib,1024)} |`,
		`| FD DNS | ${span(s.resources?.fd,1,0)} |`,
		`| UDP-сокеты DNS | ${span(s.resources?.udp,1,0)} |`,
		`| TCP-сокеты DNS | ${span(s.resources?.tcp,1,0)} |`,
		`| Conntrack | ${span(s.resources?.conntrack,1,0)} |`, '',
		`Смен PID DNS: ${s.pid_changes || 0}. Наблюдаемых смен транспорта: ${s.active_changes || 0}. Изменений отметки переключения health-check: ${s.switch_timestamp_changes || 0}.`, '',
		'## Контрольные Пробы', '', '| Проба | OK | FAIL | SKIPPED | Максимум отказов подряд |', '| --- | --- | --- | --- | --- |'];
	for (const name of ['dns_udp_tcp','protected_dot','protected_https','wan_control_https','guard_tables']) {
		const p=s.probes?.[name];
		lines.push(`| ${name} | ${p?.ok || 0} | ${p?.fail || 0} | ${p?.skipped || 0} | ${p?.max_consecutive_fail || 0} |`);
	}
	lines.push('', '## AWG', '', '| Подключение | UP/DOWN/UNKNOWN снимков | Ошибок probe | Сбросов счётчиков |', '| --- | --- | --- | --- |');
	for (const [key,t] of Object.entries(s.transports || {})) {
		if (!/^\d+$/.test(key)) continue;
		lines.push(`| ${key} | ${t.up}/${t.down}/${t.unknown} | ${t.probe_down} | ${t.counter_resets} |`);
	}
	lines.push('', '## Границы Вывода', '',
		(s.resources?.cpu_pct?.n || 0)>(s.cpu_fractional_samples || 0) ? 'Часть ранних CPU-замеров имеет целочисленную точность; последующие сохраняют доли процента.' : 'CPU-замеры сохраняют доли процента.',
		'Это измерения, а не автоматическое доказательство долговременной стабильности или отсутствия WAN-утечек.',
		'Снижение FD после смены PID не доказывает устранение накопления. Краткие отказы между снимками могут быть пропущены.',
		'HTTPS-пробы выполняются самим роутером: AWG transport и обычный WAN-контроль. Они не заменяют клиентский тест protected/direct-политики.',
		'guard_tables подтверждает наличие таблиц, но не является packet capture или доказательством неизменности всех правил.',
		'При reboot tmpfs-журнал и непостоянный наблюдатель теряются; неполное окно нельзя объявлять PASS.',
		'24–48-часовую приёмку нельзя завершать до фактического окончания измерений. UDP/QUIC оцениваются отдельно.', '');
	return lines.join('\n');
}

if (require.main === module) {
	const dir=process.argv[2];
	if (!dir) throw Error('Usage: node tools/native-observe-report.js PRIVATE_CAPTURE_DIRECTORY');
	const read=name => {
		const file=path.join(dir,name);
		if (fs.statSync(file).size>256*1024) throw Error('Oversized observation metadata');
		return JSON.parse(fs.readFileSync(file,'utf8'));
	};
	process.stdout.write(report(read('config.json'),read('summary.json')));
}
module.exports={report};
