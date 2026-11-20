#!/usr/bin/env node
// Tests the real Red Rising EPUB's long, antialiased chapter divider in WKWebView.
// Uses the existing native bridge test harness in a temporary directory; never
// modifies the installed book or any app files.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

if (process.platform !== 'darwin') {
  console.log('SKIP: divider WebKit smoke needs macOS.');
  process.exit(0);
}

const project = path.resolve(__dirname, '..');
const library = path.join(os.homedir(), 'Library/Application Support/Folio/Extracted');
const redRisingChapter = 'OEBPS/Brow_9780345539793_epub_p01_r1.htm';
const redRisingGift = 'OEBPS/Brow_9780345539793_epub_c04_r1.htm';
const redRisingArt = 'OEBPS/Brow_9780345539793_epub_ata_r1.htm';
const redRisingMap = 'OEBPS/Brow_9780345539793_epub_map_r1.htm';
const locate = (relative, textMatch) => {
  if (!fs.existsSync(library)) return null;
  for (const dir of fs.readdirSync(library)) {
    const candidate = path.join(library, dir, relative);
    if (fs.existsSync(candidate) &&
        (!textMatch || fs.readFileSync(candidate, 'utf8').includes(textMatch))) {
      return candidate;
    }
  }
  return null;
};

const chapter = locate(redRisingChapter, 'There is a flower that grows on Mars');
if (!chapter) {
  console.log('SKIP: installed Red Rising chapter is unavailable; run on a Folio test library containing the book.');
  process.exit(0);
}
const chapterMarkup = fs.readFileSync(chapter, 'utf8');
assert.match(chapterMarkup,
  /<h1 class="part1"><img alt="" src="images\/Brow_9780345539793_epub_L02_r1\.jpg"/);
const dividerPath = path.join(path.dirname(chapter), 'images/Brow_9780345539793_epub_L02_r1.jpg');
assert.ok(fs.existsSync(dividerPath), 'actual divider JPEG exists');
const gift = locate(redRisingGift, 'THE GIFT');
assert.ok(gift, 'installed Red Rising chapter 4 THE GIFT exists');
assert.match(fs.readFileSync(gift, 'utf8'),
  /<h1 class="chapter1"><img alt="" src="images\/Brow_9780345539793_epub_L03_r1\.jpg"/);
assert.ok(fs.existsSync(path.join(path.dirname(gift),
  'images/Brow_9780345539793_epub_L03_r1.jpg')), 'actual chapter 4 divider JPEG exists');

