(() => {
  'use strict';
  const M = window.RootnoteModel;
  const $ = id => document.getElementById(id);
  const native = Boolean(window.webkit?.messageHandlers?.rootnote);
  let state = { performance: null, account: { accounts: [], settings: {} }, pinned: false };
  let tab = 'tasks', previousTab = 'tasks', selected = null, noticeTimer;
  const drafts = new Map();
  const states = {
    running: ['进行中', 'loader-circle', 'blue', '最近仍有任务活动'],
    completed: ['本轮完成', 'circle-check', 'green', '本轮已结束，可以查看结果'],
    waiting: ['待处理', 'circle-help', 'amber', '请在 Codex 中处理'],
    failed: ['未完成', 'circle-alert', 'red', '请打开会话检查'],
    stopped: ['已停止', 'circle-pause', 'muted', '任务已停止，可以继续跟进'],
    unknown: ['待确认', 'circle-dashed', 'muted', '暂时没有足够的新状态'],
  };
  function el(tag, text, cls) {
    const node = document.createElement(tag);
    if (text != null) node.textContent = text;
    if (cls) node.className = cls;
    return node;
  }
  function icon(name, cls = '') { const i = el('i', null, cls); i.dataset.lucide = name; return i; }
  function icons() { window.lucide.createIcons({ attrs: { 'aria-hidden': 'true' } }); }
  function empty(title, description = '') {
    const node = el('div', null, 'empty'); node.append(icon('leaf'), el('div', title), el('p', description)); return node;
  }
  function send(action, data = {}) {
    if (native) window.webkit.messageHandlers.rootnote.postMessage({ action, ...data });
    else window.dispatchEvent(new CustomEvent('rootnote-action', { detail: { action, ...data } }));
  }
  function notice({ message }) {
    clearTimeout(noticeTimer); $('notice').textContent = message; $('notice').hidden = false;
    noticeTimer = setTimeout(() => { $('notice').hidden = true; }, 6000);
  }
  function date(seconds) {
    if (!M.number(seconds) || seconds <= 0) return '时间未知';
    return new Date(seconds * 1000).toLocaleString('zh-CN', { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false });
  }
  function showTab(name) {
    if (name !== 'settings') previousTab = name;
    tab = name;
    for (const view of document.querySelectorAll('.view')) view.hidden = view.id !== `view-${name}`;
    for (const button of document.querySelectorAll('[data-tab]')) {
      const active = button.dataset.tab === name;
      button.setAttribute('aria-selected', String(active)); button.tabIndex = active ? 0 : -1;
    }
    $('settings').setAttribute('aria-pressed', String(name === 'settings'));
    footer(); syncChrome();
  }
  function tasks() {
    const source = Array.isArray(state.performance?.sessions) ? state.performance.sessions : [];
    const rank = { waiting: 0, failed: 1, running: 2, completed: 3, stopped: 4, unknown: 5 };
    return source.map(task => ({ ...task, status: M.taskState(task) }))
      .sort((a, b) => rank[a.status] - rank[b.status]);
  }
  function renderTasks() {
    const rows = tasks();
    if (!rows.some(row => row.threadID === selected)) selected = rows[0]?.threadID || null;
    const count = status => rows.filter(row => row.status === status).length;
    const attention = count('waiting') + count('failed');
    $('task-count').textContent = attention ? String(attention) : '';
    $('tab-tasks').title = attention ? `${attention} 项需要处理` : '任务';
    $('task-summary').replaceChildren();
    for (const [name, status] of [['进行中', 'running'], ['待处理', 'waiting'], ['未完成', 'failed'], ['本轮完成', 'completed']]) {
      if (count(status)) $('task-summary').append(el('span', `${name} ${count(status)}`));
    }
    if (!$('task-summary').childElementCount) $('task-summary').textContent = state.performance ? '暂无明确活动' : '正在读取';
    const focused = document.activeElement?.dataset?.task;
    $('tasks').replaceChildren();
    for (const row of rows) {
      const [label, glyph, cls, description] = states[row.status];
      const button = el('button', null, 'task' + (row.threadID === selected ? ' selected' : ''));
      button.dataset.task = row.threadID; button.setAttribute('aria-pressed', String(row.threadID === selected));
      const at = Date.parse(row.eventAt);
      const detail = Number.isFinite(at) ? `最近活动 ${date(at / 1000)}` : description;
      const content = el('div'); content.append(el('div', row.title || '未命名会话', 'task-title'), el('p', detail, 'task-description'));
      button.append(icon(glyph, cls), content, el('span', label, `task-state ${cls}`));
      button.title = row.title || '未命名会话';
      button.onclick = () => {
        if (selected) drafts.set(selected, $('prompt').value);
        selected = row.threadID; renderTasks(); icons();
      };
      $('tasks').append(button);
      if (focused === row.threadID) button.focus({ preventScroll: true });
    }
    if (!rows.length) $('tasks').append(empty(state.performance ? '暂无可识别的本机会话' : '正在读取任务状态', '云端任务与未打开的会话不在此列表中。'));
    const chosen = rows.find(row => row.threadID === selected);
    const prompt = $('prompt');
    if (prompt.dataset.thread !== selected) {
      prompt.value = drafts.get(selected) || ''; prompt.dataset.thread = selected || '';
    }
    prompt.disabled = !chosen; $('open-thread').disabled = !chosen;
    prompt.placeholder = !chosen ? '先选择任务' : chosen.status === 'running' ? '写下补充要求…' : '写下后续要求…';
    $('followup-label').textContent = chosen ? `跟进草稿 · ${chosen.title || '未命名会话'}` : '跟进草稿';
    updateSend();
  }
  function updateSend() { $('send').disabled = !selected || !$('prompt').value.trim(); }
  function renderPerformance() {
    const p = state.performance;
    const degraded = !p || p.collectorHealth !== 'healthy';
    const { level } = M.performance(p);
    $('performance-status').textContent = { green: '正常', yellow: '留意', red: '需关注', unknown: '未完整同步' }[level] || '未知';
    $('performance-status').className = 'badge ' + ({ green: 'green', yellow: 'amber', red: 'red' }[level] || 'muted');
    $('risk-dot').className = 'status-dot ' + ({ red: 'on red', yellow: 'on amber', unknown: 'on muted' }[level] || '');
    $('tab-performance').title = '性能 · ' + $('performance-status').textContent;
    $('performance-error').hidden = level !== 'unknown';
    $('performance-error').textContent = '部分数据暂不可用，请刷新后重试。';
    const metrics = p?.metrics || {};
    $('metrics').replaceChildren();
    for (const [label, value] of [['已用 / 总内存', `${M.bytes(metrics.memoryUsedBytes)} / ${M.bytes(metrics.memoryTotalBytes)}`], ['交换内存', M.bytes(metrics.swapUsedBytes)], ['压缩内存', M.bytes(metrics.compressedBytes)]]) {
      const node = el('div'); node.append(el('div', label, 'metric-label'), el('div', value, 'metric-value')); $('metrics').append(node);
    }
    const risks = (p?.sessions || []).filter(row => row.severity > 0).sort((a, b) => b.severity - a.severity || b.sizeBytes - a.sizeBytes);
    $('risks').replaceChildren();
    $('size-definition').hidden = !risks.length;
    for (const row of risks) {
      const node = el('div', null, 'risk'), info = el('div'), actions = el('div');
      info.append(el('div', row.title, 'risk-title'), el('p', (row.riskSource || '会话体积较大') + ' · ' + states[M.taskState(row)][0])); actions.append(el('div', M.bytes(row.sizeBytes), 'risk-value ' + (row.severity >= 3 ? 'red' : 'amber')));
      info.append(el('p', M.sessionAdvice(row, !degraded && level !== 'unknown'), 'risk-advice'));
      const open = el('button', '查看会话', 'text-button'); open.onclick = () => send('openThread', { id: row.threadID }); actions.append(open); node.append(info, actions); $('risks').append(node);
    }
    if (!risks.length && !degraded && level !== 'unknown') {
      $('risks').append(empty(level === 'green' ? '暂无异常会话' : '系统资源占用偏高',
        level === 'green' ? '' : '若出现卡顿，可在活动监视器中查看具体占用。'));
    }
  }
  function renderQuota() {
    const a = state.account || {}, accounts = a.accounts || [], settings = a.settings || {};
    $('quota-error').hidden = !a.error; $('quota-error').textContent = a.error || '';
    $('accounts').replaceChildren();
    let hasReminder = false;
    for (const account of accounts) {
      const reminders = M.reminders(account, settings); hasReminder ||= reminders.length > 0;
      const current = account.id === a.currentAccount;
      const section = el('article', null, 'account'), head = el('div', null, 'account-head'), title = el('div');
      const plan = { plus: 'Plus', pro: 'Pro', free: 'Free', team: 'Team', business: 'Business', enterprise: 'Enterprise' }[account.plan] || (account.plan !== '未知' ? account.plan : null);
      const stamp = M.accountTime(account);
      title.append(el('div', account.label, 'account-title'), el('p', (plan ? plan + ' · ' : '') + (stamp ? '同步于 ' + date(stamp) : '同步时间未知'), 'account-plan'));
      head.append(el('span', String(account.label || 'A').slice(0, 1).toUpperCase(), 'avatar'), title, el('span', current ? '当前账号' : account.id === a.lastKnownAccount ? '身份待确认' : '历史记录', 'badge ' + (current ? 'green' : 'muted'))); section.append(head);
      if (!current) section.append(el('p', '以下为上次同步记录，不代表当前登录账号的实时额度。', 'caption snapshot-note'));
      const buckets = account.buckets || [];
      let count = 0;
      for (const bucket of buckets) for (const window of bucket.windows || []) {
        count += 1;
        const remaining = M.remaining(window), row = el('div', null, 'quota-window'), label = el('div', null, 'quota-label');
        const value = el('strong', remaining === null ? '—' : M.percent(remaining)); value.append(el('small', '剩余'));
        label.append(el('span', `${buckets.length > 1 ? (bucket.name || bucket.id || '额度') + ' · ' : ''}${M.period(window.minutes)}额度`), value);
        const track = el('div', null, 'track'), fill = el('span', null, 'fill'); track.hidden = remaining === null; fill.style.width = `${remaining ?? 0}%`; if (remaining !== null && remaining <= 15) fill.style.background = 'var(--amber)'; track.append(fill);
        const resetPassed = M.number(window.resetsAt) && window.resetsAt <= Date.now() / 1000;
        const meta = el('div', null, 'quota-meta');
        meta.append(el('span', remaining === null ? '已用比例未提供' : `已用 ${M.percent(100 - remaining)}`),
          el('span', M.number(window.resetsAt) && window.resetsAt > 0 ? `${date(window.resetsAt)} ${resetPassed ? '已到重置时间，待同步' : '重置'}` : '重置时间未知'));
        row.append(label, track, meta); section.append(row);
      }
      if (!count) section.append(el('p', '当前没有可用的额度明细', 'caption'));
      else section.append(el('p', '总次数与 token 上限未提供，不按百分比推算。', 'caption quota-limit-note'));
      const credits = account.resetCredits, gift = el('div', null, 'gift' + (reminders.some(r => r.kind === 'gift') ? ' due' : '')), detail = el('div');
      const giftCount = M.number(credits?.availableCount) ? credits.availableCount : null;
      detail.append(el('div', giftCount === null ? '赠送重置机会：数量未提供' : `赠送重置机会 · ${giftCount} 次`));
      const items = credits?.items || [];
      const list = el('ul', null, 'credit-list');
      items.forEach((item, index) => {
        const line = el('li'), heading = el('div', null, 'credit-heading');
        const type = item.resetType === 'codexRateLimits' ? 'Codex 额度重置' : '赠送机会';
        heading.append(el('span', `${type} ${index + 1}`), el('span', M.creditStatus(item), 'caption'));
        line.append(heading, el('p', M.number(item.expiresAt) && item.expiresAt > 0 ? `${date(item.expiresAt)} 到期` : '到期时间未提供'));
        list.append(line);
      });
      if (items.length) detail.append(list);
      if (!items.length) detail.append(el('p', giftCount === 0 ? '暂无可用机会' : '机会明细暂未提供'));
      else if (giftCount !== null && giftCount > items.filter(item => item.status === 'available').length) detail.append(el('p', '仅列出已返回的部分明细'));
      if (giftCount > 0 || items.length) detail.append(el('p', '在 Codex 中使用'));
      gift.append(icon('gift'), detail); section.append(gift);
      if (reminders.some(r => r.kind === 'reset')) section.append(el('p', '已到预计重置时间，请切换到该账号后同步确认。', 'caption amber'));
      $('accounts').append(section);
    }
    if (!accounts.length) $('accounts').append(empty(a.syncing ? '正在同步当前账号' : '尚未同步账号', '登录 Codex 后刷新，不需要在这里再次登录。'));
    $('quota-dot').className = 'status-dot amber' + (hasReminder && !settings.quiet ? ' on' : '');
  }
  function renderSettings() {
    const settings = state.account?.settings || {};
    const appearance = settings.appearance === 'dark' ? 'dark' : 'light';
    document.documentElement.dataset.theme = appearance;
    for (const button of document.querySelectorAll('[data-appearance]')) button.setAttribute('aria-pressed', String(button.dataset.appearance === appearance));
    for (const button of document.querySelectorAll('[data-days]')) { button.setAttribute('aria-pressed', String(Number(button.dataset.days) === (settings.leadDays || 3))); button.disabled = !settings.giftReminder; }
    for (const button of document.querySelectorAll('[data-setting]')) {
      const enabled = Boolean(settings[button.dataset.setting]);
      button.setAttribute('aria-checked', String(button.dataset.inverted ? !enabled : enabled));
    }
    $('pin').setAttribute('aria-checked', String(Boolean(state.pinned)));
  }
  function footer() {
    $('footer-status').textContent = tab === 'quota' ? (state.account?.syncing ? '正在同步当前账号…' : '账号记录仅保存在本机') : tab === 'settings' ? '' : tab === 'tasks' ? '本机已打开的会话 · 不含云端任务' : '只读检查 · 不自动处置';
    $('updated').textContent = ['tasks', 'performance'].includes(tab) ? (state.performance?.timestamp ? '更新于 ' + date(state.performance.timestamp) : '等待读取') : '';
    for (const button of document.querySelectorAll('[data-refresh="account"]')) button.disabled = Boolean(state.account?.syncing);
  }
  function syncChrome() {
    if (!document.documentElement.classList.contains('native-chrome')) return;
    send('panelContext', { tab, attention: Number($('task-count').textContent) || 0,
      risk: M.performance(state.performance).level, quotaReminder: $('quota-dot').classList.contains('on') });
  }
  function update(value) {
    if (!value || typeof value !== 'object') return;
    state = value; renderSettings(); renderTasks(); renderPerformance(); renderQuota(); footer(); syncChrome(); icons();
  }
  for (const button of document.querySelectorAll('[data-tab]')) {
    button.onclick = () => showTab(button.dataset.tab);
    button.onkeydown = event => {
      if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
      event.preventDefault(); const tabs = [...document.querySelectorAll('[data-tab]')], index = tabs.indexOf(button);
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1 : (index + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length;
      tabs[next].click(); tabs[next].focus();
    };
  }
  $('settings').onclick = () => showTab(tab === 'settings' ? previousTab : 'settings');
  $('close').onclick = () => send('hide'); $('pin').onclick = () => send('pin');
  for (const button of document.querySelectorAll('[data-refresh]')) button.onclick = () => send('refresh', { scope: button.dataset.refresh });
  $('prompt').oninput = () => { drafts.set(selected, $('prompt').value); updateSend(); };
  $('send').onclick = () => send('copyFollowup', { id: selected, text: $('prompt').value.trim() });
  $('open-thread').onclick = () => send('openThread', { id: selected });
  for (const button of document.querySelectorAll('[data-appearance]')) button.onclick = () => send('setting', { key: 'appearance', value: button.dataset.appearance });
  for (const button of document.querySelectorAll('[data-days]')) button.onclick = () => send('setting', { key: 'leadDays', value: Number(button.dataset.days) });
  for (const button of document.querySelectorAll('[data-setting]')) button.onclick = () => {
    const enabled = button.getAttribute('aria-checked') !== 'true';
    send('setting', { key: button.dataset.setting, value: button.dataset.inverted ? !enabled : enabled });
  };
  $('clear').onclick = () => { $('clear-confirm').hidden = false; $('clear-cancel').focus(); };
  $('clear-cancel').onclick = () => { $('clear-confirm').hidden = true; $('clear').focus(); };
  $('clear-yes').onclick = () => { send('clearAccounts'); $('clear-confirm').hidden = true; };
  $('quota-help').onclick = () => $('help-dialog').showModal();
  $('help-close').onclick = () => $('help-dialog').close();
  if (!native) document.body.classList.add('browser');
  window.RootnotePanel = { update, notice, showTab, currentTab: () => tab };
  update(state);
})();
