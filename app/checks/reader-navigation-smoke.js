#!/usr/bin/env node
// Standalone deterministic smoke check for WKWebView's injected reader script.
// Run: node checks/reader-navigation-smoke.js
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const swift = fs.readFileSync(path.join(__dirname, '..', 'Core', 'ReaderScript.swift'), 'utf8');
const source = swift.match(/#"""\n([\s\S]*?)\n"""#/);
assert(source, 'ReaderScript.source must be present');

function reader({ mode = 'pages', viewport = 1000, height = 700, totalWidth = 2040, totalHeight = 2700 } = {}) {
  const messages = [];
  const events = new Map();
  const timeouts = [];
  const highlights = new Map();
  const append = [];
  let left = 0, top = 0, contentWidth = totalWidth, pageEnd = -1, pageTailCSS = false;
  const scrollingElement = {
    get scrollWidth() { return Math.max(contentWidth, pageTailCSS ? pageEnd + 1 : 0); },
    scrollHeight: totalHeight,
    get scrollLeft() { return left; },
    set scrollLeft(v) { left = Math.max(0, Math.min(this.scrollWidth - viewport, v)); },
    get scrollTop() { return top; },
    set scrollTop(v) { top = Math.max(0, Math.min(totalHeight - height, v)); }
  };
  const documentElement = {
    clientWidth: viewport,
    get scrollWidth() { return scrollingElement.scrollWidth; },
    style: {
      setProperty(name, value) {
        if (name === '--folio-page-end') pageEnd = parseFloat(value);
      }
    },
    appendChild(node) { append.push(node); }
  };
  const textNodes = ['Before ', 'a highlighted phrase', ' and then ', 'a highlighted phrase', ' after (e.g. C++).']
    .map(nodeValue => ({
      nodeValue,
      parentElement: { closest() { return false; } }
    }));
  let style;
  const document = {
    documentElement, scrollingElement,
    body: {
      get scrollWidth() { return contentWidth; },
      scrollHeight: totalHeight,
      contains() { return true; },
      get textContent() { return textNodes.map(n => n.nodeValue).join(''); }
    },
    head: {
      appendChild(node) { style = node; },
    },
    fonts: { ready: Promise.resolve() },
    getElementById(id) {
      if (id === 'folio-style') return style;
      if (id === 'chapter-end') return {
        getBoundingClientRect() { return {left: 2 * viewport + 20 - left}; }
      };
      return null;
    },
    getElementsByName() { return []; },
    createElement(tagName) {
      const node = {
        tagName, id: '', style: {}, children: [],
        setAttribute() {},
        replaceChildren(...elements) { this.children = elements; }
      };
      if (tagName === 'style') {
        let css = '';
        Object.defineProperty(node, 'textContent', {
          get() { return css; },
          set(value) { css = value; pageTailCSS = css.includes('html::after'); }
        });
      }
      return node;
    },
    createTreeWalker() {
      let index = -1;
      return {
        currentNode: null,
        nextNode() {
          index++;
          if (index >= textNodes.length) return false;
          this.currentNode = textNodes[index];
          return true;
        }
      };
    },
    createRange() {
      return {
        setStart(node, offset) { this.start = {node, offset}; },
        setEnd(node, offset) { this.end = {node, offset}; },
        getClientRects() { return []; }
      };
    },
    addEventListener(name, cb) { events.set('document:' + name, cb); }
  };
  const window = {
    innerWidth: viewport, innerHeight: height,
    webkit: {messageHandlers: {folio: {postMessage(m) {messages.push(m); }}}},
    CSS: {highlights},
    getSelection() { return {toString() {return '';}, isCollapsed: true, rangeCount: 0}; },
    addEventListener(name, cb) { events.set('window:' + name, cb); }
  };
  const context = vm.createContext({
    window, document, CSS: window.CSS,
    NodeFilter: {SHOW_TEXT: 4, FILTER_ACCEPT: 1, FILTER_REJECT: 2},
    Highlight: class Highlight {constructor(...ranges) {this.ranges = ranges;}},
    requestAnimationFrame(cb) {cb();},
    setTimeout(cb) {timeouts.push(cb); return timeouts.length;},
    clearTimeout() {},
    console
  });
  vm.runInContext(source[1], context);
  const folio = window.folio;
  const config = {
    mode, margin: 56, columns: false, comic: false, bg: '#fff', fg: '#000',
    accent: '#ab7c32', fontSize: 16, justify: true, bold: false
  };
  return {
    folio, document, messages, events, highlights, config, scrollingElement, textNodes,
    get rawWidth() { return contentWidth; },
    get pageEnd() { return pageEnd; },
    setRawWidth(nextWidth) { contentWidth = nextWidth; },
    async initialize(target = {kind: 'fraction', value: 0}) {
      folio.apply(config, target, 17);
      await new Promise(resolve => setImmediate(resolve));
      assert.equal(folio.ready, true);
      assert.equal(messages.at(-1).type, 'ready');
      assert.equal(messages.at(-1).loadID, 17);
    }
  };
}

(async () => {
  // Raw column overflow ends short of the last full viewport (real WebKit
  // ends 56px short with 56px side margins). A non-flow root tail ensures
  // each page can start at an exact viewport multiple.
  const paged = reader({totalWidth: 2040});
  await paged.initialize();
  assert.match(paged.document.getElementById('folio-style').textContent, /overflow-x:auto/);
  assert.match(paged.document.getElementById('folio-style').textContent, /html::after/,
    'the end-of-track spacer must be outside the book columns');
  assert.doesNotMatch(paged.document.getElementById('folio-style').textContent, /width:auto !important/,
    'column viewport width must not be overridden later in CSS');
  assert.equal(paged.folio.pages, 3);
  assert.equal(paged.scrollingElement.scrollWidth, 3000,
    'partial last column must extend to a full final page, without adding a page');
  assert.equal(paged.folio.navigate(1), true);
  assert.equal(paged.folio.page, 1);
  assert.equal(paged.folio.navigate(1), true);
  assert.equal(paged.scrollingElement.scrollLeft, 2000,
    'final page must not get clamped and shifted right');
  assert.equal(paged.folio.page, 2);
  assert.equal(paged.folio.navigate(1), false, 'end of chapter advances to next chapter');
  assert.equal(paged.folio.navigate(-1), true);
  assert.equal(paged.folio.page, 1);
  assert.equal(paged.scrollingElement.scrollLeft, 1000);
  assert.equal(paged.folio.navigate(-1), true);
  assert.equal(paged.folio.page, 0);
  assert.equal(paged.folio.navigate(-1), false, 'start of chapter returns to previous');
  paged.folio.goFragment('chapter-end');
  assert.equal(paged.scrollingElement.scrollLeft, 2000,
    'fragment/bookmark in the final page must restore without horizontal drift');
  paged.folio.goPage(0);

  const exact = reader({totalWidth: 3000});
  await exact.initialize();
  assert.equal(exact.folio.pages, 3, 'an already aligned chapter has no phantom page');
  exact.folio.goEnd();
  assert.equal(exact.scrollingElement.scrollWidth, 3000);
  assert.equal(exact.scrollingElement.scrollLeft, 2000);
  const single = reader({totalWidth: 1000});
  await single.initialize();
  assert.equal(single.folio.pages, 1);
  assert.equal(single.scrollingElement.scrollWidth, 1000);
  assert.equal(single.folio.navigate(1), false);

  const narrow = reader({totalWidth: 1030});
  await narrow.initialize();
  assert.equal(narrow.folio.navigate(1), true);
  assert.equal(narrow.folio.page, 1, 'last page shorter than half viewport is still visible');
  assert.equal(narrow.scrollingElement.scrollLeft, 1000,
    'a 30px-wide final passage must retain the correct left margin');
  assert.equal(narrow.folio.navigate(1), false);

  // A two-column spread can finish with an incomplete right column; keep
  // the spread width, not the final text box width, as the scrolling step.
  const spreads = reader({viewport: 1200, totalWidth: 3544});
  spreads.config.columns = true;
  await spreads.initialize();
  assert.equal(spreads.folio.pages, 3);
  assert.equal(spreads.scrollingElement.scrollWidth, 3600);
  assert.equal(spreads.folio.goEnd(), undefined);
  assert.equal(spreads.scrollingElement.scrollLeft, 2400);
  assert.equal(spreads.folio.navigate(1), false);
  assert.equal(spreads.folio.navigate(-1), true);
  assert.equal(spreads.scrollingElement.scrollLeft, 1200);
  // A short partial spread still counts as exactly two pages.
  const halfSpread = reader({viewport: 1200, totalWidth: 1780});
  halfSpread.config.columns = true;
  await halfSpread.initialize();
  assert.equal(halfSpread.folio.pages, 2);
  assert.equal(halfSpread.scrollingElement.scrollWidth, 2400);
  halfSpread.folio.goEnd();
  assert.equal(halfSpread.scrollingElement.scrollLeft, 1200);

  // Bookmark/fraction restores must resolve to an aligned page, including
  // when the bookmark points to the end of a chapter.
  paged.folio.goFraction(0.99);
  assert.equal(paged.scrollingElement.scrollLeft, 2000);
  paged.folio.goFraction(0.34);
  assert.equal(paged.scrollingElement.scrollLeft, 1000);

  // Font/layout reflow changes intrinsic overflow. The root must track the
  // *new* content extent, not a stale spacer from the previous pagination.
  paged.setRawWidth(1470);
  paged.folio.restyle({...paged.config, fontSize: 18});
  assert.equal(paged.folio.pages, 2, 'smaller chapter content must remove old pages');
  assert.equal(paged.scrollingElement.scrollWidth, 2000);
  paged.folio.goEnd();
  assert.equal(paged.scrollingElement.scrollLeft, 1000);
  paged.setRawWidth(3480);
  paged.folio.restyle({...paged.config, fontSize: 20});
  assert.equal(paged.folio.pages, 4, 'grown content must extend the root track');
  assert.equal(paged.scrollingElement.scrollWidth, 4000);
  paged.folio.goEnd();
  assert.equal(paged.scrollingElement.scrollLeft, 3000);
  assert.equal(paged.folio.navigate(1), false);

  const scroll = reader({mode: 'scroll', totalHeight: 1800});
  await scroll.initialize();
  assert.doesNotMatch(scroll.document.getElementById('folio-style').textContent, /html::after/,
    'scroll mode must not have a pagination tail');
  let turns = 0;
  while (scroll.folio.navigate(1) && turns < 10) turns++;
  assert(turns > 0 && turns < 10);
  assert.equal(scroll.scrollingElement.scrollTop, 1100);
  assert.equal(scroll.folio.navigate(1), false);
  while (scroll.folio.navigate(-1)) { /* Traverse back. */ }
  assert.equal(scroll.scrollingElement.scrollTop, 0);

  // All event sources request the same serialized native navigation path.
  paged.events.get('document:keydown')({
    key: 'ArrowRight', metaKey: false, ctrlKey: false, altKey: false,
    shiftKey: false, target: {closest() {return false;}}, preventDefault() {}
  });
  assert.equal(paged.messages.at(-1).type, 'nav');
  assert.equal(paged.messages.at(-1).dir, 1);
  paged.folio.navigate(1);
  paged.events.get('document:click')({
    clientX: 15, target: {closest() {return false;}}
  });
  assert.equal(paged.messages.at(-1).dir, -1);
  paged.folio.navigate(-1);
  let wheelCancelled = false;
  paged.events.get('window:wheel')({
    deltaX: 0, deltaY: 85,
    preventDefault() {wheelCancelled = true;}
  });
  assert.equal(wheelCancelled, true);
  assert.equal(paged.messages.at(-1).type, 'nav');
  assert.equal(paged.messages.at(-1).dir, 1);

  // Replacing highlights must never modify EPUB text or pagination.
  const textBefore = paged.document.body.textContent;
  const beforePages = paged.folio.pages;
  assert.equal(paged.folio.highlightAnnotations([
    {text: 'a highlighted phrase', prefix: 'Before ', suffix: ' and then '}
  ]), 1);
  assert.equal(paged.highlights.get('folio-annotations').ranges.length, 1);
  assert.equal(paged.highlights.get('folio-annotations').ranges[0].start.node, paged.textNodes[1],
    'anchor context chooses the intended occurrence of repeated text');
  assert.equal(paged.folio.highlightAnnotations(['and then']), 1);
  assert.equal(paged.folio.highlightAnnotations(['(e.g. C++).']), 1,
    'punctuation must not become active regular expression syntax');
  assert.equal(paged.folio.highlightAnnotations([]), 0);
  assert.equal(paged.highlights.has('folio-annotations'), false);
  assert.equal(paged.document.body.textContent, textBefore);
  assert.equal(paged.folio.pages, beforePages);

  console.log('Reader navigation smoke passed (paged, short final page, previous, scroll, keyboard/click, highlights).');
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
