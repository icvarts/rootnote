const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const crypto = require('node:crypto');
const out = process.env.QA_OUTPUT || path.resolve(__dirname, '../qa-output/sidebar');
const guard = path.resolve(__dirname, '../Resources/guard');
(async () => {
  fs.mkdirSync(out, {recursive:true});
  const css = fs.readFileSync(path.join(guard, 'sidebar-quota.css'), 'utf8');
  const approved = path.resolve(__dirname, 'fixtures/sidebar-quota-approved.css');
  assert.equal(css, fs.readFileSync(approved, 'utf8'), 'approved narrow component must not drift');
  const browser = await chromium.launch({headless:true, ...(process.env.PLAYWRIGHT_CHANNEL ? {channel:process.env.PLAYWRIGHT_CHANNEL} : {}), chromiumSandbox:true});
  const checks = [], errors = [];
  try {
    const page = await browser.newPage({viewport:{width:44,height:124},deviceScaleFactor:2});
    page.on('pageerror', e=>errors.push(e.message));
    await page.route('**/*', route => {
      const url=route.request().url();
      return url.startsWith('file:') ? route.continue() : route.abort();
    });
    await page.addInitScript(() => {
      window.actions=[];
      window.webkit={messageHandlers:{sidebarQuota:{postMessage:m=>window.actions.push(m)}}};
    });
    await page.goto(pathToFileURL(path.join(guard,'sidebar-quota.html')).href);
    for (const appearance of ['light','dark']) {
      for (const remaining of [69,8,0,null,0.5,100,-1,101,'69',true]) {
        await page.evaluate(d=>window.SidebarQuota.update(d),{remaining,appearance});
        const state=await page.locator('#quota').evaluate(e=>{
          const r=e.getBoundingClientRect();
          const p=e.querySelector('.quota-percent'),range=document.createRange();range.selectNodeContents(p);
          const style=getComputedStyle(e);
          return {x:r.x,y:r.y,width:r.width,height:r.height,text:p.textContent,label:e.querySelector('.quota-label').textContent,low:e.classList.contains('low'),stale:e.classList.contains('stale'),scroll:document.documentElement.scrollWidth,textWidth:range.getBoundingClientRect().width,border:style.borderTopWidth,background:style.backgroundColor};
        });
        const valid=typeof remaining==='number' && remaining>=0 && remaining<=100;
        assert.deepEqual([state.x,state.y,state.width,state.height],[4,4,36,116]);
        assert.equal(state.scroll,44);
        assert.equal(state.border,'0px');
        assert.equal(state.background,appearance==='dark'?'rgba(22, 25, 24, 0.95)':'rgba(240, 242, 241, 0.95)');
        assert.ok(state.textWidth<=28, 'percentage must fit inside native hit window');
        assert.equal(state.text,!valid?'—':remaining>0&&remaining<1?'<1%':Math.floor(remaining)+'%');
        assert.equal(state.label,valid?'周额度':'待同步');
        assert.equal(state.stale,!valid);
        assert.equal(state.low,valid&&remaining<=10);
        checks.push(appearance+':'+String(remaining));
      }
      await page.evaluate(d=>window.SidebarQuota.update(d),{remaining:69,appearance});
      await page.mouse.move(0,0);
      await page.screenshot({path:path.join(out,appearance+'.png'),omitBackground:true});
    }
    await page.locator('#quota').click();
    await page.locator('#quota').click();
    await page.locator('#quota').focus();
    await page.keyboard.press('Enter');
    await page.keyboard.press('Space');
    assert.deepEqual(await page.evaluate(()=>window.actions),
      Array.from({length:4},()=>({action:'openQuota'})), 'all entry actions route to the shared native panel without pet actions');
    assert.match(await page.locator('#quota').getAttribute('aria-label'), /打开或关闭/);
    checks.push('click_and_keyboard_route_to_shared_panel');
    assert.equal(await page.locator('#quota').isVisible(),true);

    await page.evaluate(()=>window.SidebarQuota.update({remaining:69,appearance:'light',reduceTransparency:true}));
    assert.equal(await page.locator('#quota').evaluate(e=>getComputedStyle(e).backgroundColor),'rgb(240, 242, 241)');
    checks.push('reduce_transparency_opaque_surface');
    const input=await browser.newPage({viewport:{width:44,height:124}});
    await input.addInitScript(()=>{window.__rootnoteInputOnly=true;window.actions=[];window.webkit={messageHandlers:{sidebarQuota:{postMessage:m=>window.actions.push(m)}}};});
    await input.goto(pathToFileURL(path.join(guard,'sidebar-quota.html')).href);
    for(const reduceTransparency of [true,false]) {
      await input.evaluate(d=>window.SidebarQuota.update(d),{remaining:69,appearance:'dark',reduceTransparency});
      assert.deepEqual(await input.locator('#quota').evaluate(e=>({surface:getComputedStyle(e).backgroundColor,shadow:getComputedStyle(e).boxShadow,visibleChildren:[...e.children].some(c=>getComputedStyle(c).visibility!=='hidden')})),{surface:'rgba(0, 0, 0, 0)',shadow:'none',visibleChildren:false});
    }
    await input.keyboard.press('Tab');
    await input.waitForTimeout(30);
    assert.ok((await input.evaluate(()=>window.actions)).some(m=>m.action==='focus'&&m.focused));
    await input.keyboard.press('Enter');
    assert.equal((await input.evaluate(()=>window.actions)).filter(m=>m.action==='openQuota').length,1);
    await page.evaluate(()=>window.SidebarQuota.focus(true));
    assert.equal(await page.locator('#quota').evaluate(e=>getComputedStyle(e).outlineWidth),'2px');
    checks.push('input_layer_invisible_and_keyboard_accessible','visual_focus_indicator');

    // Exercise the real existing quota page, not a replacement detail UI.
    const details=await browser.newPage({viewport:{width:544,height:650}});
    await details.goto(pathToFileURL(path.join(guard,'panel.html')).href);
    await details.evaluate(()=>window.RootnotePanel.showTab('performance'));
    for(let i=0;i<3;i++)await details.evaluate(()=>window.RootnotePanel.showTab('quota'));
    assert.equal(await details.evaluate(()=>window.RootnotePanel.currentTab()),'quota');
    assert.equal(await details.locator('#view-quota').isVisible(),true);
    assert.equal(await details.locator('#view-performance').isVisible(),false);
    checks.push('existing_detail_quota_tab_idempotent');
    assert.deepEqual(errors,[]);
    fs.writeFileSync(path.join(out,'browser-results.json'),JSON.stringify({ok:true,checks,
      liveCodexInspected:false,realQuotaRead:false,installed:false,petActions:0},null,2));
    console.log(JSON.stringify({ok:true,checks:checks.length,errors}));
  } finally { await browser.close(); }
})().catch(e=>{console.error(e);process.exitCode=1;});
