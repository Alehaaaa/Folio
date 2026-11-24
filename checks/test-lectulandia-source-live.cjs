// Optional read-only smoke: node checks/test-lectulandia-source-live.cjs
// Checks actual official catalogue HTML and a public-domain Don Quijote book.
// Only GET catalogue/metadata/intermediate HTML and HEAD cover; never fetch EPUB/PDF.
const assert = require('node:assert/strict');
const cp = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const code = fs.readFileSync(path.join(__dirname, '../extensions/lectulandia.js'), 'utf8');
const mirrors = ['https://ww3.lectulandia.com', 'https://ww3.lectulandia.co'];
const book = '/book/don-quijote-de-la-mancha/';
let requests = 0, slowestMS = 0;

function curl(url, head = false) {
  const started = performance.now();
  const args = head
    ? ['-fsSI', '--max-time', '15', '--globoff', url]
    : ['-fsS', '--compressed', '--max-time', '15', '--max-filesize', '300000', '--globoff', url];
  const text = cp.execFileSync('curl', args, { encoding: 'utf8', timeout: 18000, maxBuffer: 500000 });
  requests++;
  slowestMS = Math.max(slowestMS, performance.now() - started);
  return text;
}
function runtime(host) {
  const context = { folio: {
    fetchText: url => curl(url),
    log: message => process.stderr.write(`  ${message}\n`),
    status: () => {}
  } };
  vm.runInNewContext(code, context, { filename: 'lectulandia.js' });
  context.source.host = host;
  return context.source;
}

for (const host of mirrors) {
  const source = runtime(host);
  const began = performance.now();
  const page = curl(`${host}/search/don+quijote/`);
  const found = source.cards(page);
  assert.ok(found.length >= 1, `${host} search returned no book cards`);
  assert.ok(found.some(row => /quijote/i.test(row.title)), `${host} search lacks Quijote titles`);
  assert.ok(found.every(row => row.url.startsWith(host + '/book/')),
    `${host} search contains links outside selected approved mirror`);
  const page2 = source.cards(curl(`${host}/search/don+quijote/page/2/`));
  assert.ok(page2.length >= 1, `${host} pagination did not yield a next page`);

  const result = source.details({ id: book, url: host + book, title: 'Don Quijote de la Mancha',
    authors: ['Miguel de Cervantes'] });
  assert.equal(result.title, 'Don Quijote de la Mancha');
  assert.ok(result.authors.some(name => name.includes('Cervantes')));
  assert.equal(result.language, 'es');
  assert.ok(result.cover.startsWith(`https://assets.lectulandia.${host.endsWith('.co') ? 'co' : 'com'}/`),
    'The mirror image must come from its verified asset server');
  const headers = curl(result.cover, true);
  assert.match(headers, /HTTP\/\d(?:\.\d)? 200/);
  assert.match(headers, /content-type:\s*image\//i);
  assert.equal(result.downloads.length, 4, 'The public-domain book exposes EPUB/PDF on two mirrors');
  assert.equal(result.downloads[0].format, 'epub');
  assert.equal(result.downloads[0].url.slice(0, host.length + 1), host + '/');
  assert.ok(result.downloads.every(d => mirrors.some(m => d.url.startsWith(m + '/'))),
    'Every candidate must use an approved mirror');
  const landing = curl(result.downloads[0].url);
  assert.match(landing, /<html\b/i, 'The first link is a countdown HTML landing page');
  assert.match(landing, /linkCode\s*=\s*["'][a-zA-Z0-9]+\//,
    'Public-domain sample should publish its countdown redirect token');
  assert.ok(!landing.startsWith('PK\x03\x04'), 'Landing HTML must never be treated as an EPUB');
  console.log(`PASS ${host}: ${found.length} search cards, ${page2.length} page-2 cards; Spanish title/author, image HTTP 200, 2 EPUB + 2 PDF candidates and provider HTML countdown; ${(performance.now() - began).toFixed(0)} ms`);
}
console.log(`PASS Lectulandia live: ${requests} read-only HTTP requests, slowest ${slowestMS.toFixed(0)} ms; no book bytes downloaded`);
