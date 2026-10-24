/*
 * Bastion page shields — injected at document start into every frame.
 *  - Detects fingerprinting (canvas readback, WebGL renderer queries, audio rendering, font probing)
 *    and reports it to the app so it can be shown in the privacy breakdown and alerts.
 *  - When protection is on, adds invisible per-session noise so the fingerprint stops being stable.
 *  - Exposes navigator.globalPrivacyControl / doNotTrack.
 *  - Light cosmetic filtering for leftover ad containers.
 * __BASTION_CFG__ is replaced by the app with a JSON config object.
 */
(function () {
  'use strict';
  if (window.__bastionShields) return;
  try { Object.defineProperty(window, '__bastionShields', { value: true }); } catch (e) { return; }

  var CFG = __BASTION_CFG__;
  var host = location.hostname || '';
  for (var a = 0; a < CFG.allow.length; a++) {
    var d = CFG.allow[a];
    if (host === d || host.slice(-(d.length + 1)) === '.' + d) return;
  }

  var reported = {};
  function report(kind) {
    if (reported[kind]) return;
    reported[kind] = true;
    try { if (window.BastionBridge) window.BastionBridge.onFingerprint(kind, host); } catch (e) {}
  }

  // ---- Filter-list scriptlets and cosmetic filtering ---------------------------------------
  var bridge = window.BastionBridge;
  var setT = window.setTimeout.bind(window);
  var stringify = JSON.stringify;
  /*__SCRIPTLETS__*/
  var cos = null;
  try { if (bridge) cos = JSON.parse(bridge.cosmetics(location.href)); } catch (e) {}

  var styleText = '', styleEl = null;
  function ensureStyle() {
    var root = document.documentElement;
    if (!root || !styleText) return;
    if (!styleEl) styleEl = document.createElement('style');
    if (styleEl.textContent.length !== styleText.length) styleEl.textContent = styleText;
    if (!styleEl.isConnected) (document.head || root).appendChild(styleEl);
  }
  function addCss(css) { if (css) { styleText += css + '\n'; ensureStyle(); } }

  if (cos) {
    if (cos.sl && cos.sl.length) { try { bastionRunScriptlets(cos.sl); } catch (e) {} }
    addCss(cos.css);
  }

  if (cos && cos.g) {
    var seenKeys = new Set(), pend = [], tmr = 0;
    var addKey = function (k) { if (k.length < 120 && !seenKeys.has(k)) { seenKeys.add(k); pend.push(k); } };
    var scan = function (el) {
      if (el.nodeType !== 1) return;
      if (el.id) addKey('#' + el.id);
      var cl = el.classList;
      if (cl) for (var i = 0; i < cl.length; i++) addKey('.' + cl[i]);
    };
    var scanTree = function (root) {
      scan(root);
      if (!root.querySelectorAll) return;
      var list = root.querySelectorAll('[id],[class]');
      for (var i = 0; i < list.length && i < 8000; i++) scan(list[i]);
    };
    var flush = function () {
      tmr = 0;
      if (!pend.length) return;
      var batch = pend.splice(0, pend.length);
      try { addCss(bridge.generic(stringify(batch), location.href)); } catch (e) {}
    };
    var schedule = function () { if (!tmr) tmr = setT(flush, 60); };
    new MutationObserver(function (records) {
      ensureStyle();
      for (var r = 0; r < records.length; r++) {
        var added = records[r].addedNodes;
        for (var n = 0; n < added.length; n++) if (added[n].nodeType === 1) scanTree(added[n]);
      }
      if (pend.length) schedule();
    }).observe(document, { childList: true, subtree: true });
    document.addEventListener('DOMContentLoaded', function () { if (document.documentElement) scanTree(document.documentElement); flush(); }, { once: true });
  } else if (cos && cos.css) {
    new MutationObserver(ensureStyle).observe(document, { childList: true, subtree: false });
    document.addEventListener('DOMContentLoaded', ensureStyle, { once: true });
  }

  // ---- Global Privacy Control -------------------------------------------------------------
  if (CFG.gpc) {
    try { Object.defineProperty(Navigator.prototype, 'globalPrivacyControl', { get: function () { return true; }, configurable: true }); } catch (e) {}
    try { Object.defineProperty(Navigator.prototype, 'doNotTrack', { get: function () { return '1'; }, configurable: true }); } catch (e) {}
  }

  // ---- deterministic per-session noise ----------------------------------------------------
  var seed = (CFG.seed >>> 0) || 1;
  function rnd(i) {
    var x = (seed ^ Math.imul(i + 1, 2654435761)) >>> 0;
    x ^= x << 13; x >>>= 0;
    x ^= x >>> 17;
    x ^= x << 5; x >>>= 0;
    return x;
  }
  function noise(data, w, h) {
    var px = (w * h) | 0;
    if (!px || !data) return;
    var n = Math.min(12, px);
    for (var k = 0; k < n; k++) {
      var p = (rnd(k) % px) * 4 + (k % 3);
      data[p] = data[p] ^ 1;
    }
  }

  // ---- Canvas -----------------------------------------------------------------------------
  try {
    var CP = HTMLCanvasElement.prototype;
    var C2D = CanvasRenderingContext2D.prototype;
    var origToDataURL = CP.toDataURL, origToBlob = CP.toBlob, origGetImageData = C2D.getImageData;

    var noisyCopy = function (canvas) {
      var w = canvas.width, h = canvas.height;
      if (!w || !h || w * h > 2000000) return null;
      try {
        var c = document.createElement('canvas');
        c.width = w; c.height = h;
        var cx = c.getContext('2d');
        cx.drawImage(canvas, 0, 0);
        var img = origGetImageData.call(cx, 0, 0, w, h);
        noise(img.data, w, h);
        cx.putImageData(img, 0, 0);
        return c;
      } catch (e) { return null; }
    };

    CP.toDataURL = function () {
      report('Canvas');
      if (CFG.fp) { var c = noisyCopy(this); if (c) return origToDataURL.apply(c, arguments); }
      return origToDataURL.apply(this, arguments);
    };
    CP.toBlob = function () {
      report('Canvas');
      if (CFG.fp) { var c = noisyCopy(this); if (c) return origToBlob.apply(c, arguments); }
      return origToBlob.apply(this, arguments);
    };
    C2D.getImageData = function (sx, sy, sw, sh) {
      var img = origGetImageData.apply(this, arguments);
      if (Math.abs(sw * sh) > 16) report('Canvas');
      if (CFG.fp) { try { noise(img.data, img.width, img.height); } catch (e) {} }
      return img;
    };

    var origMeasure = C2D.measureText, measures = 0;
    C2D.measureText = function () {
      if (++measures === 300) report('Font probing');
      return origMeasure.apply(this, arguments);
    };
  } catch (e) {}

  // ---- WebGL ------------------------------------------------------------------------------
  function patchGL(Ctx) {
    if (!Ctx || !Ctx.prototype) return;
    var P = Ctx.prototype, origParam = P.getParameter, origExt = P.getExtension;
    P.getParameter = function (p) {
      if (p === 0x9245 || p === 0x9246) {
        report('WebGL');
        if (CFG.strict) return p === 0x9245 ? 'Google Inc.' : 'WebKit WebGL';
      }
      return origParam.apply(this, arguments);
    };
    P.getExtension = function (name) {
      if (name === 'WEBGL_debug_renderer_info') report('WebGL');
      return origExt.apply(this, arguments);
    };
  }
  try { patchGL(window.WebGLRenderingContext); patchGL(window.WebGL2RenderingContext); } catch (e) {}

  // ---- Audio ------------------------------------------------------------------------------
  try {
    if (window.OfflineAudioContext) {
      var origRender = OfflineAudioContext.prototype.startRendering;
      OfflineAudioContext.prototype.startRendering = function () {
        report('Audio');
        return origRender.apply(this, arguments);
      };
    }
    if (window.AudioBuffer && CFG.fp) {
      var origChannel = AudioBuffer.prototype.getChannelData;
      var touched = new WeakSet();
      AudioBuffer.prototype.getChannelData = function () {
        var data = origChannel.apply(this, arguments);
        try {
          if (!touched.has(data)) {
            touched.add(data);
            for (var k = 0; k < 8 && data.length; k++) {
              var i = rnd(k + 50) % data.length;
              data[i] = data[i] + 1e-7;
            }
          }
        } catch (e) {}
        return data;
      };
    }
  } catch (e) {}

  // ---- Hardware details (strict mode) -----------------------------------------------------
  if (CFG.strict) {
    try { Object.defineProperty(Navigator.prototype, 'hardwareConcurrency', { get: function () { return 4; }, configurable: true }); } catch (e) {}
    try { Object.defineProperty(Navigator.prototype, 'deviceMemory', { get: function () { return 4; }, configurable: true }); } catch (e) {}
  }

  // ---- Cosmetic filtering -----------------------------------------------------------------
  if (CFG.cosmetic) {
    var css = [
      'ins.adsbygoogle', '.adsbygoogle', '[id^="google_ads_iframe"]', '[id^="div-gpt-ad"]', '[data-google-query-id]',
      'amp-ad', 'amp-embed[type="taboola"]', '.taboola', '[id^="taboola-"]', '.trc_rbox_container',
      '.OUTBRAIN', '.ob-widget', '.ob-smartfeed-wrapper', '[data-ad-slot]', '.adsbox', '.ad-banner',
      '.ad-slot', '.advertisement', '.sponsored-ad', '#carbonads', '[aria-label="Advertisement"]'
    ].join(',') + '{display:none!important}';
    var addStyle = function () {
      try {
        var s = document.createElement('style');
        s.textContent = css;
        (document.head || document.documentElement).appendChild(s);
        return true;
      } catch (e) { return false; }
    };
    if (!document.documentElement || !addStyle()) {
      document.addEventListener('DOMContentLoaded', addStyle, { once: true });
    }
  }
})();
