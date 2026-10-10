// music.grepawk.com first-party, anonymous site telemetry (no cookies, no third parties).
// Sends web_* events to this site's own API (/api/telemetry/batch). The id is random per browser
// tab session (sessionStorage), so visits are not linked across days. The server does not store
// IP addresses. Honors Do Not Track / Global Privacy Control.
(function () {
  'use strict';
  try {
    if (navigator.doNotTrack === '1' || window.doNotTrack === '1' || navigator.globalPrivacyControl) return;
    if (!/^(music\.grepawk\.com|grepawk\.com)$/.test(location.hostname)) return;
    var api = location.hostname === 'grepawk.com' ? '/music-radar/api/telemetry/batch' : '/api/telemetry/batch';
    var uuid = function () {
      if (crypto.randomUUID) return crypto.randomUUID();
      var b = crypto.getRandomValues(new Uint8Array(16)); b[6] = (b[6] & 15) | 64; b[8] = (b[8] & 63) | 128;
      var h = Array.prototype.map.call(b, function (x) { return (x + 256).toString(16).slice(1); }).join('');
      return h.slice(0, 8) + '-' + h.slice(8, 12) + '-' + h.slice(12, 16) + '-' + h.slice(16, 20) + '-' + h.slice(20);
    };
    var id;
    try { id = sessionStorage.getItem('mr.site.sid') || uuid(); sessionStorage.setItem('mr.site.sid', id); } catch (e) { id = uuid(); }
    var page = location.pathname.replace(/\.html$/, '').replace(/^\/music-radar/, '') || '/';
    var refHost = '';
    try { refHost = document.referrer ? new URL(document.referrer).hostname : ''; } catch (e) {}
    var send = function (name, props) {
      var p = { platform: 'web', host: location.hostname, page: page };
      for (var k in props) p[k] = props[k];
      var body = JSON.stringify({ events: [{ name: name, ts: Date.now(), installId: id, sessionId: id, appVersion: 'web', properties: p }] });
      try { fetch(api, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: body, keepalive: true, credentials: 'omit' }).catch(function () {}); } catch (e) {}
    };
    send('web_page_view', { referrer_host: refHost.slice(0, 100) });
    document.addEventListener('click', function (ev) {
      var a = ev.target && ev.target.closest ? ev.target.closest('a[data-track]') : null;
      if (!a) return;
      var t = ''; try { t = new URL(a.href, location.href).hostname + new URL(a.href, location.href).pathname; } catch (e) {}
      send(a.getAttribute('data-track'), { target: t.slice(0, 120) });
    });
  } catch (e) {}
})();
