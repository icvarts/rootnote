(function (root) {
  'use strict';
  const number = value => typeof value === 'number' && Number.isFinite(value);
  function bytes(value) {
    if (!number(value) || value < 0) return '—';
    if (value < 1000) return value + ' B';
    const unit = value >= 1e9 ? 1e9 : value >= 1e6 ? 1e6 : 1e3;
    return (value / unit).toFixed(1).replace(/\.0$/, '') + ' ' + ({ 1e9: 'GB', 1e6: 'MB', 1e3: 'KB' }[unit]);
  }
  function taskState(task, now = Date.now()) {
    const allowed = ['running', 'completed', 'failed', 'stopped', 'waiting'];
    if (!allowed.includes(task.taskStatus)) return 'unknown';
    const at = Date.parse(task.eventAt);
    if (task.taskStatus === 'running' && (!Number.isFinite(at) || now - at > 30 * 60 * 1000 || at > now + 60_000)) return 'unknown';
    return task.taskStatus;
  }
  function period(minutes) {
    if (!number(minutes) || minutes <= 0) return '未知周期';
    if (minutes === 10080) return '每周';
    if (minutes % 1440 === 0) return `${minutes / 1440} 天`;
    if (minutes % 60 === 0) return `${minutes / 60} 小时`;
    return `${minutes} 分钟`;
  }
  function remaining(window) {
    return number(window.usedPercent) && window.usedPercent >= 0 && window.usedPercent <= 100 ? 100 - window.usedPercent : null;
  }
  function reminders(account, settings, now = Date.now() / 1000) {
    const results = [];
    if (settings.giftReminder) for (const item of account.resetCredits?.items || []) {
      if (item.status === 'available' && number(item.expiresAt) && item.expiresAt > now && item.expiresAt - now <= (settings.leadDays || 3) * 86400) results.push({ kind: 'gift', at: item.expiresAt });
    }
    if (settings.resetReminder) for (const bucket of account.buckets || []) for (const window of bucket.windows || []) {
      if (number(window.resetsAt) && window.resetsAt <= now && window.resetsAt > account.updatedAt) results.push({ kind: 'reset', at: window.resetsAt });
    }
    return results;
  }
  function performance(p, now = Date.now()) {
    if (!p || p.collectorHealth !== 'healthy') return { level: 'unknown', title: '性能数据待确认', advice: '部分数据暂不可用，不能据此判断性能正常。' };
    const level = ['green', 'yellow', 'red'].includes(p.microState) ? p.microState : 'unknown';
    const risks = (p.sessions || []).filter(row => row.severity > 0);
    const running = risks.some(row => taskState(row, now) === 'running');
    const completed = risks.length && risks.every(row => taskState(row, now) === 'completed');
    if (level === 'green') return { level, title: '暂未发现明显异常', advice: '继续工作即可，无需处理会话。' };
    if (level === 'unknown') return { level, title: '性能数据待确认', advice: '请刷新后重新查看。' };
    return { level, title: risks.length ? `${risks.length} 个会话体积较大` : '系统资源占用偏高',
      advice: completed ? '这些会话本轮已完成。需要继续时，可整理进展后另开会话。'
        : running ? '会话仍在进行。若出现卡顿，可保存进展后转到新会话。'
        : risks.length ? '查看下方会话；是否继续或归档，由你决定。'
        : '若出现卡顿，请查看活动监视器，确认具体占用。' };
  }
  function trend(history, now = Date.now() / 1000) {
    const unique = new Map();
    for (const point of history || []) {
      if (number(point.timestamp) && point.timestamp > 0 && point.timestamp <= now + 60 &&
          point.timestamp >= now - 86400 && number(point.sessions) && point.sessions >= 0) unique.set(point.timestamp, point.sessions);
    }
    const points = [...unique].sort((a, b) => a[0] - b[0]).map(([timestamp, sessions]) => ({ timestamp, sessions }));
    const first = points[0], last = points.at(-1);
    const duration = first && last ? last.timestamp - first.timestamp : 0;
    return { points, duration, first, last, delta: first && last ? last.sessions - first.sessions : null, ready: points.length >= 2 && duration > 0 };
  }
  function accountTime(account) { return number(account.updatedAt) && account.updatedAt > 0 ? account.updatedAt : null; }
  function sessionAdvice(row, healthy = true, now = Date.now()) {
    if (!healthy) return '先刷新确认数据，再决定是否处理。';
    const status = taskState(row, now);
    if (status === 'running') return row.sizeBytes >= 500e6
      ? '任务进行中；本轮结束后整理进展，后续另开会话。'
      : '任务进行中；可继续，出现卡顿时先保存进展。';
    if (['unknown', 'waiting', 'failed', 'stopped'].includes(status)) return '先查看任务状态，确认无需继续后再考虑归档。';
    if (row.sizeBytes >= 1e9) return '建议优先归档；需要继续时，整理进展后另开会话。';
    if (row.sizeBytes >= 500e6) return '若不再继续，建议归档；后续需求另开会话。';
    if (row.sizeBytes >= 250e6) return '建议整理进展，后续需求另开会话。';
    if (row.growthBytesPerHour >= 200e6) return '近期增长较快，建议检查内容并整理进展。';
    return '暂不需要归档，继续留意体积变化。';
  }
  function percent(value) {
    return number(value) ? Number(value.toFixed(1)).toString() + '%' : '未提供';
  }
  function creditStatus(item, now = Date.now() / 1000) {
    if (item.status === 'available' && number(item.expiresAt) && item.expiresAt <= now) return '已到期，待同步';
    return { available: '可用', consumed: '已使用', expired: '已到期' }[item.status] || '状态待确认';
  }
  const api = { number, bytes, taskState, period, remaining, reminders, performance, trend, accountTime, sessionAdvice, percent, creditStatus };
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.RootnoteModel = api;
})(typeof window === 'undefined' ? globalThis : window);
