// Deterministic checks for the published Lectulandia search, mirror and
// download-page contract. No live book downloads or external network access.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

const script = fs.readFileSync(path.join(__dirname, '../extensions/lectulandia.js'), 'utf8');
const hosts = ['https://ww3.lectulandia.com', 'https://ww3.lectulandia.co'];
const bookPath = '/book/don-quijote-de-la-mancha/';
const epubPath = '/download.php?t=1&d=ZHRTcndZQ0gv&ti=Don+Quijote+de+la+Mancha';
const searchPage = `<html><div class="books-grid">
<article id="post-1234" class="card">
  <img class="cover" src="https://assets.lectulandia.com/b/123/small.jpg">
  <h2><a class="title" href="${bookPath}" title="Don Quijote de la Mancha">Don Quijote</a></h2>
  <div class="subdetail"><a href="/autor/miguel-de-cervantes/">Miguel de Cervantes</a></div>
</article></div></html>`;
const detailPage = `<html><div id="bookWrapper"><div id="book">
  <div id="title"><h1>Don Quijote de la Mancha</h1></div>
  <div id="cover"><img src="https://assets.lectulandia.com/b/123/big.jpg"></div>
  <div id="downloadContainer">
    <a rel="nofollow" href="${epubPath.replaceAll('&', '&amp;')}"><input value="epub"></a>
    <a href="/download.php?t=2&amp;d=PDFCODE&amp;ti=Don+Quijote"><input value="pdf"></a>
    <a href="https://untrusted.example/download/evil"><input value="epub"></a>
  </div><div id="autor"><a href="/autor/miguel-de-cervantes/">Miguel de Cervantes</a></div>
</div></div></html>`;

function runtime(options = {}) {
  const requested = [], events = [];
  let browserURL = '';
  const folio = {
    fetchText(url) {
      requested.push(url);
      if (options.primaryUnavailable && url.startsWith(hosts[0]))
        throw new Error('Primary host DNS unavailable');
      if (!hosts.some(host => url.startsWith(host + '/')))
        throw new Error('URL not in allowlist');
      return url.includes('/book/') ? detailPage : searchPage;
    },
    status(message) { events.push(message); },
    log(message) { events.push(message); },
    browser: {
      open(url) {
        if (options.primaryUnavailable && url.startsWith(hosts[0]))
          throw new Error('Primary host DNS unavailable');
        if (!hosts.some(host => url.startsWith(host + '/')))
          throw new Error('Browser host not allowed');
        browserURL = 'https://www.antupload.com/file/dtSrwYCH/';
        return '<html>Lectulandia download countdown</html>';
      },
      waitFor(selector) { assert.equal(selector, '#downloadB'); return 'true'; },
      url() { return browserURL; },
      html() {
        return '<a id="downloadB" href="/filed/dtSrwYCH/Don+Quijote+de+la+Mancha+-+Miguel+de+Cervantes">DOWNLOAD NOW</a>';
      }
    }
  };
  const context = { folio };
  vm.runInNewContext(script, context, { filename: 'lectulandia.js' });
  return { source: context.source, requested, events };
}

const main = runtime();
assert.equal(main.source.id, 'lectulandia');
assert.equal(main.source.version, '1.0.1');
assert.equal(JSON.stringify(main.source.languages), '["es"]');
assert.equal(main.source.search('don quijote', 0, 'en').length, 0);
assert.equal(main.requested.length, 0, 'Mismatched language should not access a site');
const books = main.source.search('don quijote', 0, 'es', 'Don Quijote de la Mancha', 'Miguel de Cervantes');
assert.equal(books.length, 1);
assert.equal(books[0].title, 'Don Quijote de la Mancha');
assert.equal(books[0].authors[0], 'Miguel de Cervantes');
assert.equal(books[0].language, 'es');
assert.equal(books[0].downloads[0].url, hosts[0] + epubPath);
assert.equal(books[0].downloads[1].url, hosts[1] + epubPath);
assert.equal(books[0].downloads[2].format, 'pdf');
assert.equal(books[0].downloads.length, 4, 'Only EPUB/PDF links from both verified mirrors');
const finalURL = main.source.prepareDownload(books[0].downloads[0].url);
assert.equal(finalURL, 'https://www.antupload.com/filed/dtSrwYCH/Don+Quijote+de+la+Mancha+-+Miguel+de+Cervantes');
assert.throws(() => main.source.prepareDownload('https://evil.example/download.php?t=1&d=evil'));
assert.throws(() => main.source.prepareDownload('https://ww3.lectulandia.com/redirect?url=https://www.antupload.com'));

const fallback = runtime({ primaryUnavailable: true });
const retry = fallback.source.search('don quijote', 0, 'es');
assert.equal(retry.length, 1);
assert.equal(retry[0].downloads[0].url, hosts[1] + epubPath);
assert.equal(retry[0].downloads[1].url, hosts[0] + epubPath);
assert.ok(fallback.events.some(message => message.includes('Primary host DNS unavailable')));
assert.equal(fallback.source.prepareDownload(retry[0].downloads[0].url), finalURL);
assert.ok(fallback.requested.some(url => url.startsWith(hosts[0])));
assert.ok(fallback.requested.some(url => url.startsWith(hosts[1])));

console.log('PASS Lectulandia language, catalogue, declared formats, allowed download flow and official mirror failover');
