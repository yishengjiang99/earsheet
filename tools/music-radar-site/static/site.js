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
    var qs = new URLSearchParams(location.search);
    var pv = { referrer_host: refHost.slice(0, 100) };
    ['utm_source', 'utm_medium', 'utm_campaign', 'utm_content'].forEach(function (k) { var v = qs.get(k); if (v) pv[k] = v.slice(0, 80); });
    send('web_page_view', pv);
    if (/\/thanks(\.html)?$/.test(location.pathname) && qs.get('session_id')) send('web_checkout_success', { plan: (qs.get('plan') || '').slice(0, 20) });
    if (qs.get('checkout') === 'cancel') send('web_checkout_cancel', {});
    if (qs.get('waitlist') === 'ok') send('web_waitlist_joined', {});
    document.addEventListener('submit', function (ev) {
      var f = ev.target;
      if (f && f.getAttribute && f.getAttribute('data-checkout')) send('web_checkout_click', { plan: f.getAttribute('data-checkout').slice(0, 20) });
      else if (f && f.hasAttribute && f.hasAttribute('data-waitlist')) send('web_waitlist_submit', {});
    }, true);
    document.addEventListener('click', function (ev) {
      var a = ev.target && ev.target.closest ? ev.target.closest('a[data-track]') : null;
      if (!a) return;
      var t = ''; try { t = new URL(a.href, location.href).hostname + new URL(a.href, location.href).pathname; } catch (e) {}
      send(a.getAttribute('data-track'), { target: t.slice(0, 120) });
    });
  } catch (e) {}
})();
