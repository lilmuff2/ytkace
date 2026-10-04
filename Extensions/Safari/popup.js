(async () => {
  const status = document.getElementById('status');
  try {
    const [tab] = await browser.tabs.query({active:true, currentWindow:true});
    const url = youtubeAppURL(tab?.url);
    if (!url) { status.textContent = 'Открой страницу YouTube в текущей вкладке.'; return; }
    const link = document.getElementById('open');
    link.href = url;
    link.hidden = false;
    status.textContent = 'Ссылка откроется в установленном YouTube.';
  } catch {
    status.textContent = 'Разреши расширению доступ к YouTube в настройках Safari.';
  }
})();
