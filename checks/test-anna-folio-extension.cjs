// Deterministic tests of the standalone extension contract and its free EPUB getter.
// Run: node checks/test-anna-folio-extension.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.join(__dirname, '..');
const script = fs.readFileSync(path.join(root, 'extensions/annas-archive.js'), 'utf8');
const searchPage = fs.readFileSync(path.join(__dirname, 'anna-fixtures/search.html'), 'utf8');
const detailPage = fs.readFileSync(path.join(__dirname, 'anna-fixtures/detail.html'), 'utf8');
const hash = '51d2b22ca12a8b470b51f543298b34c9';
const official = ['annas-archive.gl', 'annas-archive.pk', 'annas-archive.gd'];
const githubConfig = 'export const OFFICIAL_MIRRORS = ["annas-archive.gl", "annas-archive.pk", "annas-archive.gd"] as const;';

function harness(fetch, browser, withStatus = true) {
  const requested = [];
  const statuses = [];
  const logs = [];
  const context = {
    folio: {
      fetchText(url) {
        requested.push(url);
        return fetch(url);
      },
      log(message) { logs.push(message); },
      config: {}
    },
    Date,
    RegExp,
    encodeURIComponent
  };
  if (withStatus) context.folio.status = message => statuses.push(message);
  if (browser) context.folio.browser = browser;
  vm.createContext(context);
  vm.runInContext(script, context, {timeout: 5000});
  assert.equal(context.source.name, "Anna's Archive — Free");
  assert.equal(context.source.id, 'annas-archive-free');
  assert.equal(context.source.version, '1.3.8');
  assert.equal(context.source.allowedHosts.length, 5);
  return {source: context.source, requested, statuses, logs};
}

