/*
 * iOS bridge for Bastion's page scripts (shields.js, scriptlets.js, youtube.js): the same BastionBridge interface the
 * Android build exposes, over WebKit's message handler. Site-specific cosmetics for the page you're opening are
 * injected just before it loads (window.__bastionCos); generic hiding rules come back asynchronously.
 */
(function () {
  if (window.BastionBridge) return;
  var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bastion;
  function post(o) { try { return h ? h.postMessage(o) : null; } catch (e) { return null; } }
  var PRE = window.__bastionCos || {};
  function hostOf(u) { try { return new URL(u).hostname; } catch (e) { return ''; } }
  var bridge = {
    onFingerprint: function (k, host) { post({ t: 'fp', k: String(k), h: String(host || '') }); },
    onAd: function (k) { post({ t: 'ad', k: String(k) }); },
    cosmetics: function (href) { var c = PRE[hostOf(href)]; return c ? c : '{"g":true}'; },
    generic: function (keys, href) {
      var p = post({ t: 'gen', keys: keys, href: href });
      return p && p.then ? p.then(function (r) { return r || ''; }) : '';
    }
  };
  try { Object.defineProperty(window, 'BastionBridge', { value: bridge }); } catch (e) { window.BastionBridge = bridge; }
})();
