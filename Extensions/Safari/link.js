/* Only URLs on YouTube itself are passed to the app. */
function youtubeAppURL(value) {
  try {
    const url = new URL(value);
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.port) return null;
    const host = url.hostname.toLowerCase();
    if (!['youtube.com', 'www.youtube.com', 'm.youtube.com', 'youtu.be'].includes(host)) return null;
    if (host === 'youtu.be') {
      const id = url.pathname.slice(1);
      if (!/^[A-Za-z0-9_-]{11}$/.test(id)) return null;
      url.hostname = 'www.youtube.com';
      url.pathname = '/watch';
      url.searchParams.set('v', id);
    }
    // Keep timestamps, playlists, Shorts, channel and clip paths intact.
    return 'youtube://www.youtube.com' + url.pathname + url.search + url.hash;
  } catch {
    return null;
  }
}
if (typeof module !== 'undefined') module.exports = youtubeAppURL;
