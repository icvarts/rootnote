const test = require('node:test');
const assert = require('node:assert/strict');
const M = require('../Resources/guard/model.js');

test('missing metrics are unknown, not zero', () => {
  for (const value of [null, undefined, NaN, Infinity, -1, '10']) assert.equal(M.bytes(value), '—');
  assert.equal(M.bytes(0), '0 B'); assert.equal(M.bytes(150e6), '150 MB');
});
test('runtime states need explicit events, not active false', () => {
  assert.equal(M.taskState({ active: false }), 'unknown');
  assert.equal(M.taskState({ taskStatus: 'completed' }), 'completed');
  assert.equal(M.taskState({ taskStatus: 'stopped' }), 'stopped');
  assert.equal(M.taskState({ taskStatus: 'running', eventAt: new Date().toISOString() }), 'running');
  assert.equal(M.taskState({ taskStatus: 'running', eventAt: '2020-01-01' }), 'unknown');
  assert.equal(M.taskState({ taskStatus: 'running', eventAt: null }), 'unknown');
});
test('quota periods are server-defined; missing windows stay missing', () => {
  assert.equal(M.period(10080), '每周'); assert.equal(M.period(300), '5 小时');
  assert.equal(M.period(1440), '1 天'); assert.equal(M.period(90), '90 分钟');
  assert.equal(M.period(null), '未知周期');
  for (const usedPercent of [null, -1, 101, NaN]) assert.equal(M.remaining({ usedPercent }), null);
  assert.equal(M.remaining({ usedPercent: 0 }), 100);
  assert.equal(M.remaining({ usedPercent: 100 }), 0);
});
test('only eligible, dated gifts generate reminders', () => {
  const settings = { giftReminder: true, resetReminder: true, leadDays: 3 };
  assert.deepEqual(M.reminders({ resetCredits: { availableCount: 3 } }, settings, 100), []);
  const account = { updatedAt: 50, resetCredits: { items: [
    { status: 'available', expiresAt: 200 }, { status: 'consumed', expiresAt: 200 },
    { status: 'available', expiresAt: 90 }, { status: 'available', expiresAt: null },
  ] }, buckets: [{ windows: [{ resetsAt: 80 }] }] };
  assert.deepEqual(M.reminders(account, settings, 100).map(r => r.kind), ['gift', 'reset']);
  assert.equal(M.reminders(account, {}, 100).length, 0);
  account.updatedAt = 90;
  assert.deepEqual(M.reminders(account, settings, 100).map(r => r.kind), ['gift']);
});

test('performance advice respects completed, running and unknown tasks', () => {
  const p = { collectorHealth: 'healthy', microState: 'red', sessions: [{ severity: 3, taskStatus: 'completed' }] };
  assert.match(M.performance(p).advice, /本轮已完成/);
  assert.doesNotMatch(M.performance(p).advice, /先收尾|停止/);
  p.sessions[0].taskStatus = 'running'; p.sessions[0].eventAt = new Date().toISOString();
  assert.match(M.performance(p).advice, /仍在进行/);
  p.sessions[0].eventAt = '2020-01-01';
  assert.doesNotMatch(M.performance(p).advice, /仍在进行|本轮已完成/);
  p.sessions = [];
  assert.match(M.performance(p).title, /系统资源/);
  p.collectorHealth = 'degraded';
  assert.equal(M.performance(p).level, 'unknown');
});

test('trend uses actual sorted times, rejects missing samples and invalid values', () => {
  const result = M.trend([{ timestamp: 900, sessions: 10 }, { sessions: 20 }, { timestamp: 900, sessions: 12 }, { timestamp: 990, sessions: 20 }, { timestamp: 950, sessions: 14 }, { timestamp: 980, sessions: -1 }], 1000);
  assert.deepEqual(result.points.map(p => p.timestamp), [900, 950, 990]);
  assert.equal(result.duration, 90);
  assert.equal(result.delta, 8);
  assert.equal(result.ready, true);
  assert.equal(M.trend([{ sessions: 20 }], 1000).ready, false);
  assert.equal(M.trend([{ timestamp: 900, sessions: 12 }], 1000).ready, false);
  assert.equal(M.trend([{ timestamp: 1, sessions: 12 }], 100000).ready, false);
});

test('account freshness never uses performance collection time', () => {
  assert.equal(M.accountTime({ updatedAt: 100 }), 100);
  for (const updatedAt of [null, undefined, 0, -1, NaN, '100']) assert.equal(M.accountTime({ updatedAt }), null);
});

test('session actions follow local thresholds and task state, never auto-archive', () => {
  const row = { taskStatus: 'completed', sizeBytes: 100e6 };
  assert.match(M.sessionAdvice(row), /暂不需要归档/);
  row.sizeBytes = 250e6; assert.match(M.sessionAdvice(row), /整理进展/);
  row.sizeBytes = 500e6 - 1; assert.doesNotMatch(M.sessionAdvice(row), /建议归档/);
  row.sizeBytes = 500e6; assert.match(M.sessionAdvice(row), /建议归档/);
  row.sizeBytes = 1e9; assert.match(M.sessionAdvice(row), /优先归档/);
  for (const taskStatus of ['unknown', 'waiting', 'failed', 'stopped']) {
    assert.match(M.sessionAdvice({ ...row, taskStatus }), /先查看任务状态/);
  }
  assert.doesNotMatch(M.sessionAdvice({ ...row, taskStatus: 'running', eventAt: new Date().toISOString() }), /归档/);
  assert.match(M.sessionAdvice(row, false), /先刷新/);
  assert.match(M.sessionAdvice({ ...row, sizeBytes: 20e6, growthBytesPerHour: 200e6 }), /增长较快/);
});

test('quota details preserve fractions and expired gifts are not labelled usable', () => {
  assert.equal(M.percent(69), '69%');
  assert.equal(M.percent(0.4), '0.4%');
  assert.equal(M.percent(null), '未提供');
  assert.equal(M.creditStatus({ status: 'available', expiresAt: 100 }, 100), '已到期，待同步');
  assert.equal(M.creditStatus({ status: 'available', expiresAt: 101 }, 100), '可用');
  assert.equal(M.creditStatus({ status: 'consumed', expiresAt: 101 }, 100), '已使用');
  assert.equal(M.creditStatus({ status: 'unrecognised' }), '状态待确认');
});
