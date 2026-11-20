enum ReaderScript {
    /// Pagination, selection and non-layout-changing highlights for EPUB chapters.
    static let source = #"""
(function(){
if (window.folio) return;
const F = { cfg: null, page: 0, pages: 1, ready: false, loadID: null,
            navPosted: false, layoutVersion: 0, annRanges: [], highlightLayer: null,
            highlightBackend: 'overlay', visibleAnchor: null, pendingAnchor: null,
            viewWidth: 0, viewHeight: 0, layoutKey: null, navSerial: 0,
            restoringAnchor: false,
            decorationCache: new WeakMap(),
            decorationRejected: new WeakSet(), decorationCount: 0 };
window.folio = F;
const se = () => document.scrollingElement || document.documentElement;
const width = () => Math.max(1, document.documentElement.clientWidth || window.innerWidth);
F.post = m => { try { window.webkit.messageHandlers.folio.postMessage({...m, loadID: F.loadID}); } catch (e) {} };
F.paged = () => F.cfg && F.cfg.mode === 'pages';

F.css = function(c){
  const W = width(), H = window.innerHeight;
  const paged = c.mode === 'pages';
  const n = (paged && c.columns && W >= 1000 && !c.comic) ? 2 : 1;
  const G = Math.round(c.margin * 2);
  const colW = Math.max(120, (W - G - (n - 1) * G) / n);
  const padV = c.comic ? 10 : Math.round(Math.max(36, c.margin * 0.8));
  // Palette changes update root custom properties without rebuilding columns.
  let s = `html{background:var(--folio-bg) !important;-webkit-text-size-adjust:none;}`;
  if (paged) {
    s += `html{height:${H}px !important;overflow-x:auto !important;overflow-y:hidden !important;scroll-behavior:auto !important;}`;
    // WebKit's final multicolumn box often ends one side margin before a
    // viewport boundary. A non-flow root pseudo-element extends only the
    // scrollable track; padding the body would change column widths/count.
    s += `html::after{content:"";position:absolute;top:0;left:var(--folio-page-end,0px);width:1px;height:1px;pointer-events:none;visibility:hidden;}`;
    s += `body{height:${H}px !important;width:${W}px !important;column-width:${colW}px !important;column-gap:${G}px !important;column-fill:auto !important;padding:${padV}px ${G/2}px !important;margin:0 !important;max-width:none !important;overflow:visible !important;}`;
  } else {
    const maxW = c.comic ? W : Math.min(W - G, 640 + c.fontSize * 8);
    s += `html{overflow-y:auto !important;overflow-x:hidden !important;}`;
    s += `body{max-width:${maxW}px !important;margin:0 auto !important;padding:${padV}px ${Math.round(c.margin/2)}px ${H/2}px !important;}`;
  }
  s += `body{box-sizing:border-box !important;background:var(--folio-bg) !important;color:var(--folio-fg) !important;font-size:${c.fontSize}px !important;-webkit-hyphens:auto;hyphens:auto;}`;
  if (c.font) s += `body, body *:not(code):not(pre):not(kbd):not(samp){font-family:${c.font} !important;}`;
  if (c.lineHeight) s += `body, body p, body div, body li, body blockquote, body span{line-height:${c.lineHeight} !important;}`;
  if (c.letterSpacing) s += `body *{letter-spacing:${c.letterSpacing}em !important;}`;
  if (c.wordSpacing) s += `body *{word-spacing:${c.wordSpacing}em !important;}`;
  if (c.bold) s += `body, body *{font-weight:600 !important;} body h1, body h2, body h3, body b, body strong{font-weight:800 !important;}`;
  s += c.justify ? `body p{text-align:justify !important;}` : `body p{text-align:start !important;}`;
  s += `body *{color:inherit !important;background-color:transparent !important;}`;
  s += `a, a *{color:var(--folio-accent) !important;text-decoration:none !important;}`;
  s += `img,svg,video{max-width:100% !important;max-height:${H - 2*padV}px !important;height:auto;object-fit:contain;break-inside:avoid;}`;
  if (c.comic) {
    const ph = paged ? (H - 2*padV) + 'px' : 'auto';
    s += `.folio-comic-page{height:${ph};display:flex;align-items:center;justify-content:center;break-after:column;margin:0 0 ${paged?0:12}px 0;}`;
    s += `.folio-comic-page img{max-height:${paged ? (H - 2*padV)+'px' : 'none'} !important;max-width:100% !important;}`;
  }
  s += `::selection{background:var(--folio-accent-selection);}`;
  s += `::highlight(folio-annotations){background-color:var(--folio-accent-selection);}`;
  return s;
};

F.measure = function(){
  const W = width(), H = window.innerHeight, e = se();
  if (F.paged()) {
    // The root includes our end-of-track spacer; count pages from the body's
    // *actual* column overflow to avoid adding a phantom blank reading page.
    const total = Math.max(W, document.body.scrollWidth);
    F.pages = Math.max(1, Math.ceil((total - 1) / W));
    // Give the final page a full viewport-wide scroll range. Without this,
    // WebKit clamps scrollLeft short by half the side margin (or more for a
    // partial spread), shifting the last text to the right.
    const root = document.documentElement;
    const end = F.pages * W - 1;
    if (root.style && F.pageTrackEnd !== end) {
      root.style.setProperty('--folio-page-end', end + 'px');
      F.pageTrackEnd = end;
    }
    F.page = Math.max(0, Math.min(F.pages - 1, Math.ceil((e.scrollLeft - 1) / W)));
  } else {
    const maxScroll = Math.max(0, e.scrollHeight - H);
    F.pages = Math.max(1, Math.ceil(maxScroll / (H * 0.9)) + 1);
    F.page = Math.max(0, Math.min(F.pages - 1, Math.floor((e.scrollTop + 2) / (H * 0.9))));
  }
};

// Range geometry is evaluated in layout order, so a text node split across
// columns can yield rectangles from several pages. Selecting the first
// viewport-intersecting rectangle follows the first character actually shown.
F.visibleRect = function(r){
  if (!r || !Number.isFinite(r.left) || !Number.isFinite(r.top)) return false;
  return Math.min(width(), r.right) - Math.max(0, r.left) >= 2
    && Math.min(window.innerHeight, r.bottom) - Math.max(0, r.top) >= 2;
};

F.fallbackAnchor = function(){
  F.measure();
  const e = se();
  return {
    node: null, offset: 0, y: 0,
    fraction: F.paged() ? F.page / Math.max(1, F.pages)
      : e.scrollTop / Math.max(1, e.scrollHeight - window.innerHeight),
    atEnd: F.paged() ? F.page >= F.pages - 1
      : e.scrollTop >= e.scrollHeight - window.innerHeight - 2
  };
};

F.visualRank = function(rect){
  const x = Math.max(0, rect.left), y = Math.max(0, rect.top);
  const twoColumns = F.paged() && F.cfg.columns && width() >= 1000 && !F.cfg.comic;
  // In a two-column spread, the left column is read before the right one.
  return twoColumns ? [Math.floor(x / (width() / 2)), y, x] : [y, x];
};

F.isEarlierRect = function(a, b){
  if (!b) return true;
  const left = F.visualRank(a), right = F.visualRank(b);
  for (let i = 0; i < left.length; i++) {
    if (left.length === 3 && i === 0 && left[i] !== right[i])
      return left[i] < right[i];
    if (Math.abs(left[i] - right[i]) > 1.5) return left[i] < right[i];
  }
  return false;
};

F.characterRect = function(node, offset){
  if (!node || !node.nodeValue || !document.createRange) return null;
  const range = document.createRange();
  const index = Math.max(0, Math.min(node.nodeValue.length - 1, offset));
  range.setStart(node, index);
  range.setEnd(node, index + 1);
  return Array.from(range.getClientRects()).find(r => r.width > 0 && r.height > 0) || null;
};

F.findAnchorOffset = function(node, rect){
  const x = Math.max(2, Math.min(width() - 2, Math.max(0, rect.left) + 3));
  const y = Math.max(2, Math.min(window.innerHeight - 2,
    Math.max(0, rect.top) + Math.min(4, rect.height / 2)));
  const caret = document.caretRangeFromPoint ? document.caretRangeFromPoint(x, y) : null;
  const position = !caret && document.caretPositionFromPoint
    ? document.caretPositionFromPoint(x, y) : null;
  const matches = caret && caret.startContainer === node
    ? caret.startOffset : position && position.offsetNode === node ? position.offset : -1;
  if (matches >= 0) {
    let offset = Math.max(0, Math.min(node.nodeValue.length - 1, matches));
    // caretRangeFromPoint may hit a word interior: back up to the first
    // visible character on that exact line, not the start of the DOM node.
    const line = F.characterRect(node, offset);
    if (line && F.visibleRect(line)) {
      while (offset > 0) {
        const previous = F.characterRect(node, offset - 1);
        if (!previous || !F.visibleRect(previous) ||
            Math.abs(previous.top - line.top) > 2 || previous.left > line.left + 2)
          break;
        offset--;
      }
      return offset;
    }
  }
  // WebKit's hit test sometimes resolves to a parent/sibling. Binary search
  // over text characters in layout order to find this visible line.
  const ordered = r => {
    if (!r) return Number.NEGATIVE_INFINITY;
    const px = Math.floor((r.left + se().scrollLeft) / width());
    const column = F.paged() && F.cfg.columns && width() >= 1000
      ? Math.floor(Math.max(0, (r.left + se().scrollLeft) % width()) / (width() / 2)) : 0;
    return F.paged() ? px * 1e9 + column * 1e8 + r.top * 1e4 + r.left
      : (r.top + se().scrollTop) * 1e4 + r.left;
  };
  const target = ordered(rect);
  let lo = 0, hi = node.nodeValue.length - 1;
  while (lo < hi) {
    const mid = Math.floor((lo + hi) / 2);
    if (ordered(F.characterRect(node, mid)) < target - 3) lo = mid + 1;
    else hi = mid;
  }
  for (let index = Math.max(0, lo - 2); index < Math.min(node.nodeValue.length, lo + 5); index++) {
    const candidate = F.characterRect(node, index);
    if (candidate && F.visibleRect(candidate) && Math.abs(candidate.top - rect.top) <= 3)
      return index;
  }
  return lo;
};

F.captureVisibleAnchor = function(){
  const fallback = F.fallbackAnchor();
  if (!document.body || !document.createTreeWalker) return fallback;
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  const range = document.createRange();
  let visits = 0, best = null;
  while (walker.nextNode() && ++visits < 30000) {
    const node = walker.currentNode;
    if (!node.nodeValue || !node.nodeValue.trim()) continue;
    const parent = node.parentElement;
    if (!parent || (parent.closest &&
        parent.closest('script,style,noscript,template,[aria-hidden="true"]'))) continue;
    try {
      range.selectNodeContents(node);
      for (const rect of range.getClientRects()) {
        if (F.visibleRect(rect) && (!best || F.isEarlierRect(rect, best.rect)))
          best = {node, rect};
      }
    } catch (e) { /* Text being replaced while images or fonts load. */ }
  }
  if (best) {
    const offset = F.findAnchorOffset(best.node, best.rect);
    const exact = F.characterRect(best.node, offset);
    return { ...fallback, node: best.node, offset,
      y: exact && F.visibleRect(exact) ? exact.top : best.rect.top,
      x: exact && F.visibleRect(exact) ? exact.left : best.rect.left };
  }
  return fallback;
};

F.restoreVisibleAnchor = function(anchor){
  if (!anchor) return false;
  // A mode switch can retain the previous mode's hidden-axis scroll offset
  // in WebKit, making otherwise correctly restored text remain offscreen.
  const scrolling = se();
  if (F.paged()) scrolling.scrollTop = 0;
  else scrolling.scrollLeft = 0;
  const node = anchor.node;
  if (node && node.isConnected !== false && node.nodeValue && document.body.contains(node)) {
    try {
      const range = document.createRange();
      const offset = Math.max(0, Math.min(node.nodeValue.length - 1, anchor.offset));
      range.setStart(node, offset);
      range.setEnd(node, offset + 1);
      const rect = Array.from(range.getClientRects()).find(r => r.width > 0 && r.height > 0);
      if (rect) {
        const e = se();
        if (F.paged()) {
          const absoluteX = rect.left + e.scrollLeft;
          F.restoringAnchor = true;
          try { F.goPage(Math.floor(Math.max(0, absoluteX + 1) / width())); }
          finally { F.restoringAnchor = false; }
          // On the final page WebKit may clamp scrollLeft short of a full
          // viewport. Trust the character's *actual* post-scroll rect.
          const after = F.characterRect(node, offset);
          if (after && !F.visibleRect(after)) {
            const maxLeft = Math.max(0, e.scrollWidth - width());
            e.scrollLeft = Math.max(0, Math.min(maxLeft,
              e.scrollLeft + (after.left < 0 ? after.left - 2 : after.right - width() + 2)));
            F.report();
          }
        } else {
          e.scrollTop += rect.top - anchor.y;
          F.report();
        }
        const after = F.characterRect(node, offset);
        if (after && F.visibleRect(after)) return true;
      }
    } catch (e) { /* Fall back if asynchronous EPUB content replaced the node. */ }
  }
  F.restoringAnchor = true;
  try {
    if (anchor.atEnd) F.goEnd();
    else F.goFraction(anchor.fraction);
  } finally { F.restoringAnchor = false; }
  return false;
};

let anchorTimer = null;
F.refreshVisibleAnchor = function(){
  if (!F.ready || F.pendingAnchor) return;
  F.visibleAnchor = F.captureVisibleAnchor();
  F.viewWidth = width();
  F.viewHeight = window.innerHeight;
};

F.report = function(){
  F.measure();
  const e = se();
  let frac = F.page / F.pages;
  if (!F.paged()) frac = e.scrollTop / Math.max(1, e.scrollHeight - window.innerHeight);
  F.post({ type: 'pos', page: F.page, pages: F.pages, frac: frac });
  F.paintFallbackHighlights();
  if (F.ready && !F.pendingAnchor) {
    // A large EPUB chapter can have thousands of DOM nodes. Debounce Range
    // measurement while scrolling; take a fresh snapshot when it settles.
    clearTimeout(anchorTimer);
    anchorTimer = setTimeout(F.refreshVisibleAnchor, 180);
  }
};

F.goPage = function(p){
  if (!F.restoringAnchor) F.navSerial++;
  F.measure();
  p = Math.max(0, Math.min(F.pages - 1, p));
  const e = se();
  if (F.paged()) e.scrollLeft = p * width(); else e.scrollTop = p * window.innerHeight * 0.9;
  F.report();
  return F.page === p;
};

F.goFraction = function(f){
  if (!F.restoringAnchor) F.navSerial++;
  F.measure();
  const e = se();
  if (F.paged()) F.goPage(Math.floor(Math.max(0, Math.min(1, f)) * F.pages + 1e-6));
  else { e.scrollTop = f * Math.max(0, e.scrollHeight - window.innerHeight); F.report(); }
};

F.goEnd = function(){
  if (!F.restoringAnchor) F.navSerial++;
  F.measure();
  if (F.paged()) F.goPage(F.pages - 1);
  else { const e = se(); e.scrollTop = e.scrollHeight; F.report(); }
};

F.goFragment = function(id){
  const el = document.getElementById(id) || document.getElementsByName(id)[0];
  if (!el) { F.goPage(0); return; }
  if (F.paged()) {
    const r = el.getBoundingClientRect();
    F.goPage(Math.floor((r.left + se().scrollLeft + 2) / width()));
  } else { el.scrollIntoView(); F.report(); }
};

F.next = function(){
  if (!F.ready) return true;
  F.measure();
  const e = se(), H = window.innerHeight;
  if (F.paged()) { if (F.page < F.pages - 1) return F.goPage(F.page + 1); return false; }
  if (e.scrollTop < e.scrollHeight - H - 2) {
    e.scrollTop = Math.min(e.scrollHeight - H, e.scrollTop + H * 0.9);
    F.report(); return true;
  }
  return false;
};

F.prev = function(){
  if (!F.ready) return true;
  F.measure();
  const e = se(), H = window.innerHeight;
  if (F.paged()) { if (F.page > 0) return F.goPage(F.page - 1); return false; }
  if (e.scrollTop > 2) { e.scrollTop = Math.max(0, e.scrollTop - H * 0.9); F.report(); return true; }
  return false;
};
F.navigate = function(dir){
  F.navPosted = false;
  return dir > 0 ? F.next() : F.prev();
};

F.clearSelection = function(){
  const sel = window.getSelection();
  if (sel) sel.removeAllRanges();
  F.post({ type: 'selection' });
};

F.reportSelection = function(){
  const sel = window.getSelection();
  if (!sel || sel.isCollapsed || !sel.rangeCount) {
    F.post({ type: 'selection' }); return;
  }
  const range = sel.getRangeAt(0);
  const text = sel.toString().trim();
  if (!text || !document.body.contains(range.commonAncestorContainer)) {
    F.post({ type: 'selection' }); return;
  }
  try {
    const before = document.createRange();
    before.selectNodeContents(document.body);
    before.setEnd(range.startContainer, range.startOffset);
    const after = document.createRange();
    after.selectNodeContents(document.body);
    after.setStart(range.endContainer, range.endOffset);
    F.post({
      type: 'selection', text: text,
      prefix: before.toString().slice(-80),
      suffix: after.toString().slice(0, 80)
    });
  } catch (e) {
    F.post({ type: 'selection', text: text, prefix: '', suffix: '' });
  }
};

let selectionTimer = null;
document.addEventListener('selectionchange', () => {
  clearTimeout(selectionTimer);
  selectionTimer = setTimeout(F.reportSelection, 90);
});

// CSS Custom Highlights render above original text without inserting spans
// or changing any column geometry.
F.highlightAnnotations = function(annotations){
  if (!Array.isArray(annotations)) return 0;
  F.annRanges = [];
  F.highlightBackend = 'overlay';
  if (window.CSS && CSS.highlights) CSS.highlights.delete('folio-annotations');
  if (F.highlightLayer) F.highlightLayer.replaceChildren();
  if (!document.body) return 0;

  const nodes = [], strings = [];
  let length = 0;
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      if (!node.nodeValue || !node.nodeValue.length) return NodeFilter.FILTER_REJECT;
      const p = node.parentElement;
      return p && !p.closest('script,style,noscript,template')
        ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
    }
  });
  while (walker.nextNode()) {
    const node = walker.currentNode, len = node.nodeValue.length;
    nodes.push({ node: node, start: length, end: length + len });
    strings.push(node.nodeValue);
    length += len;
  }
  if (!length) return 0;
  const full = strings.join('');
  const at = (offset, ending) => {
    for (const part of nodes) {
      if (offset < part.end || (ending && offset === part.end))
        return [part.node, offset - part.start];
    }
    const last = nodes[nodes.length - 1];
    return [last.node, last.end - last.start];
  };
  const clean = s => String(s || '').replace(/\s+/g, ' ').trim();
  const commonEdge = (one, two, fromEnd) => {
    one = clean(one).slice(fromEnd ? -80 : 0, fromEnd ? undefined : 80);
    two = clean(two).slice(fromEnd ? -80 : 0, fromEnd ? undefined : 80);
    let score = 0;
    while (score < one.length && score < two.length
           && (fromEnd ? one[one.length - 1 - score] === two[two.length - 1 - score]
                       : one[score] === two[score])) score++;
    return score;
  };
  for (const entry of annotations) {
    const quote = typeof entry === 'string' ? entry : entry && (entry.text || entry.quote);
    if (typeof quote !== 'string' || !quote.trim()) continue;
    const chunks = quote.trim().split(/\s+/).filter(Boolean);
    const escaped = chunks.map(s => s.replace(/[.*+?^$()|[\]{}\\]/g, '\\$&'));
    // Formatting and adjacent blocks can add or omit whitespace.
    const expression = new RegExp(escaped.join('\\s*'), 'g');
    let match, best = null, count = 0;
    while ((match = expression.exec(full)) !== null && count++ < 1000) {
      const start = match.index, end = start + match[0].length;
      const prefix = typeof entry === 'object' ? entry.prefix : '';
      const suffix = typeof entry === 'object' ? entry.suffix : '';
      const score = commonEdge(prefix, full.slice(Math.max(0, start - 80), start), true)
                  + commonEdge(suffix, full.slice(end, end + 80), false);
      if (!best || score > best.score) best = {start, end, score};
      if (score >= clean(prefix).length + clean(suffix).length && score > 0) break;
    }
    if (!best) continue;
    const start = at(best.start, false), end = at(best.end, true);
    try {
      const range = document.createRange();
      range.setStart(start[0], start[1]);
      range.setEnd(end[0], end[1]);
      F.annRanges.push(range);
    } catch (e) {}
  }

  if (window.CSS && CSS.highlights && typeof Highlight !== 'undefined') {
    try {
      if (F.annRanges.length)
        CSS.highlights.set('folio-annotations', new Highlight(...F.annRanges));
      F.highlightBackend = 'native';
      return F.annRanges.length;
    } catch (e) { /* Use geometry overlays on older WebKit versions. */ }
  }
  F.paintFallbackHighlights();
  return F.annRanges.length;
};

