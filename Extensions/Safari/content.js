(() => {
  // The link lives in the page, so opening it retains Safari's real user gesture.
  const host = document.createElement('div');
  const root = host.attachShadow({mode: 'closed'});
  const style = document.createElement('style');
  style.textContent = `:host { position:fixed; right:12px; bottom:calc(12px + env(safe-area-inset-bottom)); z-index:2147483647; }
    a { display:flex; align-items:center; justify-content:center; min-height:44px; padding:0 16px;
      border:1px solid #fff; border-radius:24px; background:#a50000; color:#fff;
      font:600 16px/1.4 system-ui; text-decoration:none; box-shadow:0 2px 8px #0005; }
    a:active { background:#780000; } a:focus-visible { outline:3px solid #007aff; outline-offset:3px; }`;
  const link = document.createElement('a');
  link.textContent = 'Открыть в YouTube';
  root.append(style, link);
  let previous = '';
  function update() {
    if (previous === location.href) return;
    previous = location.href;
    const url = youtubeAppURL(previous);
    if (!url) { host.remove(); return; }
    link.href = url;
    if (!host.isConnected) document.documentElement.append(host);
  }
  update();
  // YouTube changes its route without reloading the page.
  addEventListener('popstate', update);
  document.addEventListener('yt-navigate-finish', update);
  setInterval(update, 1000);
})();
