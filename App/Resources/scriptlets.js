/*
 * Bastion scriptlets — a compatible subset of uBlock Origin's scriptlets, so `site##+js(...)` rules from the
 * uBlock lists can neutralise anti-adblock walls and inline ad loaders. Runs in the page's own JS world at
 * document start, before any page script. Spliced into shields.js; exposes nothing on window.
 */
var bastionRunScriptlets = (function () {
  'use strict';

  var NOPE = {};
  var MAGIC = 'BastionBlocked';

  function splitArgs(s) {
    var out = [], cur = '', q = null;
    for (var i = 0; i < s.length; i++) {
      var c = s[i];
      if (c === '\\' && s[i + 1] === ',') { cur += ','; i++; continue; }
      if (q) { if (c === q) { q = null; continue; } cur += c; continue; }
      if ((c === "'" || c === '"') && cur.trim() === '') { q = c; cur = ''; continue; }
      if (c === ',') { out.push(cur.trim()); cur = ''; continue; }
      cur += c;
    }
    out.push(cur.trim());
    return out;
  }

  function toRe(pattern) {
    if (pattern === undefined || pattern === '' || pattern === '*') return /^/;
    var m = /^\/(.+)\/([gimsu]*)$/.exec(pattern);
    if (m) { try { return new RegExp(m[1], m[2]); } catch (e) { return /(?!)/; } }
    return new RegExp(pattern.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
  }

  function matcher(needle) {
    needle = needle || '';
    var neg = needle.charAt(0) === '!';
    var re = toRe(neg ? needle.slice(1) : needle);
    return function (s) { return re.test(String(s)) !== neg; };
  }

  var noopFunc = function () {};
  function constValue(raw) {
    switch (raw) {
      case 'undefined': return undefined;
      case 'false': return false;
      case 'true': return true;
      case 'null': return null;
      case "''": case '': return '';
      case 'noopFunc': return noopFunc;
      case 'trueFunc': return function () { return true; };
      case 'falseFunc': return function () { return false; };
      case 'emptyArr': case '[]': return [];
      case 'emptyObj': case '{}': return {};
      case 'noopPromiseResolve': return function () { return Promise.resolve(); };
      case 'yes': return 'yes';
      case 'no': return 'no';
      case '-1': return -1;
    }
    if (/^\d+$/.test(raw) && +raw <= 32767) return +raw;
    return NOPE;
  }

  /* Walk a property chain ("a.b.c"), waiting for intermediate objects to be assigned, then call
     finalize(owner, prop) on the last link. */
  function trapChain(owner, chain, finalize) {
    var pos = chain.indexOf('.');
    if (pos === -1) { finalize(owner, chain); return; }
    var prop = chain.slice(0, pos), rest = chain.slice(pos + 1);
    var v = owner[prop];
    if (v instanceof Object || (typeof v === 'object' && v !== null)) { trapChain(v, rest, finalize); return; }
    var d = Object.getOwnPropertyDescriptor(owner, prop);
    if (d && d.configurable === false) return;
    var cur = v;
    try {
      Object.defineProperty(owner, prop, {
        configurable: true, enumerable: true,
        get: function () { return cur; },
        set: function (a) { cur = a; if (a instanceof Object) trapChain(a, rest, finalize); }
      });
    } catch (e) {}
  }

  function swallow() {
    window.addEventListener('error', function (e) {
      if (String(e.message).indexOf(MAGIC) !== -1) e.preventDefault();
    });
  }

  var S = {};

  S['set-constant'] = function (chain, raw) {
    var value = constValue(raw);
    if (value === NOPE || !chain) return;
    trapChain(window, chain, function (owner, prop) {
      var d = Object.getOwnPropertyDescriptor(owner, prop);
      if (d && d.configurable === false) return;
      try { Object.defineProperty(owner, prop, { configurable: true, get: function () { return value; }, set: function () {} }); } catch (e) {}
    });
  };

  S['abort-on-property-read'] = function (chain) {
    if (!chain) return; swallow();
    trapChain(window, chain, function (owner, prop) {
      try { Object.defineProperty(owner, prop, { configurable: true, get: function () { throw new ReferenceError(MAGIC); }, set: function () {} }); } catch (e) {}
    });
  };

  S['abort-on-property-write'] = function (chain) {
    if (!chain) return; swallow();
    trapChain(window, chain, function (owner, prop) {
      try { Object.defineProperty(owner, prop, { configurable: true, set: function () { throw new ReferenceError(MAGIC); } }); } catch (e) {}
    });
  };

  S['abort-current-script'] = function (chain, needle) {
    if (!chain) return; swallow();
    var test = matcher(needle);
    var check = function () {
      var s = document.currentScript;
      if (!(s instanceof HTMLScriptElement)) return;
      var text = s.src || s.textContent;
      if (!needle || test(text)) throw new ReferenceError(MAGIC);
    };
    trapChain(window, chain, function (owner, prop) {
      var d = Object.getOwnPropertyDescriptor(owner, prop);
      if (d && d.configurable === false) return;
      var val = d ? d.value : undefined, og = d && d.get, os = d && d.set;
      try {
        Object.defineProperty(owner, prop, {
          configurable: true,
          get: function () { check(); return og ? og.call(this) : val; },
          set: function (v) { check(); if (os) os.call(this, v); else val = v; }
        });
      } catch (e) {}
    });
  };

  // ---- JSON pruning --------------------------------------------------------------------------
  function prunePath(obj, segs, i) {
    if (obj === null || typeof obj !== 'object') return false;
    var seg = segs[i], last = i === segs.length - 1, hit = false, k;
    if (seg === '[]' || seg === '*') {
      for (k in obj) { if (Object.prototype.hasOwnProperty.call(obj, k)) { if (last) { delete obj[k]; hit = true; } else if (prunePath(obj[k], segs, i + 1)) hit = true; } }
      return hit;
    }
    if (seg === '[-]' && Array.isArray(obj)) {
      for (k = obj.length - 1; k >= 0; k--) { if (hasPath(obj[k], segs, i + 1)) { obj.splice(k, 1); hit = true; } }
      return hit;
    }
    if (!Object.prototype.hasOwnProperty.call(obj, seg)) return false;
    if (last) { delete obj[seg]; return true; }
    return prunePath(obj[seg], segs, i + 1);
  }
  function hasPath(obj, segs, i) {
    if (i >= segs.length) return true;
    if (obj === null || typeof obj !== 'object') return false;
    var seg = segs[i];
    if (seg === '[]' || seg === '*') { for (var k in obj) { if (hasPath(obj[k], segs, i + 1)) return true; } return false; }
    if (!Object.prototype.hasOwnProperty.call(obj, seg)) return false;
    return hasPath(obj[seg], segs, i + 1);
  }
  function makePruner(rawPrune, rawNeedle) {
    var prune = (rawPrune || '').split(/ +/).filter(Boolean).map(function (p) { return p.split('.'); });
    var needles = (rawNeedle || '').split(/ +/).filter(Boolean).map(function (p) { return p.split('.'); });
    return function (obj) {
      if (!prune.length || obj === null || typeof obj !== 'object') return obj;
      for (var n = 0; n < needles.length; n++) if (!hasPath(obj, needles[n], 0)) return obj;
      for (var p = 0; p < prune.length; p++) prunePath(obj, prune[p], 0);
      return obj;
    };
  }

  S['json-prune'] = function (rawPrune, rawNeedle) {
    var pruner = makePruner(rawPrune, rawNeedle);
    var origParse = JSON.parse;
    JSON.parse = new Proxy(origParse, { apply: function (t, self, args) { return pruner(Reflect.apply(t, self, args)); } });
    var origJson = Response.prototype.json;
    Response.prototype.json = new Proxy(origJson, { apply: function (t, self, args) { return Reflect.apply(t, self, args).then(pruner); } });
  };

  function urlFromArgs(args, start) {
    var o = {}; for (var i = start; i + 1 < args.length; i += 2) o[args[i]] = args[i + 1];
    var p = o.propsToMatch || '';
    return p.replace(/^url:/, '');
  }

  S['json-prune-fetch-response'] = function (rawPrune, rawNeedle) {
    var pruner = makePruner(rawPrune, rawNeedle);
    var urlTest = matcher(urlFromArgs(arguments, 2));
    var origFetch = window.fetch;
    window.fetch = new Proxy(origFetch, {
      apply: function (t, self, args) {
        var req = args[0], url = typeof req === 'string' ? req : (req && req.url) || String(req);
        var p = Reflect.apply(t, self, args);
        if (!urlTest(url)) return p;
        return p.then(function (resp) {
          return resp.clone().json().then(function (obj) {
            var body = JSON.stringify(pruner(obj));
            return new Response(body, { status: resp.status, statusText: resp.statusText, headers: resp.headers });
          }).catch(function () { return resp; });
        });
      }
    });
  };

  S['json-prune-xhr-response'] = function (rawPrune, rawNeedle) {
    var pruner = makePruner(rawPrune, rawNeedle);
    var urlTest = matcher(urlFromArgs(arguments, 2));
    var X = XMLHttpRequest.prototype, origOpen = X.open;
    X.open = function (m, u) { this.__bUrl = String(u); return origOpen.apply(this, arguments); };
    ['response', 'responseText'].forEach(function (name) {
      var d = Object.getOwnPropertyDescriptor(X, name);
      if (!d || !d.get) return;
      Object.defineProperty(X, name, {
        configurable: true,
        get: function () {
          var v = d.get.call(this);
          if (this.readyState !== 4 || !this.__bUrl || !urlTest(this.__bUrl)) return v;
          try {
            if (typeof v === 'string') return JSON.stringify(pruner(JSON.parse(v)));
            if (v && typeof v === 'object') return pruner(v);
          } catch (e) {}
          return v;
        }
      });
    });
  };

  // ---- timers ------------------------------------------------------------------------------
  function timerDefuser(name) {
    return function (needle, delay) {
      var test = matcher(needle), dn = delay ? parseInt(String(delay).replace('!', ''), 10) : NaN, dneg = String(delay || '').charAt(0) === '!';
      window[name] = new Proxy(window[name], {
        apply: function (t, self, args) {
          var fnText = String(args[0]), d = args[1] | 0;
          var delayOk = isNaN(dn) ? true : ((d === dn) !== dneg);
          if (test(fnText) && delayOk) args[0] = noopFunc;
          return Reflect.apply(t, self, args);
        }
      });
    };
  }
  S['no-setTimeout-if'] = timerDefuser('setTimeout');
  S['no-setInterval-if'] = timerDefuser('setInterval');

  function booster(name) {
    return function (needle, delay, boost) {
      var test = matcher(needle || '');
      var dn = delay === undefined || delay === '' ? 1000 : (delay === '*' ? -1 : parseInt(delay, 10));
      var b = parseFloat(boost); if (isNaN(b)) b = 0.05; b = Math.min(50, Math.max(0.001, b));
      window[name] = new Proxy(window[name], {
        apply: function (t, self, args) {
          var d = args[1] | 0;
          if ((dn === -1 || d === dn) && test(String(args[0]))) args[1] = d * b;
          return Reflect.apply(t, self, args);
        }
      });
    };
  }
  S['nano-setTimeout-booster'] = booster('setTimeout');
  S['nano-setInterval-booster'] = booster('setInterval');

  S['addEventListener-defuser'] = function (type, needle) {
    var typeTest = matcher(type), fnTest = matcher(needle);
    var orig = EventTarget.prototype.addEventListener;
    EventTarget.prototype.addEventListener = new Proxy(orig, {
      apply: function (t, self, args) {
        var fn = args[1], txt = '';
        try { txt = typeof fn === 'function' ? String(fn) : (fn && fn.handleEvent ? String(fn.handleEvent) : ''); } catch (e) {}
        if (typeOf(args[0]) && typeTest(args[0]) && fnTest(txt)) return;
        return Reflect.apply(t, self, args);
      }
    });
    function typeOf(x) { return typeof x === 'string'; }
  };

  S['window.open-defuser'] = function (needle) {
    var test = matcher(needle || '');
    window.open = new Proxy(window.open, {
      apply: function (t, self, args) {
        if (test(String(args[0] || ''))) return null;
        return Reflect.apply(t, self, args);
      }
    });
  };

  S['no-fetch-if'] = function (needle) {
    var test = matcher(needle || '');
    window.fetch = new Proxy(window.fetch, {
      apply: function (t, self, args) {
        var req = args[0], url = typeof req === 'string' ? req : (req && req.url) || String(req);
        if (test(url.replace(/^url:/, ''))) return Promise.resolve(new Response('', { status: 200 }));
        return Reflect.apply(t, self, args);
      }
    });
  };

  S['no-xhr-if'] = function (needle) {
    var test = matcher((needle || '').replace(/^url:/, ''));
    var X = XMLHttpRequest.prototype, origOpen = X.open, origSend = X.send;
    X.open = function (m, u) { this.__bBlock = test(String(u)); return origOpen.apply(this, arguments); };
    X.send = function () {
      if (!this.__bBlock) return origSend.apply(this, arguments);
      var xhr = this;
      try {
        Object.defineProperty(xhr, 'readyState', { value: 4, configurable: true });
        Object.defineProperty(xhr, 'status', { value: 200, configurable: true });
        Object.defineProperty(xhr, 'responseText', { value: '', configurable: true });
        Object.defineProperty(xhr, 'response', { value: '', configurable: true });
      } catch (e) {}
      setTimeout(function () {
        try { xhr.dispatchEvent(new Event('readystatechange')); xhr.dispatchEvent(new Event('load')); xhr.dispatchEvent(new Event('loadend')); } catch (e) {}
      }, 1);
    };
  };

  S['noeval-if'] = function (needle) {
    var test = matcher(needle || '');
    window.eval = new Proxy(window.eval, { apply: function (t, self, args) { if (test(String(args[0]))) return; return Reflect.apply(t, self, args); } });
  };

  S['alert-buster'] = function () { window.alert = function () {}; };

  S['set-local-storage-item'] = function (key, value) {
    if (!key) return;
    try {
      if (value === '$remove$') { localStorage.removeItem(key); return; }
      var v = constValue(value);
      if (v === NOPE) return;
      localStorage.setItem(key, String(v === undefined ? 'undefined' : (typeof v === 'object' ? JSON.stringify(v) : v)));
    } catch (e) {}
  };

  function domWork(fn) {
    var run = function () { try { fn(); } catch (e) {} };
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run, { once: true }); else run();
    var pending = false;
    new MutationObserver(function () {
      if (pending) return; pending = true;
      setTimeout(function () { pending = false; run(); }, 50);
    }).observe(document, { childList: true, subtree: true, attributes: false });
  }

  S['remove-attr'] = function (attrs, selector) {
    if (!attrs) return;
    var list = attrs.split(/\s*\|\s*/);
    var sel = selector || list.map(function (a) { return '[' + a + ']'; }).join(',');
    domWork(function () {
      document.querySelectorAll(sel).forEach(function (el) { list.forEach(function (a) { el.removeAttribute(a); }); });
    });
  };

  S['remove-class'] = function (classes, selector) {
    if (!classes) return;
    var list = classes.split(/\s*\|\s*/);
    var sel = selector || list.map(function (c) { return '.' + c; }).join(',');
    domWork(function () {
      document.querySelectorAll(sel).forEach(function (el) { list.forEach(function (c) { el.classList.remove(c); }); });
    });
  };

  var ALIASES = {
    'set': 'set-constant', 'aopr': 'abort-on-property-read', 'aopw': 'abort-on-property-write',
    'acs': 'abort-current-script', 'abort-current-inline-script': 'abort-current-script', 'acis': 'abort-current-script',
    'nostif': 'no-setTimeout-if', 'prevent-setTimeout': 'no-setTimeout-if', 'setTimeout-defuser': 'no-setTimeout-if',
    'nosiif': 'no-setInterval-if', 'prevent-setInterval': 'no-setInterval-if', 'setInterval-defuser': 'no-setInterval-if',
    'nano-stb': 'nano-setTimeout-booster', 'nano-sib': 'nano-setInterval-booster', 'adjust-setTimeout': 'nano-setTimeout-booster',
    'adjust-setInterval': 'nano-setInterval-booster',
    'aeld': 'addEventListener-defuser', 'prevent-addEventListener': 'addEventListener-defuser',
    'nowoif': 'window.open-defuser', 'prevent-window-open': 'window.open-defuser',
    'prevent-fetch': 'no-fetch-if', 'prevent-xhr': 'no-xhr-if',
    'noeval-if': 'noeval-if', 'prevent-eval-if': 'noeval-if',
    'ra': 'remove-attr', 'rc': 'remove-class', 'set-local-storage-item': 'set-local-storage-item',
    'json-prune-fetch-response': 'json-prune-fetch-response', 'jpfr': 'json-prune-fetch-response',
    'json-prune-xhr-response': 'json-prune-xhr-response', 'jpxr': 'json-prune-xhr-response'
  };

  return function (list) {
      var ran = 0;
      for (var i = 0; i < list.length; i++) {
        var args = splitArgs(list[i]);
        var name = args.shift().replace(/\.js$/, '');
        var fn = S[ALIASES[name] || name];
        if (!fn) continue;
        try { fn.apply(null, args); ran++; } catch (e) {}
      }
      return ran;
  };
})();
