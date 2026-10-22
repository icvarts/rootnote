const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { pathToFileURL } = require('node:url');

// Documentation only: synthetic host content around the unchanged real component.
// Never attaches to a client, reads accounts, or captures the user's desktop.
(async () => {
  const root = path.resolve(__dirname, '..');
  const images = path.join(root, 'docs/images');
  const reportDir = path.join(root, 'qa-output/sidebar-context');
  const browser = await chromium.launch({ headless: true, chromiumSandbox: true,
    ...(process.env.PLAYWRIGHT_CHANNEL ? { channel: process.env.PLAYWRIGHT_CHANNEL } : {}) });
  const results = [], errors = [], requests = [];
  try {
    const page = await browser.newPage({ viewport: { width: 1000, height: 764 }, deviceScaleFactor: 2 });
    page.on('pageerror', error => errors.push(error.message));
    await page.route('**/*', route => {
      requests.push(route.request().url().split(':')[0]);
      return route.request().url().startsWith('file:') ? route.continue() : route.abort();
    });
    await page.goto(pathToFileURL(path.join(root, 'docs/previews/sidebar-context.html')).href);
    const frame = page.frames().find(item => item.url().endsWith('/sidebar-quota.html'));
    assert(frame, 'the real quota component must load');
    await frame.waitForFunction(() => Boolean(window.SidebarQuota));
    for (const appearance of ['dark', 'light']) {
      await page.evaluate(theme => { document.documentElement.dataset.theme = theme; }, appearance);
      await frame.evaluate(theme => window.SidebarQuota.update({ remaining: 69, appearance: theme }), appearance);
      const host = await page.evaluate(() => {
        const rect = id => { const r = document.getElementById(id).getBoundingClientRect();
          return { x: r.x, y: r.y, width: r.width, height: r.height }; };
        const pet = document.getElementById('preview-pet');
        const composer = document.querySelector('.composer').getBoundingClientRect();
        return { rail: rect('rail'), list: rect('project-list'), account: rect('example-account'),
          pet: rect('preview-pet'), petLoaded: pet.complete && pet.naturalWidth > 0, composerTop: composer.top,
          iframe: rect('capsule-frame'), text: document.body.innerText, icons: document.querySelectorAll('svg.lucide').length };
      });
      const capsule = await frame.locator('#quota').evaluate(element => {
        const r = element.getBoundingClientRect();
        return { x: r.x, y: r.y, width: r.width, height: r.height, text: element.innerText,
          background: getComputedStyle(element).backgroundColor };
      });
      const x = host.iframe.x + capsule.x, y = host.iframe.y + capsule.y;
      assert.equal(host.rail.width, 52);
      assert.deepEqual([capsule.width, capsule.height], [36, 116]);
      assert.equal(x + capsule.width / 2, host.rail.x + host.rail.width / 2);
      assert.equal(x + capsule.width / 2, host.account.x + host.account.width / 2);
      assert.equal(host.account.y - (y + capsule.height), 12);
      assert.ok(x + capsule.width < host.list.x);
      assert.match(capsule.text, /69%/);
      assert.equal(capsule.background, appearance === 'dark' ? 'rgba(22, 25, 24, 0.95)' : 'rgba(240, 242, 241, 0.95)');
      assert.match(host.text, /CV/);
      assert.ok(host.petLoaded);
      assert.ok(host.pet.x > host.list.x + host.list.width);
      assert.ok(host.pet.y + host.pet.height < host.composerTop);
      assert.match(host.text, /合成界面位置示意/);
      assert.ok(host.icons >= 20);
      assert.doesNotMatch(host.text, /@|\/Users\/|EX|icvarts|工作台铸造|真实账号/);
      await page.mouse.move(990, 754);
      await page.screenshot({ path: path.join(images, `sidebar-context-${appearance}.png`) });
      results.push({ appearance, railWidth: 52, capsule: { x, y, width: capsule.width, height: capsule.height },
        account: host.account, accountLetters: 'CV', pet: host.pet, petLoaded: true, petClearOfComposer: true,
        gap: 12, centered: true, projectListClear: true, syntheticQuota: 69 });
    }
    assert.deepEqual(errors, []);
    assert.ok(requests.every(protocol => protocol === 'file'));
    const files = ['docs/previews/sidebar-context.html', 'Resources/guard/sidebar-quota.html',
      'Resources/guard/sidebar-quota.css', 'Resources/guard/sidebar-quota.js', 'Assets/current-desktop-pet.png'];
    const report = { ok: true, results, browserErrors: errors, externalRequests: 0, realClientCaptured: false,
      realAccountRead: false, componentSourceHashes: Object.fromEntries(files.map(file => [file,
        crypto.createHash('sha256').update(fs.readFileSync(path.join(root, file))).digest('hex')])) };
    fs.mkdirSync(reportDir, { recursive: true });
    fs.writeFileSync(path.join(reportDir, 'report.json'), JSON.stringify(report, null, 2) + '\n');
    console.log(JSON.stringify(report, null, 2));
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
