/*
 * Bastion YouTube shield — injected at document start into youtube.com / youtube-nocookie.com / youtubekids.com
 * frames, in the page's own JavaScript world (not limited by Manifest V3).
 *
 * Layered so that when YouTube changes one thing, the other layers still hold:
 *   1. Data surgery   – strip adPlacements / adSlots / playerAds and ad renderers from every player, watch,
 *                       browse, search, Shorts and get_watch response (fetch, XHR, JSON.parse, initial page data).
 *   2. Anti-adblock   – neuter the "abnormality detected" callback, fast-forward the 17 s penalty timer,
 *                       remove enforcement pop-ups and resume playback.
 *   3. Playback guard – if an ad still reaches the player (server-side inserted "SSAP" ads stitched into the
 *                       stream, or client ads), cover it, mute it, click Skip, and seek past it.
 *   4. Cosmetics      – hide feed, search, masthead, companion and overlay ad units (desktop and mobile).
 * Network-level blocking of ad/measurement endpoints lives in bastion-filters.txt.
 */
(function () {
  'use strict';
  if (window.__bastionYT) return;
  try { Object.defineProperty(window, '__bastionYT', { value: true }); } catch (e) { return; }

  var bridge = window.BastionBridge;
  var origParse = JSON.parse, origStringify = JSON.stringify;
  var origSetTimeout = window.setTimeout, origSetInterval = window.setInterval;
  function report(kind) { try { if (bridge && bridge.onAd) bridge.onAd(kind); } catch (e) {} }

  // ======================================================================== 1. data surgery
  var AD_KEYS = ['adPlacements', 'playerAds', 'adSlots', 'adBreakHeartbeatParams', 'adBreakParams'];
  var AD_RENDERERS = {};
  ['adSlotRenderer', 'promotedSparklesWebRenderer', 'promotedSparklesTextSearchRenderer', 'inFeedAdLayoutRenderer',
    'displayAdRenderer', 'promotedVideoRenderer', 'compactPromotedVideoRenderer', 'searchPyvRenderer',
    'bannerPromoRenderer', 'statementBannerRenderer', 'adActionInterstitialRenderer', 'actionCompanionAdRenderer',
    'companionAdRenderer', 'instreamVideoAdRenderer', 'linearAdSequenceRenderer', 'adPlacementRenderer',
    'merchandiseShelfRenderer', 'brandVideoShelfRenderer', 'brandVideoSingletonRenderer', 'primetimePromoRenderer',
    'mealbarPromoRenderer', 'playerLegacyDesktopWatchAdsRenderer'
  ].forEach(function (k) { AD_RENDERERS[k] = 1; });
  var NEEDLE = /"(?:adPlacements|adSlots|playerAds|adSlotRenderer|promotedSparklesWebRenderer|inFeedAdLayoutRenderer|isAd|displayAdRenderer|searchPyvRenderer|mealbarPromoRenderer)"/;

  function hasAdRenderer(o) {
    if (!o || typeof o !== 'object') return false;
    for (var k in o) if (AD_RENDERERS[k]) return true;
    return false;
  }

  function isAdItem(x) {
    if (!x || typeof x !== 'object' || Array.isArray(x)) return false;
    if (hasAdRenderer(x)) return true;
    var wrappers = ['richItemRenderer', 'richSectionRenderer', 'itemSectionRenderer', 'reelItemRenderer'];
    for (var i = 0; i < wrappers.length; i++) {
      var w = x[wrappers[i]];
      if (w && w.content && hasAdRenderer(w.content)) return true;
      if (w && Array.isArray(w.contents) && w.contents.length === 1 && hasAdRenderer(w.contents[0])) return true;
    }
    var rw = x.command && x.command.reelWatchEndpoint;
    if (rw && rw.adClientParams && rw.adClientParams.isAd) return true;
    var rw2 = x.reelWatchEndpoint;
    if (rw2 && rw2.adClientParams && rw2.adClientParams.isAd) return true;
    return false;
  }

  function prune(o, depth) {
    if (!o || typeof o !== 'object' || depth > 48) return 0;
    var removed = 0;
    if (Array.isArray(o)) {
      for (var i = o.length - 1; i >= 0; i--) {
        if (isAdItem(o[i])) { o.splice(i, 1); removed++; }
        else removed += prune(o[i], depth + 1);
      }
      return removed;
    }
    for (var j = 0; j < AD_KEYS.length; j++) {
      if (Object.prototype.hasOwnProperty.call(o, AD_KEYS[j])) { delete o[AD_KEYS[j]]; removed++; }
    }
    for (var k in o) {
      var v = o[k];
      if (v && typeof v === 'object') removed += prune(v, depth + 1);
    }
    return removed;
  }

  function cleanText(txt) {
    if (typeof txt !== 'string' || !NEEDLE.test(txt)) return txt;
    var prefix = '';
    var body = txt;
    if (body.indexOf(")]}'") === 0) { prefix = ")]}'\n"; body = body.slice(body.indexOf('\n') + 1); }
    try {
      var o = origParse(body);
      if (prune(o, 0)) { report('pruned'); return prefix + origStringify(o); }
      return txt;
    } catch (e) {
      var out = txt.replace(/"(adPlacements|adSlots|playerAds)"/g, '"no_ads"');
      if (out !== txt) report('pruned');
      return out;
    }
  }

  var API = /\/youtubei\/v1\/(player|next|browse|search|reel\/|get_watch|guide)|\/watch\?|\/playlist\?|\/get_watch|\/shorts\//;

  // fetch
  try {
    var origFetch = window.fetch;
    window.fetch = new Proxy(origFetch, {
      apply: function (t, self, args) {
        var req = args[0];
        var url = typeof req === 'string' ? req : (req && req.url) || String(req);
        var p = Reflect.apply(t, self, args);
        if (!API.test(url)) return p;
        return p.then(function (resp) {
          if (!resp || !resp.ok) return resp;
          return resp.clone().text().then(function (txt) {
            var out = cleanText(txt);
            if (out === txt) return resp;
            var headers = new Headers(resp.headers);
            headers.delete('content-length');
            headers.delete('content-encoding');
            var r2 = new Response(out, { status: resp.status, statusText: resp.statusText, headers: headers });
            try { Object.defineProperty(r2, 'url', { value: resp.url }); } catch (e) {}
            return r2;
          }).catch(function () { return resp; });
        });
      }
    });
  } catch (e) {}

  // XHR
  try {
    var X = XMLHttpRequest.prototype, origOpen = X.open;
    X.open = function (m, u) { this.__bYt = API.test(String(u)); return origOpen.apply(this, arguments); };
    ['responseText', 'response'].forEach(function (name) {
      var d = Object.getOwnPropertyDescriptor(X, name);
      if (!d || !d.get) return;
      Object.defineProperty(X, name, {
        configurable: true, enumerable: d.enumerable,
        get: function () {
          var v = d.get.call(this);
          if (!this.__bYt || this.readyState !== 4) return v;
          if (this.__bCache && this.__bCache.src === v) return this.__bCache.out;
          var out = v;
          try {
            if (typeof v === 'string') out = cleanText(v);
            else if (v && typeof v === 'object' && !(v instanceof ArrayBuffer) && !(v instanceof Blob)) { if (prune(v, 0)) report('pruned'); }
          } catch (e) {}
          this.__bCache = { src: v, out: out };
          return out;
        }
      });
    });
  } catch (e) {}

  // JSON.parse (catches embedded player responses and anything parsed by hand)
  JSON.parse = new Proxy(origParse, {
    apply: function (t, self, args) {
      var r = Reflect.apply(t, self, args);
      try {
        if (typeof args[0] === 'string' && args[0].length > 300 && NEEDLE.test(args[0]) && prune(r, 0)) report('pruned');
      } catch (e) {}
      return r;
    }
  });

  // Initial page data assigned by inline scripts (var ytInitialPlayerResponse = {...})
  ['ytInitialPlayerResponse', 'ytInitialData', 'playerResponse'].forEach(function (name) {
    var val = window[name];
    try {
      Object.defineProperty(window, name, {
        configurable: true,
        get: function () { return val; },
        set: function (v) { try { if (prune(v, 0)) report('pruned'); } catch (e) {} val = v; }
      });
    } catch (e) {}
  });

  // ======================================================================== 2. anti-adblock
  // Neutralise the detection callback YouTube hands to promises (same idea as current uBlock filters).
  try {
    Promise.prototype.then = new Proxy(Promise.prototype.then, {
      apply: function (t, self, args) {
        var f = args[0];
        if (typeof f === 'function') {
          try { if (Function.prototype.toString.call(f).indexOf('onAbnormalityDetected') !== -1) args[0] = function () {}; } catch (e) {}
        }
        return Reflect.apply(t, self, args);
      }
    });
  } catch (e) {}

  // Fast-forward the ~17 s "ad blocker penalty" timer.
  try {
    window.setTimeout = new Proxy(origSetTimeout, {
      apply: function (t, self, args) {
        var d = args[1] | 0;
        if (d >= 16000 && d <= 18000) {
          try { if (String(args[0]).indexOf('[native code]') !== -1) args[1] = 1; } catch (e) {}
        }
        return Reflect.apply(t, self, args);
      }
    });
  } catch (e) {}

  var WALL_SEL = 'ytd-enforcement-message-view-model, ytm-enforcement-message-view-model, #enforcement-message';
  function removeWalls() {
    var walls = document.querySelectorAll(WALL_SEL);
    if (!walls.length) return;
    for (var i = 0; i < walls.length; i++) {
      var el = walls[i];
      var box = el.closest('tp-yt-paper-dialog, ytd-popup-container, bottom-sheet-container, ytm-bottom-sheet-renderer, .dialog-container') || el;
      box.remove();
    }
    var backs = document.querySelectorAll('tp-yt-iron-overlay-backdrop, .ytm-bottom-sheet-overlay-renderer-overlay');
    for (var j = 0; j < backs.length; j++) backs[j].remove();
    var v = document.querySelector('video');
    if (v && v.paused) { try { v.play().catch(function () {}); } catch (e) {} }
    report('wall');
  }

  // ======================================================================== 3. playback guard
  var inAd = false, saved = null, curtain = null;

  function getPlayer() {
    return document.getElementById('movie_player') || document.querySelector('.html5-video-player');
  }

  function isSSAP(p) {
    try {
      var st = p.getStatsForNerds && p.getStatsForNerds();
      return !!(st && st.debug_info && String(st.debug_info).indexOf('SSAP, AD') === 0);
    } catch (e) { return false; }
  }

  function adActive(p) {
    if (!p) return false;
    var c = p.classList;
    return c.contains('ad-showing') || c.contains('ad-interrupting') || isSSAP(p);
  }

  function showCurtain(p) {
    if (!p) return;
    if (!curtain) {
      curtain = document.createElement('div');
      curtain.setAttribute('style', 'position:absolute;inset:0;z-index:2147483646;background:#0E1116;color:#4FD1C5;' +
        'display:flex;align-items:center;justify-content:center;font:600 15px system-ui,sans-serif;pointer-events:none');
      curtain.textContent = 'Ad skipped by Bastion';
    }
    if (curtain.parentNode !== p) p.appendChild(curtain);
    curtain.style.display = 'flex';
  }
  function hideCurtain() { if (curtain) curtain.style.display = 'none'; }

  var SKIP_SEL = '.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-ad-skip-button-slot button, ' +
    '.ytm-skip-ad-button, button.ytp-ad-skip-button-container, [class*="skip-ad-button"], [id^="skip-button"] button';

  function tick() {
    var p = getPlayer();
    var v = (p && p.querySelector('video')) || document.querySelector('video');
    if (adActive(p) && v) {
      if (!inAd) {
        inAd = true;
        saved = { muted: v.muted, rate: v.playbackRate || 1 };
        report('skipped');
      }
      showCurtain(p);
      try { v.muted = true; } catch (e) {}
      var skip = document.querySelector(SKIP_SEL);
      if (skip) { try { skip.click(); } catch (e) {} }
      if (isSSAP(p)) {
        // Server-side inserted ad: it lives inside the content stream, so seek the *ad* to its end.
        try {
          var ps = p.getProgressState && p.getProgressState();
          if (ps && ps.duration > 0 && ps.duration < 240 && p.seekTo) p.seekTo(ps.duration);
        } catch (e) {}
      } else {
        // Classic client-side ad: its own media element – jump to the last frame.
        try { if (isFinite(v.duration) && v.duration > 0 && v.currentTime < v.duration - 0.1) v.currentTime = v.duration - 0.05; } catch (e) {}
      }
      try { v.playbackRate = 16; } catch (e) {}
    } else if (inAd) {
      inAd = false;
      hideCurtain();
      if (v && saved) { try { v.muted = saved.muted; v.playbackRate = saved.rate; } catch (e) {} }
      saved = null;
    }
    removeWalls();
  }
  origSetInterval.call(window, tick, 200);

  // ======================================================================== 4. cosmetics
  var CSS = [
    'ytd-ad-slot-renderer', 'ytd-in-feed-ad-layout-renderer', 'ytd-promoted-sparkles-web-renderer',
    'ytd-promoted-video-renderer', 'ytd-display-ad-renderer', 'ytd-compact-promoted-video-renderer',
    'ytd-banner-promo-renderer', 'ytd-statement-banner-renderer', 'ytd-search-pyv-renderer',
    'ytd-merch-shelf-renderer', 'ytd-player-legacy-desktop-watch-ads-renderer', 'ytd-brand-video-singleton-renderer',
    'ytd-brand-video-shelf-renderer', 'ytd-primetime-promo-renderer', 'ytd-mealbar-promo-renderer',
    'ytd-rich-item-renderer:has(> #content > ytd-ad-slot-renderer)', 'ytd-rich-section-renderer:has(ytd-statement-banner-renderer)',
    'ytd-engagement-panel-section-list-renderer[target-id="engagement-panel-ads"]',
    '#masthead-ad', '#player-ads', '#panels > ytd-ads-engagement-panel-content-renderer',
    '.ytp-ad-overlay-container', '.ytp-ad-overlay-slot', '.ytp-ad-message-container', '.ytp-ad-image-overlay',
    '.ytp-suggested-action', '.ytp-featured-product',
    'ad-slot-renderer', 'ytm-ad-slot-renderer', 'ytm-promoted-sparkles-web-renderer', 'ytm-promoted-sparkles-text-search-renderer',
    'ytm-promoted-video-renderer', 'ytm-companion-ad-renderer', 'ytm-companion-slot', 'ytm-statement-banner-renderer',
    'ytm-rich-item-renderer:has(ad-slot-renderer)', 'ytm-rich-item-renderer:has(ytm-ad-slot-renderer)',
    'ytm-item-section-renderer:has(> lazy-list > ad-slot-renderer)', 'ytm-item-section-renderer:has(ytm-ad-slot-renderer)',
    'ytm-mealbar-promo-renderer', 'ytm-brand-video-singleton-renderer', 'ytm-paid-content-overlay-renderer',
    'ytm-reel-shelf-renderer:has(.ad-badge)',
    'ytd-enforcement-message-view-model', 'ytm-enforcement-message-view-model',
    'tp-yt-paper-dialog:has(ytd-enforcement-message-view-model)'
  ].join(',') + '{display:none!important}';
  function addStyle() {
    try {
      var s = document.createElement('style');
      s.textContent = CSS;
      (document.head || document.documentElement).appendChild(s);
      return true;
    } catch (e) { return false; }
  }
  if (!document.documentElement || !addStyle()) document.addEventListener('DOMContentLoaded', addStyle, { once: true });
})();
