const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const { spawnSync } = require('node:child_process');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '..');
const scene = path.join(root, 'scene');
const dist = path.join(scene, 'dist');
const out = path.resolve(process.env.QA_OUTPUT || path.join(root, 'qa-output/scene'));
fs.mkdirSync(out, { recursive: true });
const build = spawnSync('pnpm', ['--dir', scene, 'build'], { stdio: 'inherit' });
assert.equal(build.status, 0, 'Install scene dependencies with pnpm --dir scene install --frozen-lockfile first.');

const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.webp': 'image/webp' };
const server = http.createServer((request, response) => {
  let file;
  try {
    const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
    file = path.resolve(dist, '.' + (pathname === '/' ? '/index.html' : pathname));
    if (!file.startsWith(dist + path.sep) || !fs.statSync(file).isFile()) throw new Error('not found');
  } catch {
    response.writeHead(404).end();
    return;
  }
  response.setHeader('Content-Type', types[path.extname(file)] || 'application/octet-stream');
  fs.createReadStream(file).pipe(response);
});

async function pixels(page) {
  return page.locator('#scene-canvas').evaluate(canvas => {
    const gl = canvas.getContext('webgl2');
    if (!gl) return { rendered: 0, lost: true };
    const data = new Uint8Array(canvas.width * canvas.height * 4);
    gl.readPixels(0, 0, canvas.width, canvas.height, gl.RGBA, gl.UNSIGNED_BYTE, data);
    let rendered = 0, signature = 0;
    for (let i = 0; i < data.length; i += 64) {
      if (data[i + 3] > 0) rendered++;
      signature = (signature + data[i] * 3 + data[i + 1] * 5 + data[i + 2] * 7 + data[i + 3]) >>> 0;
    }
    return { rendered, signature, lost: gl.isContextLost(), width: canvas.width, height: canvas.height };
  });
}

(async () => {
  let browser;
  const checks = [], errors = [];
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const url = 'http://127.0.0.1:' + server.address().port;
  try {
    browser = await chromium.launch({
      headless: true,
      args: ['--enable-unsafe-swiftshader'],
      ...(process.env.PLAYWRIGHT_CHANNEL ? { channel: process.env.PLAYWRIGHT_CHANNEL } : {}),
    });
    const page = await browser.newPage();
    page.on('pageerror', error => errors.push(error.message));
    page.on('response', response => {
      if (response.status() >= 400) errors.push(response.status() + ' ' + response.url());
    });
    for (const viewport of [{ width: 1280, height: 800 }, { width: 390, height: 844 }]) {
      await page.setViewportSize(viewport);
      await page.goto(url);
      await page.waitForFunction(() => window.RootnoteSceneLifecycle?.snapshot().attached);
      assert.equal(await page.evaluate(() => window.RootnoteSceneLifecycle.snapshot().suspended), false);
      await page.waitForFunction(() => document.querySelector('#rootnote').naturalWidth > 0);
      for (const world of ['companion', 'margin', 'agents', 'shelter']) {
        await page.locator('[data-state-button="' + world + '"]').click();
        assert.equal(await page.evaluate(() => window.RootnoteResonance.snapshot().world), world);
        checks.push(viewport.width + '-' + world + '-control');
      }
      await page.waitForFunction(() => window.RootnoteResonance.snapshot().tree > 0.5);
      const before = await pixels(page);
      assert(before.rendered > 100 && !before.lost, JSON.stringify(before));
      await page.waitForTimeout(300);
      const after = await pixels(page);
      assert.notEqual(after.signature, before.signature, 'The active scene must animate');
      const layoutHandle = await page.waitForFunction(() => {
        const unloaded = [...document.images].filter(image => image.src && (!image.complete || !image.naturalWidth));
        if (unloaded.length) return false;
        const r = document.querySelector('#rootnote-wrap').getBoundingClientRect();
        return {
          overflow: document.documentElement.scrollWidth > innerWidth,
          unloaded: [],
          pet: { left: r.left, right: r.right, top: r.top, bottom: r.bottom },
        };
      });
      const layout = await layoutHandle.jsonValue();
      await layoutHandle.dispose();
      assert.equal(layout.overflow, false);
      assert.deepEqual(layout.unloaded, []);
      assert(layout.pet.left >= 0 && layout.pet.right <= viewport.width && layout.pet.top >= 0 && layout.pet.bottom <= viewport.height);
      checks.push(viewport.width + '-canvas-nonblank-moving', viewport.width + '-assets-and-framing');
      await page.screenshot({ path: path.join(out, viewport.width + '-scene.png') });
      for (const modifier of ['waiting', 'failure', 'review']) {
        await page.locator('[data-modifier-button="' + modifier + '"]').click();
        assert.equal(await page.evaluate(() => window.RootnoteResonance.snapshot().modifier), modifier);
        checks.push(viewport.width + '-' + modifier + '-control');
      }
      await page.locator('#demo-toggle').click();
      assert.equal(await page.locator('#demo-toggle').getAttribute('aria-pressed'), 'true');
      await page.locator('#demo-toggle').click();
      assert.equal(await page.locator('#demo-toggle').getAttribute('aria-pressed'), 'false');
      checks.push(viewport.width + '-demo-toggle');
    }

    await page.goto(url + '/?desktop=1');
    await page.waitForFunction(() => window.RootnoteSceneLifecycle?.snapshot().attached);
    assert.equal(await page.evaluate(() => window.RootnoteSceneLifecycle.snapshot().suspended), true);
    assert.equal(await page.locator('.scene-bar').isVisible(), false);
    assert.equal(await page.locator('#rootnote-wrap').isVisible(), false);
    checks.push('desktop-starts-paused', 'desktop-does-not-duplicate-native-pet');
    await page.evaluate(() => {
      window.RootnoteSceneLifecycle.setSuspended(false);
      window.RootnoteResonance.dispatch('agents', { agents: 3 });
    });
    await page.waitForFunction(() => window.RootnoteResonance.snapshot().tree > 0.2);
    await page.evaluate(() => window.RootnoteSceneLifecycle.setSuspended(true));
    const paused = await page.evaluate(() => window.RootnoteResonance.snapshot());
    assert.equal(paused.world, 'companion');
    assert.equal(paused.tree, 0);
    await page.waitForTimeout(300);
    assert.deepEqual(await page.evaluate(() => window.RootnoteResonance.snapshot()), paused);
    checks.push('suspend-stops-and-resets-scene');
    await page.evaluate(() => {
      window.RootnoteSceneLifecycle.setSuspended(false);
      window.RootnoteResonance.dispatch('analysis');
    });
    await page.waitForFunction(() => window.RootnoteResonance.snapshot().paths > 0.1);
    assert.equal(await page.evaluate(() => window.RootnoteResonance.dispatch('unknown-event')), false);
    checks.push('resume-and-dispatch', 'unknown-event-rejected');
    assert.deepEqual(errors, []);
    const report = { ok: true, checks, count: checks.length, errors, syntheticData: true, nativePetControlled: false };
    fs.writeFileSync(path.join(out, 'report.json'), JSON.stringify(report, null, 2) + '\n');
    console.log(JSON.stringify(report));
  } finally {
    if (browser) await browser.close();
    await new Promise(resolve => server.close(resolve));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
