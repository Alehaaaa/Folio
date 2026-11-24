// Goodreads Lab recorder. Installed into each main-frame document at documentStart.
// Events are streamed to the native app, so navigation cannot erase the trace.
// No credentials, cookies, request bodies, entered notes or form field values
// are recorded. Only metadata needed to diagnose the site's UI is captured.
(() => {
  "use strict";
  if (window.__goodreadsLabRecorder) return;
  let active = false;
  let count = 0;
  const bridge = window.webkit?.messageHandlers?.goodreadsRecorder;
  const now = () => new Date().toISOString();
  const safe = value => String(value ?? "").slice(0, 1600)
    .replace(/(Bearer\s+)[A-Za-z0-9._-]+/gi, "$1[REDACTED]")
    .replace(/(token|secret|password|api[_-]?key|session|authenticity_token|csrf)(\s*[=:]\s*)[^\s"'&<>]+/gi, "$1$2[REDACTED]");
  const urlInfo = value => {
    try {
      const url = new URL(String(value), location.href);
      return {host: url.host, path: url.pathname.slice(0, 350),
        queryKeys: [...new Set(url.searchParams.keys())].slice(0, 40)};
    } catch { return {path: safe(value).slice(0, 200)}; }
  };
  const fields = body => {
    try {
      if (body instanceof FormData || body instanceof URLSearchParams) return [...new Set(body.keys())].slice(0, 50);
      if (typeof body === "string" && !body.trim().startsWith("{")) return [...new Set(new URLSearchParams(body).keys())].slice(0, 50);
      if (typeof body === "string" && body.trim().startsWith("{")) {
        const value = JSON.parse(body);
        const collect = (obj, prefix = "", depth = 0) => {
          if (!obj || typeof obj !== "object" || depth > 3) return [];
          return Object.keys(obj).slice(0, 35).flatMap(key => [prefix + key, ...collect(obj[key], prefix + key + ".", depth + 1)]);
        };
        return collect(value).slice(0, 60);
      }
    } catch { /* Only names are recorded. */ }
    return [];
  };
  const safePayload = body => {
    // Keep a few non-secret book and progress values, which are essential
    // to reproduce the currently-reading progress request. Never keep notes.
    try {
      const keys = /^(?:book_id|bookId|review_id|reviewId|percent|percentage|progress|page|pages|currentPosition|finalPosition|shelfName|name|operationName|user_status\[(?:book_id|percent|page|progress)\])$/;
      const allowValue = (name, value) => {
        if (!keys.test(name) || (typeof value !== "string" && typeof value !== "number")) return null;
        const text = String(value);
        return /^(?:[0-9]{1,16}|[a-z-]{1,40}|[A-Za-z][A-Za-z0-9_]{1,45})$/.test(text) ? text : null;
      };
      let values = {};
      if (body instanceof FormData || body instanceof URLSearchParams ||
          (typeof body === "string" && !body.trim().startsWith("{"))) {
        const form = typeof body === "string" ? new URLSearchParams(body) : body;
        for (const [name, value] of form) {
          const permitted = allowValue(name, value);
          if (permitted != null) values[name] = permitted;
        }
      } else if (typeof body === "string" && body.trim().startsWith("{")) {
        const parsed = JSON.parse(body);
        for (const [name, value] of Object.entries(parsed)) {
          const permitted = allowValue(name, value);
          if (permitted != null) values[name] = permitted;
        }
        for (const [name, value] of Object.entries(parsed.variables?.input || {})) {
          const permitted = allowValue(name, value);
          if (permitted != null) values["variables.input." + name] = permitted;
        }
      }
      return values;
    } catch { return {}; }
  };
  const emit = (type, detail = {}) => {
    if (!active || ++count > 3500) return;
    try { bridge?.postMessage({time: now(), type, page: urlInfo(location.href), ...detail}); }
    catch { /* Recording must not break Goodreads. */ }
  };
  const scrubHTML = html => safe(html)
    .replace(/\s(value|data-token|data-csrf|data-auth|nonce|integrity)\s*=\s*(["']).*?\2/gi, ' $1="[REDACTED]"')
    .replace(/(<(?:input|textarea)[^>]*type=["'](?:password|hidden)["'][^>]*>)/gi, '[REDACTED FIELD]');
  const describe = element => {
    if (!(element instanceof Element)) return {};
    const e = element.closest('button,a,[role="button"],input,label,form,[data-testid]') || element;
    return {tag: e.tagName.toLowerCase(), id: safe(e.id).slice(0, 120),
      classes: safe(typeof e.className === "string" ? e.className : "").slice(0, 200),
      testID: safe(e.getAttribute("data-testid")).slice(0, 120),
      label: safe(e.getAttribute("aria-label") || e.getAttribute("title") || e.innerText || e.textContent).slice(0, 180),
      href: e.getAttribute("href") ? urlInfo(e.getAttribute("href")) : null,
      html: scrubHTML(e.outerHTML).slice(0, 1400)};
  };
  const notePage = () => emit("page", {title: safe(document.title), readyState: document.readyState,
    scripts: [...document.scripts].slice(0, 100).map(s => s.src ? urlInfo(s.src) : {inline: true, length: s.textContent?.length || 0})});

  window.__goodreadsLabRecorder = {
    start() { active = true; count = 0; notePage(); emit("recording-start"); return true; },
    stop() { emit("recording-stop"); active = false; return true; },
    status() { return {active, count}; },
  };

  document.addEventListener("click", event => emit("click", {
    target: describe(event.target), x: Math.round(event.clientX), y: Math.round(event.clientY),
    trusted: event.isTrusted,
  }), true);
  document.addEventListener("pointerdown", event => emit("pointerdown", {target: describe(event.target)}), true);
  document.addEventListener("submit", event => {
    if (event.target instanceof HTMLFormElement) {
      emit("submit", {method: event.target.method, action: urlInfo(event.target.action),
        fields: fields(new FormData(event.target)), target: describe(event.target)});
    }
  }, true);
  document.addEventListener("change", event => {
    const e = event.target;
    if (e instanceof Element) emit("change", {target: describe(e), field: safe(e.getAttribute("name"))});
  }, true);
  window.addEventListener("error", event => emit("javascript-error", {
    message: safe(event.message), filename: event.filename ? urlInfo(event.filename) : null,
    line: event.lineno, column: event.colno,
  }), true);
  window.addEventListener("unhandledrejection", event => emit("unhandled-promise", {
    reason: safe(event.reason?.message || event.reason),
  }));
  window.addEventListener("popstate", () => emit("history", {kind: "popstate"}));
  window.addEventListener("hashchange", () => emit("history", {kind: "hashchange"}));
  for (const method of ["pushState", "replaceState"]) {
    const original = history[method];
    history[method] = function () {
      const result = original.apply(this, arguments);
      emit("history", {kind: method, target: urlInfo(location.href)});
      return result;
    };
  }
  const originalFetch = window.fetch;
  if (typeof originalFetch === "function") {
    window.fetch = function(resource, options = {}) {
      const url = resource instanceof Request ? resource.url : resource;
      const method = options.method || (resource instanceof Request ? resource.method : "GET");
      const detail = {transport: "fetch", method: String(method).toUpperCase(), target: urlInfo(url),
        fields: fields(options.body), safeValues: safePayload(options.body)};
      const started = performance.now();
      emit("request", detail);
      const promise = originalFetch.apply(this, arguments);
      Promise.resolve(promise).then(response => emit("response", {...detail, status: response.status,
        durationMS: Math.round(performance.now() - started), responseType: safe(response.headers.get("content-type")).slice(0, 100)}),
      error => emit("request-error", {...detail, error: safe(error?.message)}));
      return promise;
    };
  }
  const xhrOpen = XMLHttpRequest.prototype.open;
  const xhrSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function(method, url) {
    this.__goodreadsLab = {method: String(method).toUpperCase(), target: urlInfo(url)};
    return xhrOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function(body) {
    const detail = this.__goodreadsLab;
    if (detail) {
      const start = performance.now();
      emit("request", {...detail, transport: "xhr", fields: fields(body), safeValues: safePayload(body)});
      this.addEventListener("loadend", () => emit("response", {...detail, transport: "xhr", status: this.status,
        durationMS: Math.round(performance.now() - start), responseType: safe(this.getResponseHeader("content-type")).slice(0, 100)}), {once: true});
    }
    return xhrSend.apply(this, arguments);
  };
  for (const method of ["log", "info", "warn", "error", "debug"]) {
    const original = console[method];
    if (typeof original !== "function") continue;
    console[method] = function (...args) {
      if (method === "warn" || method === "error") emit("console", {level: method,
        message: safe(args.map(arg => typeof arg === "string" ? arg : Object.prototype.toString.call(arg)).join(" ")).slice(0, 500)});
      return original.apply(this, args);
    };
  }
  const nativeEval = window.eval;
  window.eval = function (...args) {
    if (active) emit("dynamic-js", {kind: "eval", length: String(args[0] ?? "").length});
    return nativeEval.apply(this, args);
  };
  const observer = new MutationObserver(records => {
    if (!active) return;
    const additions = records.flatMap(record => [...record.addedNodes]);
    const pertinent = additions.filter(n => n instanceof Element &&
      (n.matches('[role="dialog"],dialog,script,[class*="modal"],[class*="popover"]') ||
       n.querySelector?.('[role="dialog"],dialog,[class*="modal"],[class*="popover"]'))).slice(0, 6);
    for (const node of pertinent) emit("dom-added", {target: describe(node)});
  });
  observer.observe(document, {subtree: true, childList: true});
  try {
    const resources = new PerformanceObserver(list => {
      for (const item of list.getEntries().slice(0, 80)) {
        if (item.initiatorType === "script" || item.initiatorType === "link" || item.initiatorType === "css") {
          emit("resource", {kind: item.initiatorType, target: urlInfo(item.name), durationMS: Math.round(item.duration)});
        }
      }
    });
    resources.observe({type: "resource", buffered: true});
  } catch { /* PerformanceObserver is optional. */ }
  document.addEventListener("DOMContentLoaded", notePage);
  window.addEventListener("load", notePage);
})();
