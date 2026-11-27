#!/usr/bin/env node
// Deterministic text layout + canvas fixture for Folio's injected WKWebView JS.
// Run: node checks/reader-appearance-smoke.js
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const swift = fs.readFileSync(
  path.join(__dirname, '..', 'Core', 'ReaderScript.swift'), 'utf8');
const source = swift.match(/#"""\n([\s\S]*?)\n"""#/);
assert(source, 'ReaderScript.source was not found');

function fixture({images = [], placeChar = null, text = Array.from({length: 6},
  (_, i) => 'Section ' + i + ' ' + ('Text content continues through the passage. '.repeat(26)))} = {}) {
  const events = new Map(), timers = new Map(), highlights = new Map();
  let timerID = 0, viewport = 950, height = 600, left = 0, top = 0;
  let activeConfig = null, style = null, latestPixels = null, styleWrites = 0;
  let scrollLeftWrites = 0, scrollTopWrites = 0;
  const cssVariables = new Map();
  const nodes = text.map(nodeValue => ({
    nodeValue, isConnected: true, parentElement: {closest() {return null;}}
  }));
  const boundaries = nodes.map((node, index) =>
    nodes.slice(0, index).reduce((sum, n) => sum + n.nodeValue.length, 0));
  const totalLength = nodes.reduce((sum, n) => sum + n.nodeValue.length, 0);
  const dimensions = () => {
    const cfg = activeConfig || {mode: 'pages', fontSize: 16, margin: 50};
    const charWidth = cfg.fontSize * 0.57, lineHeight = cfg.fontSize * 1.45;
    const perLine = Math.max(10, Math.floor((viewport - cfg.margin * 2) / charWidth));
    const perPage = Math.max(perLine, perLine *
      Math.max(2, Math.floor((height - cfg.margin * 2) / lineHeight)));
    const pageCount = Math.max(1, Math.ceil(totalLength / perPage));
    const lines = Math.ceil(totalLength / perLine);
    return {cfg, charWidth, lineHeight, perLine, perPage,
      scrollWidth: pageCount * viewport,
      scrollHeight: height + lines * lineHeight,
      pageCount};
  };
  const scrollingElement = {
    get scrollWidth() {return dimensions().scrollWidth;},
    get scrollHeight() {return dimensions().scrollHeight;},
    get scrollLeft() {return left;},
    set scrollLeft(value) {
      scrollLeftWrites++;
      left = Math.max(0, Math.min(dimensions().scrollWidth - viewport, value));
    },
    get scrollTop() {return top;},
    set scrollTop(value) {
      scrollTopWrites++;
      top = Math.max(0, Math.min(dimensions().scrollHeight - height, value));
    }
  };
  function location(globalIndex) {
    const d = dimensions();
    let page = 0, line = 0, column = 0;
    if (d.cfg.mode === 'pages') {
      page = Math.floor(globalIndex / d.perPage);
      const within = globalIndex % d.perPage;
      line = Math.floor(within / d.perLine);
      column = within % d.perLine;
    } else {
      line = Math.floor(globalIndex / d.perLine);
      column = globalIndex % d.perLine;
    }
    const x = page * viewport + d.cfg.margin + column * d.charWidth - left;
    const y = d.cfg.margin + line * d.lineHeight -
      (d.cfg.mode === 'scroll' ? top : 0);
    const rect = {left: x, right: x + d.charWidth,
      top: y, bottom: y + d.lineHeight, width: d.charWidth, height: d.lineHeight};
    return placeChar ? (placeChar(globalIndex, rect, {viewport, height, nodes, boundaries}) || rect) : rect;
  }
  const globalIndexOf = (node, offset) => boundaries[nodes.indexOf(node)] + offset;
  function fakeRange() {
    let startNode, startOffset = 0, endNode, endOffset = 0;
    return {
      selectNodeContents(node) {
        startNode = endNode = node;
        startOffset = 0;
        endOffset = node.nodeValue.length;
      },
      setStart(node, offset) {startNode = node; startOffset = offset;},
      setEnd(node, offset) {endNode = node; endOffset = offset;},
      getClientRects() {
        if (!startNode || !endNode) return [];
        const start = globalIndexOf(startNode, startOffset);
        const end = globalIndexOf(endNode, endOffset);
        const chars = Array.from({length: Math.max(0, end - start)},
          (_, index) => location(start + index));
        // A real WebKit Range that selects a text node returns one fragment
        // rectangle per physical line, even if the text spans many columns.
        if (startNode === endNode && startOffset === 0 &&
            endOffset === startNode.nodeValue.length) {
          const lines = [];
          for (const char of chars) {
            const last = lines.at(-1);
            if (last && Math.abs(last.top - char.top) < 1 &&
                char.left >= last.left && char.left - last.right < 2) {
              last.right = Math.max(last.right, char.right);
              last.width = last.right - last.left;
            } else {
              lines.push({...char});
            }
          }
          return lines;
        }
        return chars;
      }
    };
  }
  function fakeCanvas() {
    const canvas = {width: 0, height: 0, toDataURL() {
      return 'data:image/png;base64,icon-' + ++canvas.version;
    }, version: 0};
    const ctx = {
      pixels: null, output: null,
      drawImage(img) {
        const data = new Uint8ClampedArray(canvas.width * canvas.height * 4);
        for (let y = 0; y < canvas.height; y++) {
          for (let x = 0; x < canvas.width; x++) {
            const ix = Math.min(img.naturalWidth - 1,
              Math.floor(x * img.naturalWidth / canvas.width));
            const iy = Math.min(img.naturalHeight - 1,
              Math.floor(y * img.naturalHeight / canvas.height));
            data.set(img.testPixels.slice(4 * (iy * img.naturalWidth + ix),
              4 * (iy * img.naturalWidth + ix) + 4), (y * canvas.width + x) * 4);
          }
        }
        ctx.pixels = data;
      },
      getImageData() {
        if (ctx.throwSecurity) throw new Error('SecurityError: tainted canvas');
        return {data: ctx.pixels};
      },
      createImageData(w, h) {
        return {data: new Uint8ClampedArray(w * h * 4)};
      },
      putImageData(output) {ctx.output = output.data; latestPixels = output.data;}
    };
    canvas.getContext = () => ctx;
    Object.defineProperty(ctx, 'throwSecurity', {
      get() {return images.some(img => img.tainted && !img.converted);}
    });
    return canvas;
  }
  const document = {
    documentElement: {
      get clientWidth() {return viewport;},
      get scrollWidth() {return dimensions().scrollWidth;},
      style: {setProperty(key, value) {cssVariables.set(key, value);}},
      appendChild() {}
    },
    body: {
      get scrollWidth() {return dimensions().scrollWidth;},
      get scrollHeight() {return dimensions().scrollHeight;},
      contains(node) {return nodes.includes(node);},
      querySelectorAll(query) {return query === 'img' ? images : [];}
    },
    scrollingElement,
    head: {appendChild(node) {style = node;}},
    fonts: {ready: Promise.resolve()},
    addEventListener(name, callback) {events.set(name, callback);},
    getElementById(name) {return name === 'folio-style' ? style : null;},
    createElement(name) {
      if (name === 'canvas') return fakeCanvas();
      const element = {
        id: '', style: {}, textContent: '', children: [],
        appendChild() {},
        setAttribute() {},
        replaceChildren(...children) {this.children = children;}
      };
      if (name === 'style') {
        Object.defineProperty(element, 'textContent', {
          get() {return element.css || '';},
          set(v) {element.css = v; activeConfig = window.folio.cfg; styleWrites++;}
        });
      }
      return element;
    },
    createTreeWalker() {
      let index = -1;
      return {
        get currentNode() {return nodes[index];},
        nextNode() {return ++index < nodes.length;}
      };
    },
    createRange: fakeRange,
    caretRangeFromPoint(x, y) {
      const d = dimensions();
      const column = Math.max(0, Math.min(d.perLine - 1,
        Math.floor((x + left - (d.cfg.mode === 'pages'
          ? Math.floor((x + left) / viewport) * viewport : 0) -
          d.cfg.margin) / d.charWidth)));
      const line = Math.max(0, Math.floor((y +
        (d.cfg.mode === 'scroll' ? top : 0) - d.cfg.margin) / d.lineHeight));
      const page = d.cfg.mode === 'pages' ? Math.floor((x + left) / viewport) : 0;
      const globalIndex = Math.min(totalLength - 1, page * d.perPage +
        line * d.perLine + column);
      const index = Math.max(0, boundaries.findLastIndex(start => start <= globalIndex));
      return {startContainer: nodes[index],
        startOffset: globalIndex - boundaries[index]};
    }
  };
  const window = {
    get innerWidth() {return viewport;},
    get innerHeight() {return height;},
    webkit: {messageHandlers: {folio: {postMessage() {}}}},
    getSelection() {return {toString() {return ''}, isCollapsed: true, rangeCount: 0};},
    addEventListener(name, callback) {events.set(name, callback);},
    CSS: {highlights}
  };
  const context = vm.createContext({
    window, document, CSS: window.CSS, NodeFilter: {SHOW_TEXT: 4},
    Highlight: class Highlight {},
    requestAnimationFrame(cb) {cb();},
    setTimeout(cb, delay = 0) {
      const id = ++timerID;
      timers.set(id, {cb, delay});
      return id;
    },
    clearTimeout(id) {timers.delete(id);},
    Uint8ClampedArray,
    console
  });
  vm.runInContext(source[1], context);
  const folio = window.folio;
  const config = {
    mode: 'pages', margin: 50, fontSize: 16, bg: '#F4E8D3', fg: '#4A3B2A',
    accent: '#8A5A20', comic: false, columns: false, justify: true
  };
  return {
    folio, document, nodes, events, scrollingElement, config, dimensions, location,
    get styleWrites() {return styleWrites;},
    get scrollWrites() {return [scrollLeftWrites, scrollTopWrites];},
    cssVariables,
    get pixels() {return latestPixels;},
    resize(w, h = height) {viewport = w; height = h;},
    simulateFontReflow(c) {activeConfig = c;},
    async initialize(c = config) {
      activeConfig = c;
      folio.apply(c, {kind: 'fraction', value: 0}, 123);
      await new Promise(resolve => setImmediate(resolve));
      assert.equal(folio.ready, true);
    },
    restyle(c) {folio.restyle(c);},
    visible(node, offset) {
      const r = location(globalIndexOf(node, offset));
      return Math.min(viewport, r.right) - Math.max(0, r.left) >= 2 &&
        Math.min(height, r.bottom) - Math.max(0, r.top) >= 2;
    },
    flushTimers() {
      const due = [...timers].sort((a, b) => a[1].delay - b[1].delay);
      for (const [id, task] of due) {
        if (!timers.has(id)) continue;
        timers.delete(id);
        task.cb();
      }
    }
  };
}

function image(name, type = 'ornament') {
  const w = 40, h = 40;
  const pixels = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const index = (y * w + x) * 4;
      let color = x >= 16 && x < 24 && y >= 8 && y < 32 ? 0 : 255;
      if (type === 'gray') color = Math.round(x / w * 200 + 30);
      if (type === 'photo') color = 120;
      pixels[index] = type === 'photo' ? 244 : color;
      pixels[index + 1] = type === 'photo' ? 30 : color;
      pixels[index + 2] = type === 'photo' ? 65 : color;
      pixels[index + 3] = 255;
    }
  }
  return {
    tagName: 'IMG', naturalWidth: w, naturalHeight: h, complete: true,
    testPixels: pixels, src: name, currentSrc: name, converted: false,
    getBoundingClientRect() {return {width: 40, height: 40};},
    getAttribute(field) {
      return field === 'src' ? name : field === 'alt' ? type : '';
    },
    hasAttribute() {return false;},
    closest() {return null;}
  };
}

