(() => {
  'use strict';
  const button = document.getElementById('quota');
  const percent = button.querySelector('.quota-percent');
  const label = button.querySelector('.quota-label');
  if (window.__rootnoteInputOnly === true) document.documentElement.classList.add('input-only');
  function update(data = {}) {
    const n = data.remaining;
    const valid = typeof n === 'number' && Number.isFinite(n) && n >= 0 && n <= 100;
    document.documentElement.classList.toggle('reduce-transparency', data.reduceTransparency === true);
    button.className = 'quota-button ' + (data.appearance === 'dark' ? 'dark' : 'light') +
      (!valid ? ' stale' : n <= 10 ? ' low' : '') + (valid && n === 100 ? ' hundred' : '');
    button.style.setProperty('--progress', valid ? n : 0);
    percent.textContent = !valid ? '—' : n > 0 && n < 1 ? '<1%' : Math.floor(n) + '%';
    label.textContent = valid ? '周额度' : '待同步';
    const title = valid ? '周额度：剩余 ' + Number(n.toFixed(1)) + '%，点击打开或关闭额度页' : '周额度待同步，点击打开或关闭额度页';
    button.title = title;
    button.setAttribute('aria-label', title);
  }
  button.addEventListener('click', () => {
    window.webkit?.messageHandlers?.sidebarQuota?.postMessage({action: 'openQuota'});
  });
  function focus(visible) { document.documentElement.classList.toggle('keyboard-focus', visible === true); }
  function sendFocus() {
    if (window.__rootnoteInputOnly === true) window.webkit?.messageHandlers?.sidebarQuota?.postMessage({
      action: 'focus', focused: button.matches(':focus-visible')
    });
  }
  button.addEventListener('focus', sendFocus);
  button.addEventListener('blur', sendFocus);
  button.addEventListener('keydown', () => requestAnimationFrame(sendFocus));
  button.addEventListener('pointerdown', () => requestAnimationFrame(sendFocus));
  window.SidebarQuota = {update, focus};
})();
