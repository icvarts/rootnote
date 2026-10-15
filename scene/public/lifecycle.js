(function () {
  let suspended = true;
  let engine = null;
  const style = document.createElement("style");
  style.textContent = "html[data-rootnote-suspended=true] *, html[data-rootnote-suspended=true] *::before, html[data-rootnote-suspended=true] *::after { animation-play-state: paused !important; }";
  document.head.append(style);
  document.documentElement.dataset.rootnoteSuspended = "true";

  window.RootnoteSceneLifecycle = Object.freeze({
    attach(value) {
      if (engine) throw new Error("Scene lifecycle already attached");
      engine = value;
      engine.stop();
      engine.reset();
      if (!suspended) {
        engine.discardDelta();
        engine.start();
      }
    },
    setSuspended(value) {
      const next = value !== false;
      if (next === suspended) return;
      suspended = next;
      document.documentElement.dataset.rootnoteSuspended = String(next);
      if (!engine) return;
      if (next) {
        engine.stop();
        engine.reset();
      } else {
        engine.discardDelta();
        engine.start();
      }
    },
    snapshot: () => ({ suspended, attached: engine !== null }),
  });
})();