// Real-shaped search and detail page fixtures, with an unavailable first mirror.
const run = harness(url => {
  if (url.includes('raw.githubusercontent.com')) return githubConfig;
  if (url.startsWith('https://annas-archive.gl/')) throw new Error('403 browser verification');
  if (url.startsWith('https://annas-archive.pk/search?')) return searchPage;
  if (url === `https://annas-archive.pk/md5/${hash}`) return detailPage;
  throw new Error('unexpected URL ' + url);
});
const books = run.source.search('Pride and Prejudice Jane Austen', 0);
assert.equal(books.length, 1, 'the public-domain sample should be found');
assert.equal(books[0].id, hash);
assert.equal(books[0].title, 'Pride and Prejudice');
assert.equal(books[0].authors[0], 'Austen, Jane');
assert.equal(books[0].language, null, 'legacy search cards have no reliable table language');
assert.equal(books[0].downloads.length, 1);
assert.deepEqual({...books[0].downloads[0]}, {
  format: 'epub',
  url: `https://annas-archive.pk/slow_download/${hash}/0/0`
});
assert.ok(run.requested.some(u => u.includes('annas-archive.gl/search')));
assert.ok(run.requested.some(u => u.includes('annas-archive.pk/search')));
assert.ok(!run.requested.some(u => /fast_download|dyn\/api\/|key=/.test(u)), 'free flow must never invoke paid endpoints');
assert.ok(run.requested.every(u => /https:\/\/(?:annas-archive\.(?:gl|pk|gd)|raw\.githubusercontent\.com)\//.test(u)), 'network must stay on approved hosts');
assert.ok(run.statuses.some(s => /Refreshing official mirrors/.test(s)), 'report mirror-list refresh');
assert.ok(run.statuses.some(s => /Searching free EPUB listings/.test(s)), 'report search');
assert.ok(run.statuses.some(s => /Loading book details/.test(s)), 'report record metadata');
assert.ok(run.statuses.some(s => /Checking published free download options/.test(s)), 'report free-link checks');
assert.match(run.statuses.at(-1), /EPUB download unverified/i, 'do not claim the free HTML landing page is an EPUB');
assert.ok(run.logs.some(s => /403 browser verification/.test(s)), 'retain the failed mirror diagnosis');

// The current (Nov 2026) table result layout and the offscreen browser fallback.
const modernTable = `<html><body><table class="text-sm w-full mt-4 h-fit"><tbody>
  <tr><td></td><td><a href="/md5/${hash}">Pride and Prejudice</a></td>
  <td><a href="/md5/${hash}">Jane Austen</a></td><td>Project Gutenberg</td>
  <td>1998</td><td>Pride and Prejudice.epub</td><td>zlib</td><td>en</td>
  <td>Book (fiction)</td><td><a href="/md5/${hash}">epub</a></td><td>0.3MB</td><td></td></tr>
  </tbody></table></body></html>`;
const browserURLs = [];
const rendered = harness(url => {
  if (url.includes('raw.githubusercontent.com')) return githubConfig;
  throw new Error('403');
}, {
  open(url) {
    browserURLs.push(url);
    if (url.includes('/slow_download/')) return '<html><script>var waitSeconds = 185;</script><p>Please wait</p></html>';
    return url.includes('/md5/') ? detailPage : modernTable;
  }
});
const renderedBooks = rendered.source.search('Pride and Prejudice Jane Austen', 0);
assert.equal(renderedBooks.length, 1, 'modern HTML table should be parsed via WebKit fallback');
assert.equal(renderedBooks[0].title, 'Pride and Prejudice');
assert.equal(renderedBooks[0].authors[0], 'Jane Austen');
assert.equal(renderedBooks[0].language, 'en', 'search-table language column 7 must reach result metadata');
assert.ok(rendered.logs.some(s => s.includes(`hash=${hash} language=en`)), 'include hash and language in diagnostic logs');
assert.equal(renderedBooks[0].downloads[0].format, 'epub');
assert.equal(renderedBooks[0].origin, 'annas-archive.gl');
assert.deepEqual(browserURLs.length, 3, 'browser should load search, detail, and ONE free-partner wait page');
assert.ok(rendered.statuses.some(s => /Checking mirror in background browser/.test(s)), 'report standard browser verification');
assert.ok(rendered.statuses.some(s => /Checking free partner wait estimate/.test(s)), 'report free partner queue inspection');
assert.ok(rendered.statuses.some(s => /about 4 min \(estimate\)/.test(s)), 'only describe an estimated wait');
assert.match(rendered.statuses.at(-1), /Free partner wait ~4 min; EPUB unverified/);
assert.ok(rendered.logs.some(s => /185 seconds/.test(s)), 'retain detailed wait information in logs');
assert.ok(rendered.statuses.every(s => !/download complete|download ready|successfully downloaded/i.test(s)));
assert.equal(rendered.source.mirrorCooldowns['annas-archive.gl'], undefined,
  'a direct 403 must not cool down a mirror when its normal background browser succeeds');

// The language is per EPUB RECORD, not inherited from the query or the first
// row. Use a public-domain Austen text in different synthetic editions. Unknown
// languages must never silently become English (the German Red Rising bug).
const germanHash = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const unknownHash = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
function tableRow(md5, language, title = 'Pride and Prejudice') {
  return `<tr><td>cover</td><td><a href="/md5/${md5}">${title}</a></td>
    <td>Jane Austen</td><td>Project Gutenberg</td><td>1998</td><td>${title}.epub</td>
    <td>zlib</td><td>${language}</td><td>Book</td><td>epub</td><td>0.3MB</td></tr>`;
}
const multilingualTable = `<html><body><table class="text-sm w-full mt-4 h-fit"><tbody>
  ${tableRow(hash, 'en')}
  ${tableRow(germanHash, 'de', 'Stolz und Vorurteil')}
  ${tableRow(unknownHash, 'Unknown')}
  </tbody></table></body></html>`;
const multilingual = harness(url => {
  if (url.includes('raw.githubusercontent.com')) return githubConfig;
  if (url.includes('/search?')) return multilingualTable;
  if (url.includes('/md5/')) {
    const md5 = url.split('/md5/')[1];
    return detailPage.replaceAll(hash, md5);
  }
  throw new Error('unexpected URL ' + url);
});
const multilingualRecords = multilingual.source.search('Pride and Prejudice Jane Austen', 0);
assert.deepEqual(Array.from(multilingualRecords, r => r.language), ['en', 'de', null],
  'per-result language distinguishes English, German and unlabelled editions');
assert.deepEqual(Array.from(multilingualRecords, r => r.id), [hash, germanHash, unknownHash]);
for (const [md5, language] of [[hash, 'en'], [germanHash, 'de'], [unknownHash, 'unknown']]) {
  assert.ok(multilingual.logs.some(line => line.includes(`hash=${md5} language=${language}`)),
    `log language and hash for ${md5}`);
}
assert.equal(multilingual.source.normalizedLanguage('German'), 'de');
assert.equal(multilingual.source.normalizedLanguage('Deutsch'), 'de');
assert.equal(multilingual.source.normalizedLanguage('English [en]'), 'en');
assert.equal(multilingual.source.normalizedLanguage('French'), 'fr');
assert.equal(multilingual.source.normalizedLanguage('ESPAÑOL'), 'es');
assert.equal(multilingual.source.normalizedLanguage('de-DE'), 'de');
assert.equal(multilingual.source.normalizedLanguage(''), null);
assert.equal(multilingual.source.normalizedLanguage('N/A'), null);
assert.equal(multilingual.source.normalizedLanguage('multiple unknown languages'), null);

// The archive sorts some popular translated editions before the English one.
// An optional preferred language MUST filter/reorder the ENTIRE search table
// before the 12 record-detail lookups, not after those 12 lookups are spent.
const manyRows = [
  ...Array.from({length: 12}, (_, i) => ({
    id: (i + 1).toString(16).padStart(32, '0'), language: i % 2 ? 'German' : 'de'
  })),
  {id: '99999999999999999999999999999990', language: ''},
  {id: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeee1', language: 'EN'},
  {id: 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeee2', language: 'English [en]'},
  ...Array.from({length: 16}, (_, i) => ({
    id: (i + 40).toString(16).padStart(32, '0'), language: 'unknown'
  }))
];
const manyRowHTML = records => `<html><body><table class="text-sm w-full mt-4 h-fit"><tbody>
  ${records.map(r => tableRow(r.id, r.language)).join('\n')}
  </tbody></table></body></html>`;
function multiRowRun(records) {
  return harness(url => {
    if (url.includes('raw.githubusercontent.com')) return githubConfig;
    if (url.includes('/search?')) return manyRowHTML(records);
    if (url.includes('/md5/')) {
      const md5 = url.split('/md5/')[1];
      return detailPage.replaceAll(hash, md5);
    }
    throw new Error('unexpected URL ' + url);
  });
}
const languagePreferred = multiRowRun(manyRows);
const preferredBooks = languagePreferred.source.search('Pride and Prejudice Jane Austen', 0, ' EN-us ');
const englishIDs = ['eeeeeeeeeeeeeeeeeeeeeeeeeeeeeee1', 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeee2'];
assert.equal(preferredBooks.length, 12, 'language filtering still honors the 12-detail request budget');
assert.deepEqual(Array.from(preferredBooks.slice(0, 2), b => b.id), englishIDs,
  'English matches beyond the first twelve German rows are fetched FIRST');
assert.deepEqual(Array.from(preferredBooks.slice(0, 2), b => b.language), ['en', 'en'],
  'case-insensitive language names and regional preferences normalize to en');
assert.ok(preferredBooks.slice(2).every(b => b.language === null),
  'unknown languages remain unknown, and are considered only after English matches');
const chosenDetailIDs = languagePreferred.requested.filter(u => u.includes('/md5/')).map(u => u.split('/md5/')[1]);
assert.equal(chosenDetailIDs.length, 12, 'wrong-language rows must not burn any detail lookup slots');
assert.deepEqual(chosenDetailIDs.slice(0, 2), englishIDs, 'actual detail requests start with English');
assert.ok(chosenDetailIDs.every(id => !manyRows.slice(0, 12).some(r => r.id === id)),
  'no explicitly German record receives a detail request');
assert.ok(languagePreferred.logs.some(s => /12 explicit mismatch\(es\) skipped before detail lookups/.test(s)),
  'diagnostics report how many wrong-language rows were skipped');

const noPreference = multiRowRun(manyRows);
const oldBehavior = noPreference.source.search('Pride and Prejudice Jane Austen', 0);
assert.equal(oldBehavior.length, 12, 'two-argument search remains constrained by maxResults');
assert.deepEqual(Array.from(oldBehavior, b => b.id), manyRows.slice(0, 12).map(r => r.id),
  'two-argument search retains original server order without language filtering');
assert.ok(oldBehavior.every(b => b.language === 'de'),
  'without a preferred language existing German results are not silently discarded');

const allGerman = multiRowRun(manyRows.slice(0, 14).map(r => ({...r, language: 'DE'})));
const noEnglishBooks = allGerman.source.search('Pride and Prejudice Jane Austen', 0, 'English');
assert.equal(noEnglishBooks.length, 0,
  'all explicitly German records must return zero English candidates rather than the wrong book');
assert.equal(allGerman.requested.filter(u => u.includes('/md5/')).length, 0,
  'all-German search does not issue any record-detail requests');
assert.ok(allGerman.logs.some(s => /14 explicit mismatch\(es\) skipped/.test(s)),
  'no eligible language matches are explicitly explained, not treated as mirror failure');

const allFrench = multiRowRun(manyRows.slice(0, 14).map(r => ({...r, language: 'French'})));
assert.equal(allFrench.source.search('Pride and Prejudice Jane Austen', 0, 'en').length, 0,
  'a clearly named non-English language must not be mistaken for an unknown-language fallback');
assert.equal(allFrench.requested.filter(u => u.includes('/md5/')).length, 0,
  'explicit French mismatches consume no detail requests when English is required');

const unknownPreferred = multiRowRun(manyRows.slice(0, 14));
const unknownQueryLanguage = unknownPreferred.source.search('Pride and Prejudice', 0, 'unknown');
assert.deepEqual(Array.from(unknownQueryLanguage, b => b.id), manyRows.slice(0, 12).map(r => r.id),
  'an unrecognized preferred language must not be guessed and cannot discard records');

// REAL-SHAPED Iron Gold / Pierce Brown search evidence, read-only rendered .pk
// table inspected 2026-11-20: the archive had 44 rows. Several exact-title
// entries were on rows #15/#17/#18 (beyond the old 12-detail cutoff), while
// #4/#5 had the exact title but a concatenated duplicate creator string.
// Keep those source strings untouched; Folio independently verifies author,
// language and the imported OPF before allowing automatic reading.
function ironRow(id, title, author, language = 'en') {
  return `<tr><td></td><td><a href="/md5/${id}">${title}</a></td>
    <td>${author}</td><td>Publisher</td><td>2018</td><td>book.epub</td>
    <td>zlib</td><td>${language}</td><td>Book</td><td>epub</td><td>0.7MB</td></tr>`;
}
const ironRows = [
  ['4956fde65184f83f42885f1e22e86475', 'Red Rising 3-Book Bundle: Red Rising, Golden Son, Morning Star, and an Exclusive Extended Excerpt of Iron Gold', 'Pierce Brown'],
  ['1a5d05656e72e95ef47c83761a6f16ba', 'Brown, Pierce - Red Rising 04 - Iron Gold Iron Gold (Red Rising Series Book 4)', 'Brown, Pierce Pierce Brown'],
  ['44cb189d7801112768c0d835aed3246b', 'Brown, Pierce - Red Rising 04 - Iron Gold', 'Brown, Pierce'],
  ['c3ab387a504eb85f580cd3a6fe08487f', 'Iron Gold', 'Brown, Pierce Pierce Brown'],
  ['e793494411fa3200779ebb85277632da', 'Iron Gold', 'Brown, Pierce Pierce Brown'],
  ['9bbfdefd0349afd401b0cb90d3bbea0f', 'Brown, Pierce - Red Rising 04 - Iron Gold Iron Gold (Red Rising Saga, #4)', 'Brown, Pierce Pierce Brown'],
  ['f76acaea85541c0e9444fa363457057f', 'Brown, Pierce - Red Rising 04 - Iron Gold', 'Brown, Pierce', '?'],
  ['062822e4df51eabef9a3fbe5806594c8', 'Red Rising 3-Book Bundle including Iron Gold [Arabic]', 'Pierce Brown', 'unknown'],
  ['423dfcf76344377d6e177756eb622502', 'Iron Gold (Red Rising Series Book 4) Iron gold Iron Gold Series, Book 1', 'Pierce Brown [Brown, Pierce]'],
  ['5ebce92e0ec145f63d3536514534fb64', 'Iron Gold (Red Rising Saga, #4) Iron gold. 4 / Red Rising saga', 'Brown, Pierce Pierce Brown'],
  ['2588dfd07fe5e7aa59ff368d3ba1466a', 'Iron Gold: Book 4 of the Red Rising Saga', 'Brown, Pierce Pierce Brown'],
  ['eb9e07487c59ed4bd0487383a1141f5c', 'Iron Gold: Book IV of the Red Rising Saga', 'Pierce Brown'],
  ['efd069a81cfdab0984be23aba4840bf4', 'Iron Gold (Red Rising Series Book 4) Iron gold Iron Gold Series, Book 1', 'Brown, Pierce'],
  ['49a3ee2fc4ebcfbcd2a4d2abdaf54935', 'Iron Gold: Book 4 of the Red Rising Saga Iron Gold (Red Rising Series Book 4)', 'Brown, Pierce'],
  ['aa327cf11bd005c1e8b3bd8d052a31fb', 'Iron Gold', 'Pierce Brown;'],
  ['0e0893c8969c150dd886e8074be099a2', 'Iron Gold (Red Rising Series Book 4)', 'Pierce Brown'],
  ['7dd9a2be4257bc2e18b521e3badc10ef', 'Iron Gold', 'Pierce Brown'],
  ['85f3888647519042732dcef80ee3ca02', 'Iron Gold', 'Pierce Brown'],
  ['ad74a0fc47e94a27aa563164b7df2d10', 'Red Rising 3-Book Bundle (includes Iron Gold excerpt)', 'Pierce Brown']
];
function ironFixture(rows) {
  return `<html><body><table class="text-sm w-full mt-4 h-fit"><tbody>
    ${rows.map(r => ironRow(...r)).join('\n')}
    </tbody></table></body></html>`;
}
function ironHarness(initial, refined) {
  return harness(url => {
    if (url.includes('raw.githubusercontent.com')) return githubConfig;
    if (url.includes('/search?')) {
      const q = new URL(url).searchParams.get('q');
      return q === 'Iron Gold' ? ironFixture(refined ?? initial) : ironFixture(initial);
    }
    if (url.includes('/md5/')) {
      const md5 = url.split('/md5/')[1];
      return detailPage.replaceAll(hash, md5);
    }
    throw new Error('unexpected URL ' + url);
  });
}
const iron = ironHarness(ironRows);
const ironBooks = iron.source.search('Iron Gold brown', 0, 'en');
const ironSearchURLs = iron.requested.filter(u => u.includes('/search?'));
const ironDetailIDs = iron.requested.filter(u => u.includes('/md5/')).map(u => u.split('/md5/')[1]);
const cleanIronIDs = ['aa327cf11bd005c1e8b3bd8d052a31fb',
  '7dd9a2be4257bc2e18b521e3badc10ef', '85f3888647519042732dcef80ee3ca02'];
assert.equal(ironSearchURLs.length, 1, 'exact Iron Gold titles in the initial table need no query retry');
assert.deepEqual(ironDetailIDs.slice(0, 3), cleanIronIDs,
  'clean exact title+author records beyond rank 12 must lead detail lookups');
assert.ok(ironBooks.slice(0, 3).every(b => b.title === 'Iron Gold' && b.language === 'en'),
  'return original unmodified, correctly labelled English Iron Gold records');
assert.ok(ironDetailIDs.length <= 12, 'source never exceeds twelve record-detail requests');
assert.ok(!ironDetailIDs.includes('4956fde65184f83f42885f1e22e86475'),
  'Red Rising three-book bundle/excerpt is NOT an Iron Gold candidate');
assert.ok(iron.logs.some(line => /Identity-aware search for Iron Gold \/ brown/.test(line)),
  'log identity-aware ranking and near-match diagnostics');
const ironHint = iron.source.lookupIdentity('Iron Gold brown', iron.source.searchCards(ironFixture(ironRows)));
assert.equal(ironHint.title, 'Iron Gold', 'infer the title from a query only when author column corroborates surname');
assert.equal(iron.source.identityRank({title: 'Iron Gold (Red Rising Series Book 4)', author: 'Pierce Brown'}, ironHint), 1,
  'single series qualifier is a safe metadata variant, never silently rewritten');
assert.equal(iron.source.identityRank({title: 'Iron Gold: Book IV of the Red Rising Saga', author: 'Pierce Brown'}, ironHint), 1,
  'series-book subtitle is recognized without redefining the book title');
assert.equal(iron.source.identityRank({title: 'Iron Gold: An Annotated Edition', author: 'Pierce Brown'}, ironHint), -1,
  'annotated edition is rejected for unattended source ranking');
assert.equal(iron.source.identityRank({title: 'Iron Gold: Abridged', author: 'Pierce Brown'}, ironHint), -1,
  'abridged edition is rejected');
assert.equal(iron.source.identityRank({title: 'The Iron Gold Collection', author: 'Pierce Brown'}, ironHint), -1,
  'collection title preceding the requested title is rejected');
const trustedIron = ironHarness(ironRows);
const trustedBooks = trustedIron.source.search('Iron Gold brown', 0, 'en', 'Iron Gold', 'Pierce Brown');
assert.deepEqual(Array.from(trustedBooks.slice(0, 3), r => r.id), cleanIronIDs,
  'native five-argument trusted identity ranks clean-author Iron Gold records first');
assert.ok(trustedIron.requested.filter(u => u.includes('/md5/')).length <= 12,
  'native five-argument search still respects its bounded detail budget');
assert.equal(trustedIron.requested.filter(u => u.includes('/search?')).length, 1,
  'credible titles avoid the unnecessary title-only search');
assert.ok(!trustedIron.requested.some(u => u.includes('/md5/4956fde65184f83f42885f1e22e86475')),
  'real Red Rising bundle is never fetched in trusted automatic lookup');

// When the first title+surname search has only ambiguous/bundle rows (NO
// credible exact or clean series edition), retry with the title once BEFORE
// any expensive /md5/ requests. A credible series-only row must not trigger
// a redundant retry.
const ironNearbyOnly = [ironRows[0], ironRows[1], ironRows[8], ironRows[18]];
const refinedOnly = [
  ['bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbe', 'Iron Gold', 'Pierce Brown', 'en'],
  ['aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab', 'Iron Gold: Abridged', 'Pierce Brown', 'en']
];
const ironRetry = ironHarness(ironNearbyOnly, refinedOnly);
const retryResults = ironRetry.source.search('Iron Gold brown', 0, 'English');
assert.equal(ironRetry.requested.filter(u => u.includes('/search?')).length, 2,
  'one title-only query retry, never repeated searches per candidate');
assert.equal(new URL(ironRetry.requested.filter(u => u.includes('/search?'))[1]).searchParams.get('q'), 'Iron Gold',
  'title-only refinement removes the author surname without changing the title');
assert.equal(retryResults[0].id, 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbe',
  'one newly discovered exact title+author wins before existing nearby matches');
assert.ok(!retryResults.some(b => /abridged/i.test(b.title)),
  'refinement never turns an abridged edition into an automatic candidate');
assert.ok(ironRetry.requested.filter(u => u.includes('/md5/')).length <= 12,
  'two search requests still share one twelve-detail budget');
assert.ok(!ironRetry.requested.some(u => u.includes('/md5/4956fde65184f83f42885f1e22e86475')),
  'retry does not fetch an unrelated bundle from the first result page');

const credibleSeries = ironHarness([ironRows[11]]);
const seriesOnly = credibleSeries.source.search('Iron Gold brown', 0, 'en', 'Iron Gold', 'Pierce Brown');
assert.equal(credibleSeries.requested.filter(u => u.includes('/search?')).length, 1,
  'a credible series-edition subtitle does not cause a title-only retry');
assert.equal(seriesOnly.length, 1, 'a corroborated safe series subtitle may be returned for native verification');

// The native queue now passes expectedTitle/expectedAuthor. Without first
// page results, or for a one-word title, source-side inference alone cannot
// build the identity. These MUST still retry the title-only query exactly once.
function trustedSearch(initialHTML, retryHTML, query, title, author, language = 'en') {
  const run = harness(url => {
    if (url.includes('raw.githubusercontent.com')) return githubConfig;
    if (url.includes('/search?')) {
      const q = new URL(url).searchParams.get('q');
      return q === title ? retryHTML : initialHTML;
    }
    if (url.includes('/md5/')) return detailPage.replaceAll(hash, url.split('/md5/')[1]);
    throw new Error('unexpected URL ' + url);
  });
  return {run, results: run.source.search(query, 0, language, title, author)};
}
const noRows = '<html><body><p>No results found</p></body></html>';
const redGodHash = 'ababababababababababababababab01';
const redGod = trustedSearch(noRows,
  ironFixture([[redGodHash, 'Red God', 'Pierce Brown', 'en'],
    ['ababababababababababababababab02', 'Red God: Abridged', 'Pierce Brown', 'en'],
    ['ababababababababababababababab03', 'Red God', 'Another Brown', 'en']]),
  'Red God brown', 'Red God', 'Pierce Brown');
assert.deepEqual(Array.from(redGod.results, r => r.id), [redGodHash],
  'Red God with zero initial hits must find the correct edition through the title-only retry');
assert.equal(redGod.run.requested.filter(u => u.includes('/search?')).length, 2,
  'zero initial Red God rows cause one additional title-only query');
assert.deepEqual(redGod.run.requested.filter(u => u.includes('/md5/')).map(u => u.split('/md5/')[1]), [redGodHash],
  'Red God fetches only credible author and title, not abridged or surname-only authors');

const duneHash = 'ababababababababababababababab04';
const dune = trustedSearch(noRows,
  ironFixture([[duneHash, 'Dune', 'Frank Herbert', 'en'],
    ['ababababababababababababababab05', 'Dune', 'Brian Herbert', 'en'],
    ['ababababababababababababababab06', 'Dune: Annotated', 'Frank Herbert', 'en']]),
  'Dune herbert', 'Dune', 'Frank Herbert');
assert.deepEqual(Array.from(dune.results, r => r.id), [duneHash],
  'one-word title retry works and rejects a different author sharing the same surname');
assert.equal(dune.run.requested.filter(u => u.includes('/search?')).length, 2,
  'single-word titles do not need a first-page hit to retry');
assert.equal(dune.run.requested.filter(u => u.includes('/md5/')).length, 1,
  'single-word title does not trigger unrelated detail lookups');

const totalMiss = trustedSearch(noRows, noRows, 'Red God brown', 'Red God', 'Pierce Brown');
assert.equal(totalMiss.results.length, 0, 'two empty title searches do not invent a match');
assert.equal(totalMiss.run.requested.filter(u => u.includes('/search?')).length, 2,
  'two empty search pages are bounded at the single retry');
assert.equal(totalMiss.run.requested.filter(u => u.includes('/md5/')).length, 0,
  'empty results never consume any detail requests');
assert.match(totalMiss.run.statuses.at(-1), /No credible matching EPUB editions found/,
  'after both empty searches, queue receives an explicit no-credible-match status');

const ambiguousMiss = trustedSearch(ironFixture(ironNearbyOnly), ironFixture(ironNearbyOnly),
  'Iron Gold brown', 'Iron Gold', 'Pierce Brown');
assert.equal(ambiguousMiss.results.length, 0,
  'two noncredible listing pages must fail instead of fetching nearby or bundled editions');
assert.equal(ambiguousMiss.run.requested.filter(u => u.includes('/md5/')).length, 0,
  'ambiguous or bundled records never consume a /md5/ request');
assert.equal(ambiguousMiss.run.requested.filter(u => u.includes('/search?')).length, 2,
  'ambiguous-only search performs no more than one refinement');
assert.match(ambiguousMiss.run.logs.at(-1), /no record-detail requests were made/,
  'ambiguous-only failure logs why no unnecessary detail requests were made');

const germanOnly = trustedSearch(ironFixture([[redGodHash, 'Red God', 'Pierce Brown', 'de']]),
  ironFixture([[redGodHash, 'Red God', 'Pierce Brown', 'de']]),
  'Red God brown', 'Red God', 'Pierce Brown');
assert.equal(germanOnly.results.length, 0, 'an explicit German record cannot satisfy English');
assert.equal(germanOnly.run.requested.filter(u => u.includes('/md5/')).length, 0,
  'wrong-language records cause zero detail requests even after title-only refinement');

const noTrustedAuthor = trustedSearch(noRows, ironFixture([[redGodHash, 'Red God', 'Pierce Brown', 'en']]),
  'Red God brown', 'Red God', '');
assert.equal(noTrustedAuthor.results.length, 0,
  'incomplete trusted identity with no initial corroborating rows cannot guess a match');
assert.equal(noTrustedAuthor.run.requested.filter(u => u.includes('/search?')).length, 1,
  'incomplete trusted identity must not start speculative title-only retries');

const noPreferredLanguage = trustedSearch(noRows,
  ironFixture([[redGodHash, 'Red God', 'Pierce Brown', 'en']]),
  'Red God brown', 'Red God', 'Pierce Brown', null);
assert.deepEqual(Array.from(noPreferredLanguage.results, r => r.id), [redGodHash],
  'trusted fourth/fifth args still constrain title/author when language preference is absent');
assert.equal(noPreferredLanguage.run.requested.filter(u => u.includes('/search?')).length, 2,
  'trusted title-only retry does not require a language preference');

// An arbitrary free-text query should not be interpreted as a surname-based
// automatic lookup. Keep existing source ordering when identity is ambiguous.
const genericIron = ironHarness(ironRows);
const genericIronRecords = genericIron.source.search('Iron Gold Pierce Brown', 0, 'en');
assert.equal(genericIron.requested.filter(u => u.includes('/search?')).length, 1,
  'mixed-case generic query must not trigger title-only network retries');
assert.equal(genericIronRecords[0].id, ironRows[0][0],
  'generic search retains existing archive ranking');
const legacyIron = ironHarness(ironRows);
const legacyIronRecords = legacyIron.source.search('Iron Gold brown', 0);
assert.equal(legacyIron.requested.filter(u => u.includes('/search?')).length, 1,
  'two-argument search does not add automatic title-only network requests');
assert.equal(legacyIronRecords[0].id, ironRows[0][0],
  'two-argument search retains its original source order, including unrelated listings');

// Live Want/Gillian Anderson catalogue evidence (43 rows observed from the
// official .pk table on Nov 20, 2026): the four exact "Want" rows at #39-42
// were Italian; #43 is exact "Want" with UNVERIFIED language; six English
// listings carried a published subtitle, two of them unmerged and credible.
// Never infer English from an unlabelled row or from an author's nationality.
const wantRows = [
  ['11111111111111111111111111111111', 'You’re What I Really Want', 'Anderson, Gabrielle', 'en'],
  ['e561800744aa0e8d980ed87437564860', 'Want: Submitted by anonymous', 'Anderson, Gillian', 'en'],
  ['6cb98496cca079cc52b8e5d46e92a457', 'Want: Sexual Fantasies by Anonymous', 'Gillian Anderson (ed) Anderson, Gillian', 'en'],
  ['3e15f99f547b4d61ec3606d0fd41f81d', 'Want: Submitted by anonymous', 'Anderson, Gillian', 'en'],
  ['2beb360cc4fb0913e538f20f3e129617', 'Want: Submitted by Anonymous Want: Sexual Fantasies by Anonymous The Anonymous Gardeners', 'Gillian Anderson (ed) Abrams Abrams Books Anderson, Gillian', 'en'],
  ['c85f8e6ff1f7137d2d3e8f95e355d92b', 'Want', 'Gillian Anderson', 'it'],
  ['0fab9662b279babec146052c3dc3ab5b', 'Want', 'Gillian Anderson', 'it'],
  ['e9e4bd8cfa16c3fcda867d7571b31ac0', 'Want', 'Gillian Anderson', 'it'],
  ['dfcc8b94de5d5c3cfdf00d8f5ae1a7ba', 'Want', 'Gillian Anderson', 'it'],
  ['03be5ab58d201a756b1b2263298080ca', 'Want', 'Gillian Anderson', 'unknown'],
];
const wantTitle = 'Want';
const wantAuthor = 'Gillian Anderson';
const wantTitleID = wantRows[9][0];
const wantPublishedID = wantRows[2][0];
const wantTable = records => ironFixture(records);
function wantHarness(availableHash = null, records = wantRows) {
  return harness(url => {
    if (url.includes('raw.githubusercontent.com')) return githubConfig;
    if (url.includes('/search?')) return wantTable(records);
    if (url.includes('/md5/')) {
      const bookHash = url.split('/md5/')[1];
      // Readable catalogue record, but most editions do NOT publish a free
      // Slow Partner link. This is not an entire-source outage.
      if (bookHash === availableHash && url.startsWith('https://annas-archive.gl/'))
        return detailPage.replaceAll(hash, bookHash);
      return '<html><body><h1>Want</h1><p>Published EPUB record, no free partner link</p></body></html>';
    }
    throw new Error('unexpected URL: ' + url);
  });
}
const wantProbe = wantHarness(wantPublishedID);
const wantBooks = wantProbe.source.search('Want anderson', 0, 'en', wantTitle, wantAuthor);
const wantDetailURLs = wantProbe.requested.filter(url => url.includes('/md5/'));
assert.deepEqual(Array.from(wantBooks, book => book.id), [wantPublishedID],
  'an explicitly English, corroborated Want subtitle resolves after earlier editions have no published link');
assert.equal(wantBooks[0].title, 'Want: Sexual Fantasies by Anonymous',
  'source keeps the published title; the native importer must verify EPUB OPF identity');
assert.ok(wantDetailURLs.some(url => url.includes('/md5/' + wantRows[1][0])),
  'first credible English edition is tried even when its free partner link is unavailable');
assert.ok(wantDetailURLs.some(url => url.includes('annas-archive.gl/md5/' + wantPublishedID)),
  'missing link on one edition must not blacklist the same host for other editions');
assert.ok(wantDetailURLs.every(url => !wantRows.slice(5, 9).some(row => url.includes(row[0]))),
  'all explicitly Italian Want editions are excluded from English detail requests');
assert.ok(!wantDetailURLs.some(url => url.includes('/md5/' + wantRows[4][0])),
  'combined multi-title Want record is not treated as one credible edition');
assert.equal(wantProbe.requested.filter(url => url.includes('/search?')).length, 1,
  'credible English subtitle listings avoid title-only retries and mirror catalogue re-queries');
assert.ok(wantDetailURLs.some(url => url.includes('/md5/' + wantTitleID)),
  'unknown-language canonical Want is still considered after explicitly English subtitles');

const wantUnavailable = wantHarness();
assert.throws(() => wantUnavailable.source.search('Want anderson', 0, 'en', wantTitle, wantAuthor),
  /matching catalogue epub edition\(s\) found.*no accessible published free epub partner links/i,
  'matching catalogue with no published free links reports source unavailability, not no match');
const unavailableURLs = wantUnavailable.requested;
assert.equal(unavailableURLs.filter(url => url.includes('/search?')).length, 1,
  'source does not re-run the same catalogue query on each mirror after checking free links');
assert.ok(unavailableURLs.some(url => url.includes('annas-archive.gl/md5/' + wantRows[1][0])) &&
          unavailableURLs.some(url => url.includes('annas-archive.gl/md5/' + wantRows[2][0])),
  'different credible hashes are attempted even after one record lacks free links');
assert.ok(unavailableURLs.every(url => !wantRows.slice(5, 9).some(row => url.includes('/md5/' + row[0]))),
  'failed free availability never causes an automatic wrong-language retry');
assert.ok(wantUnavailable.statuses.at(-1).includes('Matching editions found, but free download is unavailable'),
  'queue receives actionable catalogue-found-but-free-link-unavailable status');

const wantOnlyItalian = wantHarness(null, wantRows.slice(5, 9));
assert.equal(wantOnlyItalian.source.search('Want anderson', 0, 'en', wantTitle, wantAuthor).length, 0,
  'Italian-only Want catalogue must yield no English-eligible results');
assert.equal(wantOnlyItalian.requested.filter(url => url.includes('/md5/')).length, 0,
  'explicitly wrong language triggers no detail requests or foreign-language downloads');
assert.match(wantOnlyItalian.statuses.at(-1), /No credible matching EPUB editions found/,
  'Italian-only catalogue reports no eligible edition instead of unavailable source links');

const wantDuplicate = wantHarness(null, [wantRows[1], wantRows[1]]);
assert.throws(() => wantDuplicate.source.search('Want anderson', 0, 'en', wantTitle, wantAuthor),
  /no accessible published/i, 'duplicate hash cannot create false free availability');
for (const host of official) {
  assert.equal(wantDuplicate.requested.filter(url => url.includes('https://' + host + '/md5/' + wantRows[1][0])).length, 1,
    'duplicate Want hash must not be reopened on ' + host);
}

// Saved real WebKit snapshot (when available) confirms Anna's actual row order:
// cells[7] = 'en', cells[9] = 'epub'. Do not require the snapshot in shipped tests.
const savedLiveHTML = path.join(root, 'app/checks/anna-live-pk.html');
if (fs.existsSync(savedLiveHTML)) {
  const liveRecords = multilingual.source.searchCards(fs.readFileSync(savedLiveHTML, 'utf8'));
  assert.ok(liveRecords.length >= 10, 'saved real search table should expose EPUB rows');
  assert.ok(liveRecords.every(r => r.language === 'en'),
    'saved public-domain search has explicit English codes in language cell 7');
}

// Free partner pre-download: wait on the same background page until the
// official page exposes an actual file URL. Do not import HTML as an EPUB.
const finalFile = 'https://annas-archive.gl/files/pride-and-prejudice.epub';
const waiting = '<html><body><span class="js-partner-countdown">2</span><script>let waitSeconds = 2;</script></body></html>';
const ready = `<html><body><span class="bg-gray-200 break-all">${finalFile}</span></body></html>`;
let stage = waiting;
let opens = 0;
let waits = 0;
const waitingBrowser = {
  url() { return `https://annas-archive.gl/slow_download/${hash}/0/0`; },
  open() { opens++; return stage; },
  html() { return stage; },
  evaluate() { return '2'; },
  waitFor(selector) {
    assert.equal(selector, 'span.bg-gray-200.break-all');
    stage = ready;
    waits++;
    return 'true';
  }
};
const preparing = harness(() => githubConfig, waitingBrowser);
const preparedURL = preparing.source.prepareDownload(`https://annas-archive.gl/slow_download/${hash}/0/0`);
assert.equal(preparedURL, finalFile, 'published file URL must be resolved after waiting');
assert.equal(opens, 0, 'reuse the in-progress partner page, do not reset countdown');
assert.equal(waits, 1, 'wait for the published real file URL');
assert.ok(preparing.statuses.some(s => /Free partner wait/.test(s)));
assert.ok(preparing.logs.some(s => /published a final file URL/.test(s)));
assert.equal(preparing.source.publishedFileURL(waiting), null, 'countdown HTML is not a file');
assert.equal(preparing.source.publishedFileURL(ready), finalFile);
assert.throws(() => preparing.source.prepareDownload('https://evil.example/slow_download/' + hash + '/0/0'),
  /unexpected partner landing-page/i, 'arbitrary URLs must not be fetched');

// On iOS, WebKit may retain a challenge marker after accepting the ordinary
// browser verification, while the previously published link has no query.
// Keep the countdown in this SAME page instead of reopening/resetting it.
const normalizedLanding = `https://annas-archive.gl/slow_download/${hash}/0/0`;
let unexpectedReopens = 0;
const verifiedBrowser = {
  url() { return normalizedLanding + '?&check=1'; },
  html() { return ready; },
  open() {
    unexpectedReopens++;
    throw new Error('reopening would reset the free partner countdown');
  },
  waitFor() { throw new Error('link already published; do not wait'); }
};
const verified = harness(() => githubConfig, verifiedBrowser);
assert.equal(verified.source.prepareDownload(normalizedLanding), finalFile,
  'a verified same-path URL with added query params must reuse the existing WebKit page');
assert.equal(unexpectedReopens, 0, 'never reset a countdown when only WebKit query params changed');
assert.notEqual(verified.source.slowPageIdentity(normalizedLanding),
  verified.source.slowPageIdentity(normalizedLanding.replace('/0/0', '/0/1')),
  'different free partner servers must never be mistaken for an existing page');
assert.notEqual(verified.source.slowPageIdentity(normalizedLanding),
  verified.source.slowPageIdentity(normalizedLanding.replace('/' + hash + '/', '/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/')),
  'different book records must not reuse another book countdown');
assert.equal(verified.source.slowPageIdentity('https://other.example/slow_download/' + hash + '/0/0'),
  null, 'unapproved hosts must not be treated as a recognized official free partner page');

let coldOpen = 0;
const cold = harness(() => githubConfig, {
  url() { throw new Error('No page is open in the background browser.'); },
  open() { coldOpen++; return '<a href="https://b4mcx2ml.net/verified.epub">📚 Download now</a>'; },
  html() { return ''; },
  waitFor() { throw new Error('Unnecessary wait'); }
});
assert.equal(cold.source.prepareDownload(`https://annas-archive.gl/slow_download/${hash}/0/0`),
  'https://b4mcx2ml.net/verified.epub', 'cold sessions should open landing page and resolve official partner link');
assert.equal(coldOpen, 1);
assert.ok(cold.source.allowedHosts.includes('https://b4mcx2ml.net'), 'verified external partner host must be on allowlist');

// GitHub list is advisory: a new or fraudulent host cannot be granted access by data.
const unknown = harness(url => {
  if (url.includes('raw.githubusercontent.com'))
    return 'export const OFFICIAL_MIRRORS = ["annas-archive.is", "annas-archive.gl"] as const;';
  throw new Error('unavailable');
});
assert.deepEqual(Array.from(unknown.source.mirrors()), ['annas-archive.gl']);

// Even if GitHub disappears, the locally verified official list stays usable.
const offline = harness(() => { throw new Error('offline'); });
assert.deepEqual(Array.from(offline.source.mirrors()), official);
assert.equal(offline.statuses.length, 1, 'fallback mirror refresh should report a single status');

// A short-lived iOS resolver/interface failure gets one direct retry. A
// recovered request must not open WebKit or place the mirror on cooldown.
let transientAttempts = 0;
const transient = harness(url => {
  transientAttempts++;
  if (transientAttempts === 1)
    throw new Error('A server with the specified hostname could not be found.');
  return searchPage;
});
assert.equal(transient.source.fetchPage('https://annas-archive.gl/search?q=Austen'), searchPage);
assert.equal(transientAttempts, 2, 'transient transport failure should retry directly once');
assert.equal(transient.source.mirrorCooldowns['annas-archive.gl'], undefined,
  'a recovered direct request must not cool down the mirror');
assert.ok(transient.logs.some(s => /retrying direct request once/i.test(s)),
  'the recovery attempt should remain visible in diagnostics');

// Mirror membership comes only from the published official declaration, while
// transient host transport failures are runtime-local, not permanent removals.
const unavailableReasons = {
  'annas-archive.gl': 'A server with the specified hostname could not be found.',
  'annas-archive.pk': 'The request timed out.',
  'annas-archive.gd': 'The network connection was lost.'
};
const unreachable = harness(url => {
  if (url.includes('raw.githubusercontent.com')) return githubConfig;
  for (const host of official) {
    if (url.startsWith('https://' + host + '/')) throw new Error(unavailableReasons[host]);
  }
  throw new Error('Unexpected URL ' + url);
});
assert.throws(() => unreachable.source.search('Pride and Prejudice Jane Austen', 0),
  /free search is unavailable/i, 'unreachable mirrors should not masquerade as empty results');
assert.match(unreachable.statuses.at(-1), /Official mirrors unreachable \(network, DNS or TLS\)/,
  'network failures must not be misreported as only CAPTCHA/browser verification');
assert.deepEqual(Array.from(unreachable.source.orderedMirrors()), [],
  'temporarily skip mirrors that just failed with DNS, TLS, or timeout');
assert.deepEqual(Array.from(unreachable.source.mirrors()), official,
  'temporary unavailability must not change verified official mirror membership');
assert.ok(unreachable.logs.some(s => /annas-archive\.pk: connection timeout failed/i.test(s)));
assert.ok(unreachable.logs.some(s => /annas-archive\.gd: network connection failed/i.test(s)));
const requestsAfterFailure = unreachable.requested.length;
assert.throws(() => unreachable.source.search('Pride and Prejudice Jane Austen', 0),
  /official mirrors are temporarily unreachable/i,
  'immediate repeated searches should explain the temporary cooldown');
assert.equal(unreachable.requested.length, requestsAfterFailure,
  'rapid retry must not refetch known-unreachable official hosts or the GitHub list');
unreachable.source.mirrorCooldowns['annas-archive.gl'].until = Date.now() - 1;
assert.deepEqual(Array.from(unreachable.source.orderedMirrors()), ['annas-archive.gl'],
  'expired cooldown immediately restores the original official host');
const requestsBeforeSingleRecovery = unreachable.requested.length;
assert.throws(() => unreachable.source.search('Pride and Prejudice Jane Austen', 0),
  /free search is unavailable/i);
assert.deepEqual(unreachable.requested.slice(requestsBeforeSingleRecovery)
  .filter(u => u.includes('/search?')).map(u => new URL(u).hostname),
  ['annas-archive.gl', 'annas-archive.gl'],
  'retry only the host whose temporary cooldown has expired, with one bounded transport retry');
assert.equal(unreachable.source.transportFailure('The mirror requires verification in a web browser'), null,
  'browser verification is not a DNS/TLS outage');
assert.equal(unreachable.source.transportFailure('The record contains no published free partner links'), null,
  'edition-specific free-link absence is not a mirror transport outage');
assert.equal(unreachable.source.transportFailure('An SSL error has occurred and a secure connection to the server cannot be made.'),
  'TLS or connection security', 'certificate/TLS failures are classified for accurate queue diagnostics');
assert.equal(unreachable.source.transportFailure('A server with the specified hostname could not be found.'),
  'DNS resolution', 'iOS DNS resolution failure receives a specific diagnosis');

// A parking page and a bot check must never be misrepresented as empty search results.
const blocked = harness(url => {
  if (url.includes('raw.githubusercontent.com')) return githubConfig;
  if (url.includes('annas-archive.gl')) return '<title>annas-archive.gl</title><p>This domain may be for sale</p>';
  return '<script src="/.well-known/ddos-guard/js-challenge/x.js"></script>';
});
assert.throws(() => blocked.source.search('Austen', 0), /unavailable/i);
assert.match(blocked.statuses.at(-1), /Free search unavailable/);
assert.ok(blocked.logs.some(s => /All official mirrors failed/.test(s)), 'log precise search errors');

// The getter accepts only a free slow link tied to the record hash.
const falseLinks = harness(() => githubConfig);
const hostileDetail = detailPage.replace(`/slow_download/${hash}/0/0`, '/fast_download/' + hash + '/0/0');
assert.equal(falseLinks.source.slowLinks(hostileDetail, hash, 'https://annas-archive.gl').length, 0);
assert.equal(falseLinks.source.slowLinks(detailPage.replace(`/slow_download/${hash}/0/0`, '/slow_download/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/0/0'), hash, 'https://annas-archive.gl').length, 0);

// Wait hints are accepted only from a published landing page. They do not
// authorize a download, provide a credential, or trigger repeated polling.
assert.equal(falseLinks.source.partnerWaitSeconds('<script>let waitSeconds = 72;</script>'), 72);
assert.equal(falseLinks.source.partnerWaitSeconds('<p>Please wait about 2 minutes</p>'), 120);
assert.equal(falseLinks.source.partnerWaitSeconds('<script>var waitSeconds = 999999;</script>'), null);
assert.equal(falseLinks.source.partnerWaitSeconds('<p>Verification required</p>'), null);
assert.equal(falseLinks.source.waitLabel(121), '3 min');

const noEstimateURLs = [];
const noEstimate = harness(url => url.includes('raw.githubusercontent.com') ? githubConfig :
  url.includes('/md5/') ? detailPage : searchPage, {
  open(url) {
    noEstimateURLs.push(url);
    return '<html><p>Queue data is unavailable</p></html>';
  }
});
assert.equal(noEstimate.source.search('Pride and Prejudice', 0).length, 1);
assert.equal(noEstimateURLs.length, 1, 'only inspect one published wait page');
assert.match(noEstimate.statuses.at(-1), /EPUB download unverified/i);

const legacy = harness(url => url.includes('raw.githubusercontent.com') ? githubConfig :
  url.includes('/md5/') ? detailPage : searchPage, null, false);
assert.equal(legacy.source.search('Pride and Prejudice', 0).length, 1, 'older Folio versions work without status');
assert.ok(legacy.logs.length > 0, 'older Folio versions still receive diagnostics');

console.log('PASS: Folio extension v1.3.8, bounded transient transport retry, runtime-local mirror cooldown, source availability diagnostics, Want subtitle matches, language safeguards, and free countdown without verified-query resets.');