(async () => {
  const reader = fixture();
  await reader.initialize();
  assert(reader.folio.visibleAnchor.node, 'chapter ready captures a DOM text anchor');
  reader.folio.goPage(2);
  reader.folio.refreshVisibleAnchor();
  const first = reader.folio.visibleAnchor;
  assert(first.node && reader.visible(first.node, first.offset),
    'first text character must be genuinely visible before restyle');
  assert(first.offset > 0, 'anchor stores the actual visible character within a long text node');
  assert.equal(first.y, reader.location(
    reader.nodes.slice(0, reader.nodes.indexOf(first.node))
      .reduce((length, node) => length + node.nodeValue.length, 0) + first.offset).top,
    'anchor vertical offset belongs to the character, not a paragraph rectangle');

  // Pure palette changes must not rebuild WebKit's column stylesheet or
  // trigger a single scroll assignment. This was the real theme-jump cause.
  const writesBeforeTheme = reader.styleWrites;
  const scrollBeforeTheme = reader.scrollWrites;
  const versionBeforeTheme = reader.folio.layoutVersion;
  const pageBeforeTheme = reader.folio.page;
  const pageCountBeforeTheme = reader.folio.pages;
  const firstGlyphIndex = reader.nodes.slice(0, reader.nodes.indexOf(first.node))
    .reduce((count, node) => count + node.nodeValue.length, 0) + first.offset;
  const exactGlyphBeforeTheme = reader.location(firstGlyphIndex);
  reader.restyle({...reader.config, bg: '#121212', fg: '#E3E3E5', accent: '#6FB0FF'});
  assert.equal(reader.styleWrites, writesBeforeTheme,
    'palette-only changes must leave folio-style textContent untouched');
  assert.deepEqual(reader.scrollWrites, scrollBeforeTheme,
    'palette-only changes must not scroll or repaginate');
  assert.equal(reader.folio.layoutVersion, versionBeforeTheme);
  assert.equal(reader.folio.page, pageBeforeTheme);
  assert.equal(reader.folio.pages, pageCountBeforeTheme);
  assert.deepEqual(reader.location(firstGlyphIndex), exactGlyphBeforeTheme,
    'appearance dark/light switch must preserve the exact glyph x and y');
  assert.equal(reader.cssVariables.get('--folio-bg'), '#121212');
  assert.equal(reader.cssVariables.get('--folio-fg'), '#E3E3E5');
  assert.equal(reader.cssVariables.get('--folio-accent'), '#6FB0FF');
  assert(reader.visible(first.node, first.offset), 'theme-only switch preserves the exact glyph');
  reader.restyle({...reader.config, bg: '#EEEBE4', fg: '#2A2926', accent: '#7A5C2E'});
  assert.equal(reader.styleWrites, writesBeforeTheme);
  assert.deepEqual(reader.scrollWrites, scrollBeforeTheme);
  assert.equal(reader.folio.page, pageBeforeTheme);
  assert.deepEqual(reader.location(firstGlyphIndex), exactGlyphBeforeTheme,
    'theme swatch with unchanged font keeps exact page position and glyph rect');

  const dense = {...reader.config, fontSize: 26, margin: 70, fg: '#E8D9C0', bg: '#3A3127'};
  reader.restyle(dense);
  assert(reader.visible(first.node, first.offset),
    'same DOM character remains visible after font, margins and colors change');
  assert(reader.folio.page > 0, 'restyle retains a passage deep in the chapter');
  const changedMode = {...dense, mode: 'scroll'};
  reader.restyle(changedMode);
  assert(reader.visible(first.node, first.offset),
    'anchor remains visible switching from pages to continuous scrolling');
  const scrollAnchor = reader.folio.captureVisibleAnchor();
  reader.restyle({...changedMode, mode: 'pages'});
  assert(reader.visible(scrollAnchor.node, scrollAnchor.offset),
    'first actually visible scroll text remains visible switching back to pages');
  const beforeResize = reader.folio.captureVisibleAnchor();
  reader.resize(700);
  reader.restyle({...dense, margin: 52});
  assert(reader.visible(beforeResize.node, beforeResize.offset),
    'cached anchor survives a window resize before the resize event fires');
  reader.folio.goEnd();
  reader.folio.refreshVisibleAnchor();
  const ending = reader.folio.visibleAnchor;
  reader.restyle({...dense, fontSize: 19});
  assert(reader.visible(ending.node, ending.offset),
    'last passage text remains visible when total pagination shrinks');
  let traversals = 0;
  while (reader.folio.navigate(1) && traversals++ < 20) {}
  assert(traversals < 20);
  assert.equal(reader.folio.navigate(1), false,
    'end of passage still crosses the chapter boundary correctly');

  // EPUB DOM order need not match rendered viewport order (floats, positioned
  // headings, CSS columns). The earliest visible visual line is the anchor.
  const placed = fixture({
    text: ['Earlier DOM, visually lower.', 'Later DOM, visually first.'],
    placeChar(index, rect, {boundaries}) {
      const top = rect.top + (index < boundaries[1] ? 310 : 20);
      return {...rect, top, bottom: top + rect.height};
    }
  });
  await placed.initialize();
  assert.equal(placed.folio.captureVisibleAnchor().node, placed.nodes[1],
    'choose topmost visible text rather than first DOM text node');

  const columns = fixture({
    text: ['Right column has higher line.', 'Left column has later DOM text.'],
    placeChar(index, rect, {boundaries}) {
      const rightColumn = index < boundaries[1];
      const left = (rightColumn ? 700 : 120) + (index - (rightColumn ? 0 : boundaries[1])) * 4;
      const top = rect.top + (rightColumn ? 5 : 100);
      return {...rect, left, right: left + rect.width, top, bottom: top + rect.height};
    }
  });
  columns.resize(1200);
  await columns.initialize({...columns.config, columns: true});
  assert.equal(columns.folio.captureVisibleAnchor().node, columns.nodes[1],
    'the left column must win over an earlier-y right column');

  // In continuous scroll mode the exact character's vertical screen offset
  // is recoverable, unlike a fixed-height CSS-column page.
  const vertical = fixture();
  await vertical.initialize({...vertical.config, mode: 'scroll'});
  vertical.scrollingElement.scrollTop = 800;
  vertical.folio.refreshVisibleAnchor();
  const verticalAnchor = vertical.folio.visibleAnchor;
  const verticalScrollBeforeTheme = vertical.scrollingElement.scrollTop;
  const verticalStylesBeforeTheme = vertical.styleWrites;
  vertical.restyle({...vertical.config, mode: 'scroll', bg: '#121212', fg: '#E3E3E5'});
  assert.equal(vertical.scrollingElement.scrollTop, verticalScrollBeforeTheme);
  assert.equal(vertical.styleWrites, verticalStylesBeforeTheme);
  const taller = {...vertical.config, mode: 'scroll', fontSize: 23, margin: 64};
  vertical.restyle(taller);
  const globalOffset = vertical.nodes.slice(0, vertical.nodes.indexOf(verticalAnchor.node))
    .reduce((count, node) => count + node.nodeValue.length, 0) + verticalAnchor.offset;
  assert(Math.abs(vertical.location(globalOffset).top - verticalAnchor.y) <= 2,
    'scrolling layout restores the same glyph to the same y after typography changes');

  // Font activation may reflow content after the initial two animation frames.
  // The delayed font-ready correction must reuse the ORIGINAL glyph anchor.
  const lateFont = fixture();
  await lateFont.initialize({...lateFont.config, mode: 'scroll'});
  lateFont.scrollingElement.scrollTop = 650;
  lateFont.folio.refreshVisibleAnchor();
  const preserved = lateFont.folio.visibleAnchor;
  const glyphIndex = lateFont.nodes.slice(0, lateFont.nodes.indexOf(preserved.node))
    .reduce((count, node) => count + node.nodeValue.length, 0) + preserved.offset;
  let finishFontLoad;
  lateFont.document.fonts.ready = new Promise(resolve => {finishFontLoad = resolve;});
  lateFont.restyle({...lateFont.config, mode: 'scroll', fontSize: 21});
  lateFont.simulateFontReflow({...lateFont.config, mode: 'scroll', fontSize: 29});
  finishFontLoad();
  await new Promise(resolve => setImmediate(resolve));
  assert(Math.abs(lateFont.location(glyphIndex).top - preserved.y) <= 2,
    'late font reflow must bring the same text back to its original vertical position');

  // Image intrinsic dimensions can also settle after the first layout. Their
  // load event invokes the cached-anchor restyle instead of capturing text
  // from an already shifted viewport.
  const lateImage = fixture();
  await lateImage.initialize({...lateImage.config, mode: 'scroll'});
  lateImage.scrollingElement.scrollTop = 720;
  lateImage.folio.refreshVisibleAnchor();
  const imgAnchor = lateImage.folio.visibleAnchor;
  const imgIndex = lateImage.nodes.slice(0, lateImage.nodes.indexOf(imgAnchor.node))
    .reduce((count, node) => count + node.nodeValue.length, 0) + imgAnchor.offset;
  lateImage.simulateFontReflow({...lateImage.config, mode: 'scroll', fontSize: 24});
  lateImage.events.get('load')({target: {tagName: 'VIDEO'}});
  lateImage.flushTimers();
  assert(Math.abs(lateImage.location(imgIndex).top - imgAnchor.y) <= 2,
    'late media reflow restores the cached text glyph');

  const ornament = image('ornament.svg'), photo = image('photo.png', 'photo'),
    gray = image('gray.png', 'gray'), cover = image('cover.png');
  const art = fixture({images: [ornament, photo, gray, cover]});
  await art.initialize();
  assert.match(ornament.src, /^data:image\/png;base64,/,
    'canvas recolors the black-on-white ornamental SVG');
  assert.equal(photo.src, 'photo.png', 'color photography is not changed');
  assert.equal(gray.src, 'gray.png', 'grayscale photography is not changed');
  assert.equal(cover.src, 'cover.png', 'cover art is not changed');
  const firstColor = [...art.pixels.slice((20 * 40 + 20) * 4, (20 * 40 + 20) * 4 + 4)];
  assert.deepEqual(firstColor, [74, 59, 42, 255],
    'black ink becomes the exact theme foreground');
  const white = [...art.pixels.slice(0, 4)];
  assert.equal(white[3], 0, 'opaque white rectangular background becomes transparent');
  const formerSrc = ornament.src;
  art.restyle({...art.config, bg: '#121212', fg: '#E3E3E5'});
  assert.notEqual(ornament.src, formerSrc, 'light to dark theme recolors cached source');
  const darkInk = [...art.pixels.slice((20 * 40 + 20) * 4, (20 * 40 + 20) * 4 + 4)];
  assert.deepEqual(darkInk, [227, 227, 229, 255]);
  const version = art.folio.layoutVersion;
  art.events.get('load')({target: ornament});
  assert.equal(art.folio.layoutVersion, version, 'recolored image load cannot loop into restyle');
  const comic = fixture({images: [image('comic-ornament.svg')]});
  await comic.initialize({...comic.config, comic: true});
  assert.equal(comic.document.body.querySelectorAll('img')[0].src, 'comic-ornament.svg',
    'comic mode never recolors artwork');

  console.log('Reader appearance smoke passed (viewport line geometry, exact glyph/y, palette no-reflow, columns, font/margins/modes/resize/end, late font/media, ornament/photo/cover/comic).');
})().catch(error => {console.error(error); process.exitCode = 1;});
