/*
 * Bastion resource reporter (iOS). Safari content rules block requests silently, so this lists what the page tries to
 * load — scripts, images, frames, styles, fetch/XHR and beacons — for the privacy report. URLs only, never content.
 */
(function () {
  if (window.__bastionRep) return;
  try { Object.defineProperty(window, '__bastionRep', { value: true }); } catch (e) { return; }
  var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.bastion;
  if (!h) return;
  var seen = new Set(), q = [], t = 0;
  function flush() {
    t = 0;
    if (!q.length) return;
    var b = q.splice(0, 200);
    try { h.postMessage({ t: 'res', page: location.href, top: window === window.top, items: b }); } catch (e) {}
    if (q.length) t = setTimeout(flush, 400);
  }
  function add(u, ty) {
    if (!u || typeof u !== 'string') return;
    try { u = new URL(u, location.href).href; } catch (e) { return; }
    if (u.slice(0, 4) !== 'http' || seen.has(u) || seen.size > 3000) return;
    seen.add(u); q.push([u, ty]);
    if (!t) t = setTimeout(flush, 400);
  }
  function scan(el) {
    if (!el || el.nodeType !== 1) return;
    var tn = el.tagName;
    if (tn === 'SCRIPT' && el.src) add(el.src, 1);
    else if (tn === 'IMG' && el.src) add(el.src, 2);
    else if (tn === 'IFRAME' && el.src) add(el.src, 16);
    else if (tn === 'LINK' && /stylesheet/i.test(el.rel || '')) add(el.href, 4);
    else if ((tn === 'VIDEO' || tn === 'AUDIO' || tn === 'SOURCE') && el.src) add(el.src, 32);
  }
  new MutationObserver(function (rs) {
    for (var i = 0; i < rs.length; i++) {
      var added = rs[i].addedNodes;
      for (var j = 0; j < added.length; j++) {
        var n = added[j];
        scan(n);
        if (n.querySelectorAll) n.querySelectorAll('script[src],img[src],iframe[src],link[rel~=stylesheet],video[src],audio[src],source[src]').forEach(scan);
      }
    }
  }).observe(document, { childList: true, subtree: true });
  var of = window.fetch;
  if (of) window.fetch = function (i) { try { add(typeof i === 'string' ? i : (i && i.url) || String(i), 8); } catch (e) {} return of.apply(this, arguments); };
  var oo = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (m, u) { try { add(String(u), 8); } catch (e) {} return oo.apply(this, arguments); };
  if (navigator.sendBeacon) {
    var sb = navigator.sendBeacon.bind(navigator);
    navigator.sendBeacon = function (u, d) { try { add(String(u), 256); } catch (e) {} return sb(u, d); };
  }
  addEventListener('pagehide', flush);
})();
