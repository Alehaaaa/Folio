// Source-level regressions. Deterministic, offline: no book bytes or network calls.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const script = fs.readFileSync(path.join(__dirname, '../extensions/lectulandia.js'), 'utf8');
const main = 'https://ww3.lectulandia.com';
const backup = 'https://ww3.lectulandia.co';
const asset = 'https://assets.lectulandia.co/b/public-domain/quijote.jpg';
const ebook = '/download.php?t=1&d=ZHRTcndZQ0gv&ti=Don+Quijote';
const epub = main + ebook;
const otherEpub = backup + ebook;
const finalFile = 'https://www.antupload.com/filed/dtSrwYCH/Don+Quijote+-+Miguel+de+Cervantes';

function card(title = 'Don Quijote de la Mancha', author = 'Miguel de Cervantes', slug = 'don-quijote') {
  return `<article class="card"><a class="title" href="/book/${slug}/" title="${title}">${title}</a>
      <div class="subdetail"><a href="/autor/test/">${author}</a></div>
      <img class="cover" src="${asset}"></article>`;
}
function list(...items) { return `<html><main class="books-grid">${items.join('')}</main></html>`; }
function details(title = 'Don Quijote de la Mancha', author = 'Miguel de Cervantes') {
  return `<html><div id="book"><div id="title"><h1>${title}</h1></div>
    <div id="autor"><a href="/autor/test/">${author}</a></div>
    <div id="cover"><img src="${asset}"></div>
    <div id="downloadContainer">
      <a href="${ebook.replaceAll('&', '&amp;')}">epub</a>
      <a href="/download.php?t=2&amp;d=cGRm&amp;ti=Don+Quijote">pdf</a>
      <a href="https://unknown.example/file/spy">untrusted</a>
      <a href="/download.php?t=1&amp;d=../evil">invalid token</a>
      <a href="/download.php?t=3&amp;d=bWFsaWNpb3Vz">unknown format</a>
    </div></div><div id="related"><a href="/download.php?t=1&d=RkFLRQ">advert</a></div></html>`;
}
function runtime(options = {}) {
  const requested = [], opened = [], messages = [];
  const validSearch = list(card());
  let browserURL = 'https://www.antupload.com/file/dtSrwYCH/';
  const browser = {
    open(url) {
      opened.push(url);
      if (options.open) return options.open(url);
      if (options.unavailable && url.startsWith(main)) throw Error('primary browser offline');
      browserURL = 'https://www.antupload.com/file/dtSrwYCH/';
      return validSearch;
    },
    waitFor(selector) {
      assert.equal(selector, '#downloadB');
      return options.waitFor ? options.waitFor() : 'true';
    },
    url() { return options.browserURL || browserURL; },
    html() { return options.browserHTML || `<html><a id="downloadB" href="${finalFile.slice('https://www.antupload.com'.length)}">Download</a></html>`; }
  };
  const folio = {
    fetchText(url) {
      requested.push(url);
      if (options.fetchText) return options.fetchText(url);
      if (options.unavailable && url.startsWith(main)) throw Error('primary HTTP 503');
      return url.includes('/book/') ? details() : validSearch;
    },
    browser,
    status: message => messages.push(message),
    log: message => messages.push(message)
  };
  const context = { folio };
  vm.runInNewContext(script, context, { filename: 'lectulandia.js' });
  return { source: context.source, requested, opened, messages };
}

let run = runtime();
assert.equal(run.source.id, 'lectulandia');
assert.equal(JSON.stringify(run.source.languages), '["es"]');
assert.ok(Array.from(run.source.allowedHosts).includes('https://assets.lectulandia.co'));
assert.equal(run.source.search('quijote', 0, 'en').length, 0);
assert.equal(run.source.search('quijote', 0, 'fr-FR').length, 0);
assert.equal(run.requested.length, 0, 'A non-Spanish search must make no external requests');
const spanish = run.source.search('quijote', 0, ' ES-es ', 'Don Quijote de la Mancha', 'Miguel de Cervantes');
assert.equal(spanish.length, 1);
assert.equal(spanish[0].authors[0], 'Miguel de Cervantes');
assert.equal(spanish[0].cover, asset);
assert.equal(spanish[0].language, 'es');
assert.equal(spanish[0].downloads.length, 4, 'Only two formats across the two official mirrors');
assert.equal(spanish[0].downloads[0].url, epub);
assert.equal(spanish[0].downloads[1].url, otherEpub);
assert.equal(spanish[0].downloads[2].format, 'pdf');
assert.equal(spanish[0].downloads[3].format, 'pdf');
assert.equal(run.source.prepareDownload(epub), finalFile);
assert.deepEqual(run.opened, [epub], 'Preparation should open only its selected mirror');

run = runtime({ fetchText: url => {
  if (url.includes('/book/')) return details();
  return url.includes('/search/irrelevant/')
    ? list(card('Different story', 'Other Author', 'unrelated'))
    : list(card());
} });
let matching = run.source.search('irrelevant', 0, 'es', 'Don Quijote de la Mancha', 'Miguel de Cervantes');
assert.equal(matching.length, 1, 'Retry the exact title when a broad query finds only mismatched titles');
assert.ok(run.requested.some(url => url.includes('/search/Don+Quijote+de+la+Mancha/')));
assert.ok(!run.requested.includes(main + '/book/unrelated/'), 'Do not fetch details of a mismatched card');