F.paintFallbackHighlights = function(){
  if (F.highlightBackend === 'native') return;
  if (!F.annRanges.length) {
    if (F.highlightLayer) F.highlightLayer.replaceChildren();
    return;
  }
  if (!F.highlightLayer) {
    const layer = document.createElement('div');
    layer.setAttribute('aria-hidden', 'true');
    layer.style.cssText = 'position:fixed;inset:0;pointer-events:none;z-index:2147483000;';
    document.documentElement.appendChild(layer);
    F.highlightLayer = layer;
  }
  const elements = [];
  const ink = F.cfg ? F.cfg.accent + '55' : '#ffcb5555';
  for (const range of F.annRanges) {
    for (const rect of range.getClientRects()) {
      if (rect.width <= 0 || rect.height <= 0 || rect.right < 0 || rect.left > width()
          || rect.bottom < 0 || rect.top > window.innerHeight) continue;
      const box = document.createElement('div');
      box.style.cssText = 'position:absolute;border-radius:2px;background:' + ink + ';'
        + 'left:' + rect.left + 'px;top:' + rect.top + 'px;'
        + 'width:' + rect.width + 'px;height:' + rect.height + 'px;';
      elements.push(box);
      if (elements.length >= 400) break;
    }
    if (elements.length >= 400) break;
  }
  F.highlightLayer.replaceChildren(...elements);
};

