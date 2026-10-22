// AI Music Radar ads + attribution (music.grepawk.com). Config: ads-config.js (window.MR_ADS).
// 1. Attribution (always, first-party): utm_* / twclid / rdt_cid from the landing URL are kept in
//    localStorage for 30 days and copied into the checkout and waitlist forms as hidden fields, so
//    they reach Stripe Checkout metadata (and the server-side Conversions API).
// 2. Pixels (only when MR_ADS.enabled and an id is set, and the browser does not send Global Privacy
//    Control or Do Not Track): X Pixel and Reddit Pixel page visit; Lead after a waitlist sign-up;
//    StartTrial / Purchase on /thanks with the same event_id the server sends, for deduplication.
(function () {
  'use strict';
  var C = window.MR_ADS || {};
  var optOut = navigator.globalPrivacyControl === true || navigator.doNotTrack === '1' || window.doNotTrack === '1';
  var KEYS = ['utm_source', 'utm_medium', 'utm_campaign', 'utm_content', 'utm_term', 'twclid', 'rdt_cid'];
  var LS = 'mr.attr', TTL = 30 * 864e5;
  var store = function (k, v) { try { if (v === undefined) return JSON.parse(localStorage.getItem(k) || 'null'); localStorage.setItem(k, JSON.stringify(v)); } catch (e) { return null; } };
  var rid = function () { try { return crypto.randomUUID(); } catch (e) { return String(Date.now()) + '-' + Math.random().toString(36).slice(2, 12); } };

  // --- attribution ---
  var q = new URLSearchParams(location.search), attr = store(LS);
  if (!attr || Date.now() - (attr.t || 0) > TTL) attr = null;
  var fresh = {}; var hit = false;
  KEYS.forEach(function (k) { var v = q.get(k); if (v) { fresh[k] = v.slice(0, 200); hit = true; } });
  if (hit) { attr = { t: Date.now(), v: fresh, landing: (location.origin + location.pathname + location.search).slice(0, 300) }; store(LS, attr); }
  var addHidden = function (form, name, value) {
    if (!value) return; var i = form.querySelector('input[name="' + name + '"]');
    if (!i) { i = document.createElement('input'); i.type = 'hidden'; i.name = name; form.appendChild(i); } i.value = value;
  };
  var fillForm = function (form) {
    if (attr && attr.v) for (var k in attr.v) if (!(optOut && (k === 'twclid' || k === 'rdt_cid'))) addHidden(form, k, attr.v[k]);
    if (attr && attr.landing && !optOut) addHidden(form, 'landing', attr.landing);
    if (optOut) addHidden(form, 'ads_opt_out', '1');
  };

  // --- pixels ---
  var on = !!C.enabled && !optOut;
  var x = on && C.xPixelId, r = on && C.redditPixelId;
  if (x) {
    !function (e, t, n, s, u, a) { e.twq || (s = e.twq = function () { s.exe ? s.exe.apply(s, arguments) : s.queue.push(arguments); }, s.version = '1.1', s.queue = [], u = t.createElement(n), u.async = !0, u.src = 'https://static.ads-twitter.com/uwt.js', a = t.getElementsByTagName(n)[0], a.parentNode.insertBefore(u, a)); }(window, document, 'script');
    window.twq('config', C.xPixelId);
  }
  if (r) {
    !function (w, d) { if (!w.rdt) { var p = w.rdt = function () { p.sendEvent ? p.sendEvent.apply(p, arguments) : p.callQueue.push(arguments); }; p.callQueue = []; var t = d.createElement('script'); t.src = 'https://www.redditstatic.com/ads/pixel.js'; t.async = !0; var s = d.getElementsByTagName('script')[0]; s.parentNode.insertBefore(t, s); } }(window, document);
    window.rdt('init', C.redditPixelId);
    window.rdt('track', 'PageVisit');
  }
  var fire = function (kind, eventId, value) {
    var xe = kind === 'purchase' ? C.xPurchaseEventId : kind === 'start_trial' ? C.xStartTrialEventId : C.xLeadEventId;
    var p = { conversion_id: eventId }; if (value) { p.value = value; p.currency = 'USD'; }
    if (x && xe) window.twq('event', xe, p);
    if (r) {
      var rp = { conversionId: eventId }; if (value) { rp.value = value; rp.currency = 'USD'; }
      if (kind === 'purchase') window.rdt('track', 'Purchase', rp);
      else if (kind === 'lead') window.rdt('track', 'Lead', rp);
      else { rp.customEventName = 'StartTrial'; window.rdt('track', 'Custom', rp); }
    }
  };
  window.MR_ADS_FIRE = fire;

  var PRICES = { pro_monthly: 4.99, pro_yearly: 29.99, lifetime: 49.99 };
  document.addEventListener('DOMContentLoaded', function () {
    document.querySelectorAll('form[data-checkout]').forEach(function (f) {
      f.addEventListener('submit', function () {
        var id = 'mr-' + rid(); fillForm(f); addHidden(f, 'event_id', id);
        store('mr.pending', { id: id, plan: f.getAttribute('data-checkout'), t: Date.now() });
      });
    });
    document.querySelectorAll('form[data-waitlist]').forEach(function (f) {
      f.addEventListener('submit', function () { fillForm(f); store('mr.pending_lead', { id: 'mr-lead-' + rid(), t: Date.now() }); });
    });
    var s = q.get('waitlist');
    if (s === 'ok') {
      var ok = document.getElementById('waitlist-ok'); if (ok) ok.style.display = 'block';
      var pl = store('mr.pending_lead'); if (pl) { fire('lead', pl.id); store('mr.pending_lead', null); }
    } else if (s === 'invalid' || s === 'error') {
      var el = document.getElementById('waitlist-ok'); if (el) { el.textContent = s === 'invalid' ? 'That email address doesn\u2019t look right. Please try again.' : 'Something went wrong. Please try again.'; el.style.display = 'block'; }
    }
    // Thanks page: fire once with the id the server also sends (Stripe metadata.event_id).
    if (/\/thanks(\.html)?$/.test(location.pathname)) {
      var pend = store('mr.pending'), plan = q.get('plan') || (pend && pend.plan);
      if (pend && pend.id && q.get('session_id')) {
        if (plan === 'lifetime') fire('purchase', pend.id, PRICES.lifetime); else fire('start_trial', pend.id, 0);
        store('mr.pending', null);
      }
    }
  });
})();