run = runtime({ fetchText: url => {
  if (url.includes('/book/')) return details();
  if (url.includes('/search/Don+Quijote+de+la+Mancha/page/2/'))
    return list(card('Don Quijote de la Mancha', 'Miguel de Cervantes', 'exact-on-page-2'));
  if (url.includes('/search/Don+Quijote+de+la+Mancha/'))
    return list(card('Don Quijote de la Mancha (edición anotada)', 'Miguel de Cervantes', 'annotated'))
      .replace('</html>', '<div class="page-nav"><a class="page-numbers" href="/search/Don+Quijote+de+la+Mancha//page/2/">2</a></div></html>');
  return list(card('Don Quijote de la Mancha (Ilustrado)', 'Miguel de Cervantes', 'illustrated'));
} });
matching = run.source.search('Don Quijote de la Mancha cervantes', 0, 'es',
  'Don Quijote de la Mancha', 'Miguel de Cervantes');
assert.equal(matching[0].id, '/book/exact-on-page-2/',
  'Automatic search must prioritize an exact edition from a later page before nearby variants');
assert.equal(run.requested.filter(url => url.includes('/book/exact-on-page-2/')).length, 1);
assert.ok(run.requested.some(url => url.includes('/search/Don+Quijote+de+la+Mancha/page/2/')));
assert.equal(matching.filter(book => book.id === '/book/exact-on-page-2/').length, 1,
  'The same exact edition must not be duplicated across searches');

run = runtime({ fetchText: url => {
  if (url.includes('/book/')) return details();
  return list(card('Don Quijote de la Mancha', 'Miguel de Guerra', 'wrong-author'),
    card('Don Quijote de la Mancha', 'Miguel de Cervantes', 'correct-author'));
} });
matching = run.source.search('don quijote', 0, 'es', 'Don Quijote de la Mancha', 'Miguel de Cervantes');
assert.equal(matching.length, 1, 'Sharing a first name alone must not qualify an author match');
assert.ok(!run.requested.includes(main + '/book/wrong-author/'));
assert.equal(run.source.search('don quijote', 0, 'es', 'Don Quijote de la Mancha', 'Cervantes, Miguel').length, 1,
  'Author-name token order can differ between catalogue and caller');
assert.equal(run.source.search('don quijote', 0, 'es', 'Don Quijote de la Mancha', 'Miguel de Cervantes Saavedra').length, 1,
  'An abbreviated author attribution is acceptable');

run = runtime();
const secondPage = run.source.search('quijote', 1, 'es');
assert.equal(secondPage.length, 1);
assert.equal(run.requested[0], main + '/search/quijote/page/2/');
assert.equal(run.source.search('quijote', 101, 'en').length, 0);
assert.equal(run.source.cards(list(...Array.from({ length: 15 }, (_, i) => card(`Don Quijote ${i}`, 'Miguel de Cervantes', `edition-${i}`)))).length, 15);

run = runtime({ unavailable: true });
const mirrored = run.source.search('quijote', 0, 'es');
assert.equal(mirrored.length, 1);
assert.equal(mirrored[0].origin, backup + '/book/don-quijote/');
assert.equal(mirrored[0].downloads[0].url, otherEpub);
assert.ok(run.requested.some(url => url.startsWith(main)));
assert.ok(run.requested.some(url => url.startsWith(backup)));
assert.equal(run.source.prepareDownload(otherEpub), finalFile);
assert.equal(run.opened.at(-1), otherEpub);

run = runtime({ unavailable: true });
assert.throws(() => run.source.prepareDownload(epub), /primary browser offline/);
assert.deepEqual(run.opened, [epub], 'Do not repeat a broken mirror before Folio tries the next candidate');
assert.equal(run.source.prepareDownload(otherEpub), finalFile, 'The next candidate should recover');

for (const bad of [
  'http://ww3.lectulandia.com' + ebook,
  'https://ww3.lectulandia.com.evil.example' + ebook,
  'https://www.antupload.com/file/dtSrwYCH/',
  main + '/redirect?to=' + encodeURIComponent(epub),
  main + '/download.php?t=9&d=ZHRTcndZQ0gv',
  main + '/download.php?t=1&d=../secret'
]) {
  assert.throws(() => runtime().source.prepareDownload(bad), /Invalid Lectulandia download page/);
}
for (const bad of [
  { browserURL: 'https://evil.example/file/abcd/' },
  { browserURL: 'http://www.antupload.com/file/abcd/' },
  { browserHTML: '<a id="downloadB" href="https://evil.example/steal.epub">Download</a>' },
  { browserHTML: '<a id="downloadB" href="/filed/abcd/../../../evil">Download</a>' },
  { waitFor: () => 'false' }
]) assert.throws(() => runtime(bad).source.prepareDownload(epub));

run = runtime({ fetchText: () => { throw Error('HTTP 503'); }, open: () => { throw Error('Browser unavailable'); } });
assert.throws(() => run.source.search('quijote', 0, 'es'), /Lectulandia mirrors unavailable/);
assert.equal(run.requested.length, 2, 'Both approved hosts should be attempted after server and browser failures');

run = runtime({ fetchText: () => '<html>Just a moment... Checking your browser</html>',
  open: url => url.includes('/book/') ? details() : list(card()) });
assert.equal(run.source.search('quijote', 0, 'es').length, 1,
  'A browser-check page must trigger the WebKit fallback');
assert.ok(run.opened.length > 0);

run = runtime({ fetchText: url => url.startsWith(main) && url.includes('/book/')
    ? '<html><p>HTTP 503 maintenance</p></html>' : (url.includes('/book/') ? details() : list(card())),
  open: url => url.includes('/book/') ? '<html><p>Temporary browser interstitial</p></html>' : list(card()) });
assert.equal(run.source.search('quijote', 0, 'es')[0].origin, backup + '/book/don-quijote/',
  'HTML from a browser error/interstitial cannot suppress official mirror failover');

console.log('PASS Lectulandia source: identity, language, pagination, title and author matching, covers, format filtering, mirror recovery, server/browser errors, approved redirects and single-mirror preparation');