F.themeRGB = function(hex){
  const value = String(hex || '').replace(/^#/, '');
  if (!/^(?:[0-9a-f]{3}|[0-9a-f]{6})$/i.test(value)) return null;
  const expanded = value.length === 3
    ? value.split('').map(c => c + c).join('') : value;
  return [0, 2, 4].map(i => parseInt(expanded.slice(i, i + 2), 16));
};

// The EPUB pages are loaded with file://. WebKit taints a canvas containing
// file:// images even when the image is in the same extracted book directory.
// Ask the native reader for a vetted, small raster resource only after the
// non-pixel checks pass; data: images are origin-clean for canvas inspection.
F.decorationRequests = new Map();
F.decorationRequested = new WeakSet();
F.decorationRequestCount = 0;
F.decorationNextRequest = 0;
F.requestDecorationData = function(img){
  const source = img.currentSrc || img.src || '';
  if (!/^file:\/\/\//i.test(source) ||
      !/\.(?:png|jpe?g|webp|gif|bmp)(?:[?#]|$)/i.test(source) ||
      !window.webkit || !window.webkit.messageHandlers ||
      !window.webkit.messageHandlers.folio ||
      F.decorationRequested.has(img) || F.decorationRequestCount >= 24) return false;
  const request = ++F.decorationNextRequest;
  F.decorationRequested.add(img);
  F.decorationRequestCount++;
  F.decorationRequests.set(request, {img: img, source: source});
  F.post({type: 'decorate', requestID: request, src: source});
  return true;
};

F.receiveDecorationData = function(request, dataURL){
  const pending = F.decorationRequests.get(request);
  if (!pending) return;
  F.decorationRequests.delete(request);
  const img = pending.img;
  if (!img.isConnected || (img.currentSrc || img.src) !== pending.source ||
      typeof dataURL !== 'string' ||
      !/^data:image\/(?:png|jpeg|webp|gif|bmp);base64,/i.test(dataURL)) {
    F.decorationRejected.add(img);
    return;
  }
  const sourceImage = new Image();
  sourceImage.onload = function(){
    if (!img.isConnected || (img.currentSrc || img.src) !== pending.source) return;
    if (sourceImage.naturalWidth !== img.naturalWidth ||
        sourceImage.naturalHeight !== img.naturalHeight) {
      F.decorationRejected.add(img);
      return;
    }
    if (F.inspectDecoration(img, sourceImage)) F.recolorDecoration(img, F.cfg);
  };
  sourceImage.onerror = function(){ F.decorationRejected.add(img); };
  sourceImage.src = dataURL;
};

// A publisher's small monochrome ornament or narrow chapter divider on an
// opaque light rectangle can become theme-colored ink on transparency.
// Long, narrow dividers have antialiased JPEG strokes (many midtone pixels),
// so they need their own geometry and pixel thresholds. Preserve photographs,
// covers and logos with conservative shape, context and color checks.
F.inspectDecoration = function(img, originCleanImage){
  if (!img || !img.complete || !img.naturalWidth || !img.naturalHeight ||
      F.decorationRejected.has(img) || F.decorationCount >= 24) return null;
  const w = img.naturalWidth, h = img.naturalHeight;
  const rect = img.getBoundingClientRect();
  const source = (img.currentSrc || img.getAttribute('src') || '').toLowerCase();
  const description = ((img.getAttribute('alt') || '') + ' ' +
    (img.getAttribute('class') || '') + ' ' + source).toLowerCase();
  const longDivider = rect && w >= 90 && h >= 8 && h <= 80 &&
    w / h >= 6 && w / h <= 28 &&
    rect.width >= 40 && rect.width <= 640 &&
    rect.height >= 8 && rect.height <= 120 &&
    rect.width / rect.height >= 5;
  if (!rect || rect.width < 8 || rect.height < 8 ||
      (!longDivider && (rect.width > 260 || w / h > 5)) ||
      rect.height > 260 || w > 640 || h > 640 ||
      w * h > 200000 || h / w > 5 ||
      img.hasAttribute('srcset') || img.closest('picture,.folio-comic-page') ||
      img.closest('[class*="cover" i],[id*="cover" i]') ||
      /cover|comic|photo|portrait|poster|illustration|artwork|panel|thumbnail|logo|publisher|advert/.test(description)) {
    F.decorationRejected.add(img);
    return null;
  }
  try {
    const probe = document.createElement('canvas');
    probe.width = Math.max(1, Math.round(w * Math.min(1, 96 / Math.max(w, h))));
    probe.height = Math.max(1, Math.round(h * Math.min(1, 96 / Math.max(w, h))));
    const p = probe.getContext('2d', {willReadFrequently: true});
    if (!p) throw new Error('Canvas unavailable');
    p.drawImage(originCleanImage || img, 0, 0, probe.width, probe.height);
    const samples = p.getImageData(0, 0, probe.width, probe.height).data;
    let white = 0, ink = 0, mid = 0, color = 0, transparent = 0;
    let borderPixels = 0, borderWhite = 0, borderBright = 0, borderLuma = 0;
    const corners = [0, probe.width - 1,
      (probe.height - 1) * probe.width,
      probe.width * probe.height - 1];
    let whiteCorners = 0;
    for (let pixel = 0; pixel < samples.length; pixel += 4) {
      const r = samples[pixel], g = samples[pixel + 1],
            b = samples[pixel + 2], a = samples[pixel + 3];
      if (a < 248) { transparent++; continue; }
      if (Math.max(r, g, b) - Math.min(r, g, b) > 17) color++;
      const luma = (r * 299 + g * 587 + b * 114) / 1000;
      const pixelIndex = pixel / 4;
      const x = pixelIndex % probe.width, y = Math.floor(pixelIndex / probe.width);
      if (x === 0 || x === probe.width - 1 || y === 0 || y === probe.height - 1) {
        borderPixels++;
        borderLuma += luma;
        if (luma >= 240) borderWhite++;
        if (luma >= 220) borderBright++;
      }
      if (luma >= 240) white++;
      else if (luma <= 150) ink++;
      else mid++;
    }
    for (const index of corners) {
      const j = index * 4;
      if (samples[j + 3] >= 248 &&
          Math.min(samples[j], samples[j + 1], samples[j + 2]) >= 240)
        whiteCorners++;
    }
    const count = samples.length / 4;
    // Tiny antialiased divider strokes may fill much of the image, but
    // white-backed ornamental strips retain a pale, nearly continuous rim.
    // This rejects arbitrary grayscale artwork with dark or busy edges.
    const hasLightBorder = borderPixels > 0 &&
      borderWhite >= borderPixels * 0.65 &&
      borderBright >= borderPixels * 0.78 &&
      borderLuma / borderPixels >= 232;
    // On extremely thin chapter rules (Red Rising L03: 125x10), the dark
    // strokes reach all four image edges. Their background is still a large,
    // pale *field* with alternating light gaps, even though no corner is
    // white. Require the distinctive thin geometry, mostly pale pixels,
    // visible dark strokes and a light overall perimeter; this remains
    // separate from photos, maps, lettering, and the regular ornament rules.
    const hasPaleStrip = longDivider && h <= 20 && w / h >= 10 &&
      !!img.closest('h1,h2,h3,h4,[class*="ornament" i],[class*="decoration" i],'
        + '[class*="divider" i],[class*="separator" i]') &&
      white >= count * 0.35 && ink >= count * 0.07 &&
      borderPixels > 0 && borderWhite >= borderPixels * 0.25 &&
      borderLuma / borderPixels >= 195;
    const isMonochromeDivider = longDivider
      ? transparent <= count * 0.01 && color <= count * 0.005 &&
        white >= count * 0.20 && ink >= count * 0.07 &&
        ink <= count * 0.55 && mid <= count * 0.65 &&
        ((whiteCorners >= 3 && hasLightBorder) || hasPaleStrip)
      : whiteCorners >= 3 && transparent <= count * 0.01 &&
        color <= count * 0.005 && white >= count * 0.65 &&
        ink >= count * 0.008 && ink <= count * 0.30 &&
        mid <= count * 0.15;
    if (!isMonochromeDivider) {
      F.decorationRejected.add(img);
      return null;
    }
    // The read at full native resolution also verifies origin-clean canvas.
    const canvas = document.createElement('canvas');
    canvas.width = w;
    canvas.height = h;
    const ctx = canvas.getContext('2d', {willReadFrequently: true});
    if (!ctx) throw new Error('Canvas unavailable');
    ctx.drawImage(originCleanImage || img, 0, 0);
    const sourcePixels = new Uint8ClampedArray(ctx.getImageData(0, 0, w, h).data);
    // Only the pale-strip case needs stronger black-point separation: its
    // scanned JPEG strokes are gray rather than black. Read the light field
    // itself as the alpha matte so a gray edge never becomes a white ribbon.
    const paleField = [];
    if (hasPaleStrip && !hasLightBorder) {
      for (let i = 0; i < samples.length; i += 4) {
        const luma = (samples[i] * 299 + samples[i + 1] * 587 +
          samples[i + 2] * 114) / 1000;
        if (luma >= 230) paleField.push(luma);
      }
    }
    const backgroundLuma = paleField.length >= count * 0.25
      ? paleField.reduce((a, b) => a + b, 0) / paleField.length : 240;
    const entry = {canvas, ctx, w, h, sourcePixels, foreground: null,
      relativeMatte: hasPaleStrip && !hasLightBorder, backgroundLuma};
    F.decorationCache.set(img, entry);
    F.decorationCount++;
    return entry;
  } catch (e) {
    // Reading local file:// pixels is forbidden in WKWebView. The native bridge
    // only returns whitelisted raster images within the active book directory.
    // A failed bridge request is rejected and leaves the original image intact.
    if (!originCleanImage && e && (e.name === 'SecurityError' ||
        /insecure|taint|cross.origin/i.test(String(e))) &&
        F.requestDecorationData(img)) return null;
    F.decorationRejected.add(img);
    return null;
  }
};

F.recolorDecoration = function(img, c){
  if (!c || c.comic || F.decorationRejected.has(img)) return false;
  // Publisher headings may have their own gold color, distinct from the
  // cream body fg. An image nested in that heading inherits its intended
  // text color; match it, including across theme changes.
  const cssColor = img.parentElement ? getComputedStyle(img.parentElement).color : '';
  const cssMatch = /^rgba?\(\s*(\d{1,3})[,\s]+(\d{1,3})[,\s]+(\d{1,3})/i.exec(cssColor);
  const rgb = cssMatch
    ? cssMatch.slice(1, 4).map(Number)
    : (F.themeRGB(cssColor) || F.themeRGB(c.fg));
  if (!rgb) return false;
  const entry = F.decorationCache.get(img) || F.inspectDecoration(img);
  const tintKey = rgb.join(',');
  if (!entry || entry.foreground === tintKey) return false;
  try {
    const output = entry.ctx.createImageData(entry.w, entry.h);
    const dst = output.data, src = entry.sourcePixels;
    for (let i = 0; i < src.length; i += 4) {
      const luma = (src[i] * 299 + src[i + 1] * 587 + src[i + 2] * 114) / 1000;
      const opacity = entry.relativeMatte
        ? Math.max(0, Math.min(1,
            (entry.backgroundLuma - luma) / Math.max(75, entry.backgroundLuma - 130)))
        : (luma >= 240 ? 0 : Math.max(0, (240 - luma) / 240));
      dst[i] = rgb[0];
      dst[i + 1] = rgb[1];
      dst[i + 2] = rgb[2];
      dst[i + 3] = Math.round(src[i + 3] * opacity);
    }
    entry.ctx.putImageData(output, 0, 0);
    const colored = entry.canvas.toDataURL('image/png');
    entry.foreground = tintKey;
    img.src = colored;
    return true;
  } catch (e) {
    F.decorationRejected.add(img);
    return false;
  }
};

F.recolorDecorations = function(c){
  if (!c || c.comic || !document.body || !document.body.querySelectorAll) return;
  for (const img of document.body.querySelectorAll('img')) {
    if (F.decorationCount >= 24 && !F.decorationCache.has(img)) break;
    F.recolorDecoration(img, c);
  }
};

F.geometryKey = function(c){
  return JSON.stringify([width(), window.innerHeight, c.mode, c.columns,
    c.margin, c.comic, c.fontSize, c.font || '', c.lineHeight || 0,
    c.letterSpacing || 0, c.wordSpacing || 0, !!c.bold, !!c.justify]);
};

F.style = function(c){
  F.cfg = c;
  const key = F.geometryKey(c);
  const root = document.documentElement.style;
  if (root && root.setProperty) {
    root.setProperty('--folio-bg', c.bg);
    root.setProperty('--folio-fg', c.fg);
    root.setProperty('--folio-accent', c.accent);
    root.setProperty('--folio-accent-selection', c.accent + '55');
  }
  let st = document.getElementById('folio-style');
  if (!st) { st = document.createElement('style'); st.id = 'folio-style'; (document.head || document.documentElement).appendChild(st); }
  if (F.layoutKey !== key || !st.textContent) st.textContent = F.css(c);
  F.layoutKey = key;
  F.recolorDecorations(c);
};

F.apply = function(c, target, loadID){
  F.ready = false;
  F.visibleAnchor = null;
  F.pendingAnchor = null;
  F.loadID = loadID;
  const version = ++F.layoutVersion;
  F.style(c);
  const done = () => {
    if (version !== F.layoutVersion) return;
    if (target.kind === 'end') F.goEnd();
    else if (target.kind === 'fragment') F.goFragment(target.value);
    else F.goFraction(target.value || 0);
    F.ready = true;
    F.report();
    clearTimeout(anchorTimer);
    F.refreshVisibleAnchor();
    F.post({ type: 'ready' });
  };
  // Font downloads should not indefinitely block an otherwise readable chapter.
  const fonts = document.fonts ? document.fonts.ready.catch(() => {}) : Promise.resolve();
  Promise.race([fonts, new Promise(resolve => setTimeout(resolve, 1000))])
    .then(() => requestAnimationFrame(() => requestAnimationFrame(done)));
};

F.restyle = function(c, preserveCachedAnchor){
  if (!F.ready) { F.style(c); return; }
  const nextKey = F.geometryKey(c);
  const resized = F.viewWidth !== width() || F.viewHeight !== window.innerHeight;
  if (nextKey === F.layoutKey && !resized && !preserveCachedAnchor) {
    // Palette changes must not recreate the CSS column tree or touch scroll.
    F.style(c);
    return;
  }
  const version = ++F.layoutVersion;
  if (!F.pendingAnchor) {
    F.pendingAnchor = (resized || preserveCachedAnchor) && F.visibleAnchor
      ? F.visibleAnchor : F.captureVisibleAnchor();
  }
  F.style(c);
  requestAnimationFrame(() => requestAnimationFrame(() => {
    if (version !== F.layoutVersion) return;
    const anchor = F.pendingAnchor;
    F.pendingAnchor = null;
    F.restoreVisibleAnchor(anchor);
    F.report();
    clearTimeout(anchorTimer);
    F.refreshVisibleAnchor();
    F.paintFallbackHighlights();
    const afterRestoreNavigation = F.navSerial;
    // A newly chosen font can finish loading after the first column layout.
    // Recheck the *same* saved DOM character after fonts settle. A user page
    // turn or newer restyle cancels this correction so it cannot pull them back.
    if (anchor && anchor.node && document.fonts && document.fonts.ready) {
      Promise.resolve(document.fonts.ready).then(() => {
        requestAnimationFrame(() => requestAnimationFrame(() => {
          if (version !== F.layoutVersion || F.navSerial !== afterRestoreNavigation)
            return;
          const rect = F.characterRect(anchor.node, anchor.offset);
          if (rect && F.visibleRect(rect) &&
              (F.paged() || Math.abs(rect.top - anchor.y) < 3)) return;
          F.restoreVisibleAnchor(anchor);
          F.report();
          clearTimeout(anchorTimer);
          F.refreshVisibleAnchor();
        }));
      }).catch(() => {});
    }
  }));
};

F.requestNavigation = function(dir){
  if (!F.ready || F.navPosted) return;
  F.navPosted = true;
  F.post({ type: 'nav', dir: dir });
  setTimeout(() => { F.navPosted = false; }, 450);
};

document.addEventListener('keydown', ev => {
  if (ev.metaKey || ev.ctrlKey || ev.altKey) return;
  if (ev.target.closest && ev.target.closest('input,textarea,select,[contenteditable="true"],[role="textbox"]')) return;
  const fwd = ['ArrowRight', 'PageDown', ' '];
  const back = ['ArrowLeft', 'PageUp'];
  if (F.paged()) { fwd.push('ArrowDown'); back.push('ArrowUp'); }
  if (fwd.includes(ev.key)) { ev.preventDefault(); F.requestNavigation(ev.shiftKey && ev.key === ' ' ? -1 : 1); }
  else if (back.includes(ev.key)) { ev.preventDefault(); F.requestNavigation(-1); }
});

document.addEventListener('click', ev => {
  if (!F.paged() || (ev.target.closest && ev.target.closest('a,button,input,select,textarea,[contenteditable="true"],[role="button"]'))) return;
  if (String(window.getSelection() || '').length) return;
  const x = ev.clientX / width();
  if (x < 0.12) F.requestNavigation(-1);
  else if (x > 0.88) F.requestNavigation(1);
});

let acc = 0, lock = false;
window.addEventListener('wheel', ev => {
  if (!F.paged()) return;
  ev.preventDefault();
  if (lock) return;
  const d = Math.abs(ev.deltaX) > Math.abs(ev.deltaY) ? ev.deltaX : ev.deltaY;
  acc += d;
  if (Math.abs(acc) > 70) { F.requestNavigation(acc > 0 ? 1 : -1); acc = 0; lock = true; setTimeout(() => { lock = false; }, 420); }
}, { passive: false });

let scrollTimer = null;
window.addEventListener('scroll', () => {
  if (F.paged()) { F.paintFallbackHighlights(); return; }
  clearTimeout(scrollTimer);
  scrollTimer = setTimeout(F.report, 120);
});

let resizeTimer = null;
window.addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => { if (F.cfg) F.restyle(F.cfg); }, 120);
});

// Images can finish loading after the initial font/layout pass.
document.addEventListener('load', ev => {
  if (!F.ready || !ev.target || !['IMG', 'VIDEO', 'SVG'].includes(ev.target.tagName)) return;
  if (ev.target.tagName === 'IMG') {
    if (F.decorationCache.has(ev.target)) return; // Our data URL load: no reflow loop.
    F.recolorDecoration(ev.target, F.cfg);
  }
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => F.restyle(F.cfg, true), 80);
}, true);
})();
"""#
}
