const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const crypto = require('node:crypto');
const { pathToFileURL } = require('node:url');

const out = process.env.QA_OUTPUT || path.resolve(__dirname, '../qa-output/panel');
fs.mkdirSync(out, { recursive: true });
const now = Date.now() / 1000;
const id = n => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const fixture = {
  pinned: false,
  performance: { timestamp: now, collectorHealth: 'healthy', microState: 'yellow',
    metrics: { memoryUsedBytes: 15e9, memoryTotalBytes: 17.2e9, swapUsedBytes: 3.6e9, compressedBytes: 4.2e9, totalOpenBytes: 369.3e6 },
    history: [20, 45, 80, 70, 130, 190, 240, 369].map((n, i) => ({ timestamp: now - (8 - i) * 900, sessions: n * 1e6 })),
    sessions: [
      { threadID: id(1), title: 'Rootnote 性能与额度面板', taskStatus: 'running', eventAt: new Date().toISOString(), severity: 2, sizeBytes: 369.3e6, riskSource: '体积 ≥ 250 MB' },
      { threadID: id(2), title: '产品研究与视觉整理', taskStatus: 'completed', eventAt: new Date().toISOString(), severity: 0, sizeBytes: 4e6 },
    ] },
  account: { currentAccount: 'a', syncing: false, settings: { appearance: 'light', giftReminder: true, resetReminder: true, leadDays: 3, quiet: false }, accounts: [
    { id: 'a', label: 'ac•••@example.test', plan: 'prolite', updatedAt: now, buckets: [{ id: 'codex', name: 'Codex', windows: [{ usedPercent: 28, minutes: 300, resetsAt: now + 9000 }, { usedPercent: 46, minutes: 10080, resetsAt: now + 250000 }] }], resetCredits: { availableCount: 2, items: [{ status: 'available', resetType: 'codexRateLimits', expiresAt: now + 86400 }, { status: 'available', resetType: 'codexRateLimits', expiresAt: now + 604800 }] } },
    { id: 'b', label: 'wo•••@example.test', plan: 'plus', updatedAt: now - 86400, buckets: [{ id: 'codex', windows: [{ usedPercent: 60, minutes: 10080, resetsAt: now - 2000 }] }], resetCredits: { availableCount: 1 } },
  ] },
};
(async () => {
  const browser = await chromium.launch({ headless: true, ...(process.env.PLAYWRIGHT_CHANNEL ? { channel: process.env.PLAYWRIGHT_CHANNEL } : {}) });
  const errors = [], checks = [];
  try {
    const page = await browser.newPage({ viewport: { width: 544, height: 650 }, deviceScaleFactor: 2 });
    page.on('pageerror', error => errors.push(error.message));
    await page.addInitScript(() => {
      window.testState = null; window.actions = [];
      window.webkit = { messageHandlers: { rootnote: { postMessage(message) {
        window.actions.push(message);
        if (message.action === 'setting') window.testState.account.settings[message.key] = message.value;
        if (message.action === 'pin') window.testState.pinned = !window.testState.pinned;
        if (message.action === 'clearAccounts') window.testState.account.accounts = [];
        window.RootnotePanel.update(window.testState);
      } } } };
    });
    await page.goto(pathToFileURL(path.resolve(__dirname, '../Resources/guard/panel.html')).href);
    await page.evaluate(data => { window.testState = data; window.RootnotePanel.update(data); }, fixture);
    for (const size of [{ width: 544, height: 650 }, { width: 420, height: 560 }, { width: 900, height: 760 }]) {
      await page.setViewportSize(size);
      for (const theme of ['light', 'dark']) {
        await page.evaluate(theme => { window.testState.account.settings.appearance = theme; window.RootnotePanel.update(window.testState); }, theme);
        for (const view of ['tasks', 'performance', 'quota', 'settings']) {
          if (view === 'settings') await page.locator('#settings').click();
          else await page.locator(`#tab-${view}`).click();
          const layout = await page.evaluate(view => {
            const panel = document.querySelector('.shell').getBoundingClientRect();
            const container = document.querySelector(`#view-${view}`);
            const overflow = [...container.querySelectorAll('*')].filter(el => {
              const r = el.getBoundingClientRect(); return r.width && r.right > innerWidth + 1;
            }).map(el => el.className);
            return { width: panel.width, height: panel.height, overflow, visible: !container.hidden };
          }, view);
          assert.equal(layout.width, size.width); assert.equal(layout.height, size.height);
          assert.deepEqual(layout.overflow, []); assert.equal(layout.visible, true);
          checks.push(`${size.width}-${theme}-${view}-stable`);
          await page.screenshot({ path: path.join(out, `${size.width}-${theme}-${view}.png`) });
        }
      }
    }
    await page.setViewportSize({ width: 544, height: 650 });
    await page.locator('#tab-tasks').click();
    await page.locator('#prompt').fill('保留现有登录，不修改权限');
    const composer = await page.locator('.composer').boundingBox(), sendBox = await page.locator('#send').boundingBox();
    assert(sendBox.x >= composer.x && sendBox.x + sendBox.width <= composer.x + composer.width);
    assert(sendBox.y >= composer.y && sendBox.y + sendBox.height <= composer.y + composer.height);
    assert.match(await page.locator('#send').getAttribute('title'), /粘贴发送/);
    assert.equal(await page.locator('#send svg.lucide-arrow-up').count(), 1);
    await page.locator('#prompt').focus();
    await page.keyboard.press('Meta+a');
    assert.equal(await page.locator('#prompt').evaluate(el => el.selectionEnd - el.selectionStart), '保留现有登录，不修改权限'.length);
    await page.locator('#prompt').fill('保留现有登录，不修改权限');
    checks.push('arrow-inside-composer', 'handoff-not-fake-send', 'text-selection');
    await page.locator('#send').click();
    assert.equal(await page.evaluate(() => window.actions.at(-1).action), 'copyFollowup');
    await page.locator(`[data-task="${id(2)}"]`).click();
    assert.equal(await page.locator('#prompt').getAttribute('placeholder'), '写下后续要求…');
    assert.equal(await page.locator('#prompt').inputValue(), '');
    await page.locator('#prompt').fill('第二个任务独立草稿');
    await page.locator(`[data-task="${id(1)}"]`).click();
    assert.equal(await page.locator('#prompt').inputValue(), '保留现有登录，不修改权限');
    await page.locator('#prompt').focus();
    const focus = await page.evaluate(() => ({ border: getComputedStyle(document.querySelector('.composer')).borderColor, outline: getComputedStyle(document.querySelector('textarea')).outlineStyle }));
    assert.equal(focus.outline, 'none'); assert.equal(focus.border, 'rgb(155, 207, 176)');
    checks.push('per-task-drafts', 'followup-by-status', 'copy-not-approval', 'single-green-focus');
    await page.locator('#tab-quota').click();
    assert.equal(await page.locator('.account').count(), 2);
    assert.match(await page.locator('.account').first().innerText(), /已用 28%/);
    assert.match(await page.locator('.account').first().innerText(), /prolite/);
    assert.equal(await page.locator('.account').first().locator('.credit-list li').count(), 2);
    assert.match(await page.locator('.account').nth(1).innerText(), /上次同步记录/);
    assert.match(await page.locator('.account').nth(1).innerText(), /已到重置时间，待同步/);
    assert.match(await page.locator('.account').nth(1).innerText(), /机会明细暂未提供/);
    checks.push('quota-used-and-remaining', 'unknown-plan-not-hidden', 'each-gift-expiry-listed', 'historical-quota-explicit', 'reset-passed-not-recovered', 'missing-credit-details-explicit');
    assert.equal(await page.locator('#quota-dot').evaluate(el => el.classList.contains('on')), true);
    await page.locator('#settings').click(); await page.locator('[data-setting="quiet"]').click();
    assert.equal(await page.locator('#quota-dot').evaluate(el => el.classList.contains('on')), false);
    assert.equal(await page.locator('[data-setting="quiet"]').getAttribute('aria-checked'), 'false');
    assert.equal(await page.evaluate(() => window.testState.account.settings.quiet), true);
    await page.locator('[data-setting="quiet"]').click();
    assert.equal(await page.locator('#quota-dot').evaluate(el => el.classList.contains('on')), true);
    assert.equal(await page.locator('[data-setting="quiet"]').getAttribute('aria-checked'), 'true');
    assert.equal(await page.evaluate(() => window.testState.account.settings.quiet), false);
    assert.equal(await page.locator('#settings-back').count(), 0);
    assert.equal(await page.locator('.window-tools button').count(), 1);
    assert.equal(await page.locator('[data-appearance]').count(), 2);
    assert.equal(await page.locator('[data-appearance="system"]').count(), 0);
    await page.locator('[data-appearance="light"]').click();
    assert.equal(await page.locator('html').getAttribute('data-theme'), 'light');
    await page.locator('#pin').click(); assert.equal(await page.locator('#pin').getAttribute('aria-checked'), 'true');
    await page.locator('#pin').click();
    await page.locator('#clear').click(); await page.locator('#clear-cancel').click();
    assert.equal(await page.evaluate(() => window.testState.account.accounts.length), 2);
    await page.locator('#clear').click(); await page.locator('#clear-yes').click();
    assert.equal(await page.evaluate(() => window.testState.account.accounts.length), 0);
    checks.push('account-separation', 'reminder-quiet', 'appearance-setting', 'pin-toggle', 'clear-confirmation', 'visible-reminder-preserves-quiet-setting', 'settings-without-back', 'only-settings-in-window-tools', 'two-explicit-appearances');
    await page.evaluate(data => { window.testState = data; window.RootnotePanel.update(data); }, fixture);
    await page.locator('#tab-tasks').click();
    assert.equal(await page.locator('#task-count').innerText(), '');
    assert.doesNotMatch(await page.locator('#task-summary').innerText(), /待处理 0/);
    await page.evaluate(() => {
      window.testState.performance.sessions = [window.testState.performance.sessions[0]];
      window.testState.performance.sessions[0].taskStatus = 'completed';
      window.testState.performance.microState = 'red';
      window.RootnotePanel.update(window.testState);
    });
    const gap = await page.evaluate(() => document.querySelector('.followup').getBoundingClientRect().top - document.querySelector('.task-scroll').getBoundingClientRect().bottom);
    assert(gap < 32);
    await page.locator('#tab-performance').click();
    assert.match(await page.locator('#risks').innerText(), /本轮完成/);
    assert.equal(await page.locator('#performance-title, #performance-advice, #risk-count, #trend').count(), 0);
    assert.match(await page.locator('#risk-dot').getAttribute('class'), /red/);
    assert.doesNotMatch(await page.locator('#view-performance').innerText(), /会话检查|个会话|会话体积变化|已记录|收尾/);
    assert.match(await page.locator('.risk-advice').innerText(), /整理进展/);
    await page.evaluate(() => { window.testState.performance.sessions[0].sizeBytes = 500e6; window.RootnotePanel.update(window.testState); });
    assert.match(await page.locator('.risk-advice').innerText(), /建议归档/);
    await page.evaluate(() => { window.testState.performance.sessions[0].sizeBytes = 369.3e6; window.RootnotePanel.update(window.testState); });
    checks.push('performance-action-by-threshold');
    assert.equal((await page.locator('#view-performance').innerText()).split('369.3 MB').length - 1, 1);
    assert.match(await page.locator('#size-definition').innerText(), /不代表上下文或 token/);
    await page.locator('#view-performance [data-refresh]').click();
    assert.equal(await page.evaluate(() => window.actions.at(-1).scope), 'performance');
    await page.locator('#tab-quota').click();
    assert.equal(await page.locator('#updated').innerText(), '');
    await page.locator('#view-quota [data-refresh]').click();
    assert.equal(await page.evaluate(() => window.actions.at(-1).scope), 'account');
    assert.equal(await page.locator('[data-refresh]:visible').count(), 1);
    await page.evaluate(() => { window.testState.account.syncing = true; window.RootnotePanel.update(window.testState); });
    assert.equal(await page.locator('#view-quota [data-refresh]').isDisabled(), true);
    await page.evaluate(() => { window.testState.account.syncing = false; window.RootnotePanel.update(window.testState); });
    assert.equal(await page.locator('#view-quota [data-refresh]').isDisabled(), false);
    await page.evaluate(() => {
      window.testState.account.error = '同步超时，稍后可重试。已有记录保留。';
      window.testState.account.lastKnownAccount = 'a';
      window.testState.account.currentAccount = null;
      window.RootnotePanel.update(window.testState);
    });
    assert.match(await page.locator('#quota-error').innerText(), /同步超时/);
    assert.match(await page.locator('.account').first().innerText(), /身份待确认/);
    assert.equal(await page.locator('.account').count(), 2);
    assert.doesNotMatch(await page.locator('#accounts').innerText(), /会员到期|非实时/);
    await page.locator('#quota-help').click();
    assert.equal(await page.locator('#help-dialog').evaluate(el => el.open), true);
    await page.keyboard.press('Escape');
    assert.equal(await page.locator('#help-dialog').evaluate(el => el.open), false);
    await page.locator('#settings').click();
    assert.equal(await page.locator('#updated').innerText(), '');
    await page.locator('[data-setting="giftReminder"]').click();
    assert.equal(await page.locator('[data-days="3"]').isDisabled(), true);
    checks.push('zero-counts-removed', 'badge-is-attention-not-total', 'composer-follows-short-list', 'completed-state-without-redundant-advice', 'risk-colors-consistent', 'performance-no-repeated-summary-count-trend', 'file-size-shown-once-with-definition', 'refresh-scoped', 'quota-time-not-performance', 'one-refresh', 'cached-account-on-error', 'help-keyboard-dismiss', 'settings-no-fake-time', 'dependent-reminder-controls');
    await page.evaluate(() => {
      window.testState.performance.history = [];
      window.testState.account.accounts[0].buckets[0].windows[0].usedPercent = null;
      window.RootnotePanel.update(window.testState);
    });
    await page.locator('#tab-performance').click();
    assert.equal(await page.locator('#trend').count(), 0);
    await page.evaluate(data => { window.testState.performance.history = data.performance.history; window.RootnotePanel.update(window.testState); }, fixture);
    assert.equal(await page.locator('#trend').count(), 0);
    await page.locator('#tab-quota').click();
    assert.equal(await page.locator('.track').first().isVisible(), false);
    for (const theme of ['light', 'dark']) {
      await page.evaluate(theme => { window.testState.account.settings.appearance = theme; window.RootnotePanel.update(window.testState); }, theme);
      await page.emulateMedia({ reducedMotion: 'reduce', contrast: 'more' });
      await page.locator('#settings').click();
      await page.screenshot({ path: path.join(out, 'contrast-' + theme + '.png') });
    }
    checks.push('no-chart-with-or-without-history', 'unknown-quota-not-empty-bar', 'high-contrast-themes');
    await page.evaluate(() => {
      window.testState.performance.collectorHealth = 'degraded';
      window.testState.performance.metrics.swapUsedBytes = null;
      window.testState.performance.sessions[0].title = '<img src=x onerror="window.xss=true">';
      window.RootnotePanel.update(window.testState);
    });
    await page.locator('#tab-performance').click();
    assert.match(await page.locator('#metrics').innerText(), /—/);
    assert.equal(await page.locator('#performance-status').innerText(), '未完整同步');
    assert.equal(await page.locator('#performance-error').isVisible(), true);
    assert.equal(await page.evaluate(() => Boolean(window.xss)), false);
    assert.match(await page.locator('.risk-advice').innerText(), /先刷新/);
    checks.push('unknown-not-zero', 'degraded-not-normal', 'untrusted-title-safe');
    await page.evaluate(() => { window.testState.performance.sessions = []; window.RootnotePanel.update(window.testState); });
    assert.doesNotMatch(await page.locator('#view-performance').innerText(), /暂无异常/);
    await page.evaluate(() => { window.testState.performance.collectorHealth = 'healthy'; window.testState.performance.microState = 'red'; window.RootnotePanel.update(window.testState); });
    assert.match(await page.locator('#risks').innerText(), /系统资源占用偏高/);
    assert.equal(await page.locator('#size-definition').isVisible(), false);
    await page.evaluate(() => { window.testState.performance.microState = 'green'; window.RootnotePanel.update(window.testState); });
    assert.equal(await page.locator('#performance-error').isVisible(), false);
    assert.match(await page.locator('#risks').innerText(), /暂无异常会话/);
    checks.push('degraded-empty-not-healthy', 'resource-only-warning-preserved', 'healthy-empty-recovers');
    assert.deepEqual(errors, []);
    const resources = Object.fromEntries(['panel.html', 'panel.css', 'panel.js', 'model.js', 'lucide.min.js'].map(file =>
      [file, crypto.createHash('sha256').update(fs.readFileSync(path.resolve(__dirname, '../Resources/guard', file))).digest('hex')]));
    const report = { ok: true, count: checks.length, checks, resources, browserErrors: errors, realApprovals: 0 };
    fs.writeFileSync(path.join(out, 'report.json'), JSON.stringify(report, null, 2)); console.log(JSON.stringify(report, null, 2));
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