const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'folio-divider-smoke-'));
try {
  const swift = path.join(temp, 'reader-divider-live.swift');
  const binary = path.join(temp, 'reader-divider-live');
  let harness = fs.readFileSync(path.join(__dirname, 'reader-webkit-live.swift'), 'utf8');
  assert.ok(harness.includes("document.querySelector('img.orn')"), 'expected reader diagnostic');
  assert.ok(harness.includes('transparent > total * 60 / 100'), 'expected pixel assertion');
  // The divider's antialiased strokes are partially transparent. Inspect
  // actual inherited heading color, which can be gold when body fg is cream.
  harness = harness
    .replaceAll("document.querySelector('img.orn')", "document.querySelector('img')")
    .replace('transparent > total * 60 / 100', 'transparent > total * 25 / 100')
    .replace(/let fg=\[[\s\S]*?\];/,
      'let fg=getComputedStyle(img.parentElement).color.match(/\\d+/g).slice(0,3).map(Number);')
    .replace('rect:r,original:o,canvasError,imageStats,',
      'rect:r,original:o,canvasError,imageStats,headingInk:getComputedStyle(img.parentElement).color,'
      + ' nearbyHeading:document.querySelector("h1.subchapter1")'
      + ' ? getComputedStyle(document.querySelector("h1.subchapter1")).color : null,')
    // Exercise a divider rendered wider than the original 260px cutoff.
    .replace(
      'window.requestAnimationFrame=(callback)=>setTimeout(callback,0); folio.apply(',
      "window.requestAnimationFrame=(callback)=>setTimeout(callback,0); document.querySelector('img').style.width='320px'; folio.apply("
    );
  fs.writeFileSync(swift, harness);
  execFileSync('swiftc', [
    '-swift-version', '5', '-framework', 'AppKit', '-framework', 'WebKit',
    '-framework', 'ImageIO', swift, '-o', binary
  ], { cwd: project, stdio: 'pipe', timeout: 30000 });

  const run = (file, extra = [], executable = binary) => execFileSync(executable, [file, ...extra], {
    cwd: project, encoding: 'utf8', timeout: 20000,
    maxBuffer: 1024 * 1024
  });
  const actual = run(chapter);
  assert.match(actual, /bridge accepted Brow_9780345539793_epub_L02_r1\.jpg 156x16/);
  assert.match(actual, /"width" : 320/, 'rendered wide divider survives geometry test');
  assert.match(actual, /palette-only:[\s\S]*?"canvasError" : null/);
  assert.match(actual, /palette-only:[\s\S]*?"cached" : true/);
  assert.match(actual, /palette-only:[\s\S]*?"rejected" : false/);
  assert.match(actual, /palette-only:[\s\S]*?"transparent" : (\d+)/);
  assert.match(actual, /font\+theme:[\s\S]*?"matchingInk" : (\d+)/);
  console.log('PASS: real 156×16 Red Rising PART I divider, displayed 320px wide, transparent and heading-colored across appearance changes.');

  const giftOutput = run(gift);
  assert.match(giftOutput, /bridge accepted Brow_9780345539793_epub_L03_r1\.jpg 125x10/);
  assert.match(giftOutput, /"width" : 320/, 'chapter 4 rule renders at 320px');
  assert.match(giftOutput, /palette-only:[\s\S]*?"canvasError" : null/);
  assert.match(giftOutput, /palette-only:[\s\S]*?"cached" : true/);
  assert.match(giftOutput, /palette-only:[\s\S]*?"rejected" : false/);
  assert.match(giftOutput, /palette-only:[\s\S]*?"transparent" : ([1-9]\d*)/);
  assert.match(giftOutput, /font\+theme:[\s\S]*?"matchingInk" : ([1-9]\d*)/);
  assert.match(giftOutput, /"headingInk" : "rgb\(229, 197, 90\)"/);
  assert.match(giftOutput, /"nearbyHeading" : "rgb\(229, 197, 90\)"/);
  console.log('PASS: real 125×10 Red Rising THE GIFT divider, displayed 320px wide, translucent gray strokes transformed into gold heading ink with no white strip.');

  // Exercise a light reader palette with the same exact EPUB image and
  // verify all opaque pixels again match the computed chapter-title color.
  const lightSource = harness
    .replace('"bg": "#27251C", "fg": "#EDE5C8"', '"bg": "#FFFAE9", "fg": "#2D2A1F"')
    .replace('"accent": "#E5C55A"', '"accent": "#8C6D12"')
    .replace('next["fg"] = "#E8D9C0"', 'next["fg"] = "#303030"')
    .replace('next["bg"] = "#3A3127"', 'next["bg"] = "#FFFFFF"')
    .replace('next["bg"] = "#2C2B29"', 'next["bg"] = "#F4E8D3"')
    .replace('next["fg"] = "#D9D5CC"', 'next["fg"] = "#4A3B2A"');
  const lightSwift = path.join(temp, 'reader-divider-light.swift');
  const lightBinary = path.join(temp, 'reader-divider-light');
  fs.writeFileSync(lightSwift, lightSource);
  execFileSync('swiftc', [
    '-swift-version', '5', '-framework', 'AppKit', '-framework', 'WebKit',
    '-framework', 'ImageIO', lightSwift, '-o', lightBinary
  ], { cwd: project, stdio: 'pipe', timeout: 30000 });
  const lightOutput = run(gift, [], lightBinary);
  assert.match(lightOutput, /bridge accepted Brow_9780345539793_epub_L03_r1\.jpg 125x10/);
  assert.match(lightOutput, /palette-only:[\s\S]*?"canvasError" : null/);
  assert.match(lightOutput, /palette-only:[\s\S]*?"cached" : true/);
  assert.match(lightOutput, /font\+theme:[\s\S]*?"matchingInk" : ([1-9]\d*)/);
  assert.match(lightOutput, /"headingInk" : "rgb\(140, 109, 18\)"/);
  assert.match(lightOutput, /"nearbyHeading" : "rgb\(140, 109, 18\)"/);
  console.log('PASS: THE GIFT divider retains transparent gold ink across light palette changes.');

  for (const [label, filename] of [
    ['Red Rising chapter artwork', locate(redRisingArt)],
    ['Red Rising maps', locate(redRisingMap)],
    ['book cover', locate('OEBPS/cover.xhtml', '9781455563913.jpg')],
    ['author photo', locate('OEBPS/Text/autor.xhtml', 'Foto del autor')]
  ]) {
    if (!filename) continue;
    assert.match(run(filename, ['--negative']), /negative image preserved:/,
      label + ' should keep its original source pixels');
    console.log('PASS: ' + label + ' preserved.');
  }
} finally {
  fs.rmSync(temp, { recursive: true, force: true });
}
