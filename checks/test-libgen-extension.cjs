const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const hash = "0123456789abcdef0123456789abcdef";
const otherHash = "ffffffffffffffffffffffffffffffff";
const row = (format, url) => `<tr>
  <td><a href="/edition.php?id=12">Pride &amp; Prejudice</a><i>series label</i></td>
  <td><a href="/author.php?id=1">Jane Austen</a></td>
  <td>Publisher</td><td>1813</td><td>English</td><td>300</td><td>1 MB</td>
  <td>${format}</td><td><a href="${url}">LibGen</a></td>
</tr>`;
const search = `<table id="tablelibgen">
  ${row("EPUB", "ads.php?md5=" + hash)}
  ${row("EPUB", "/ads.php?md5=" + hash)}
  ${row("MOBI", "/ads.php?md5=" + otherHash)}
  ${row("PDF", "https://example.org/ads.php?md5=" + otherHash)}
</table>`;
const requests = [];
const context = { folio: { fetchText(url) {
  requests.push(url);
  if (url.includes("/index.php?")) return search;
  return `<a href="https://example.org/get.php?md5=${hash}&amp;key=blocked">GET</a>
          <a href="/get.php?md5=${otherHash}&amp;key=wrong">GET</a>
          <a href="get.php?md5=${hash}&amp;key=published">GET</a>`;
}} };
vm.runInNewContext(fs.readFileSync(path.join(__dirname, "../extensions/libgen.js"), "utf8"), context);
const source = context.source;
const results = source.search("Pride and Prejudice Jane Austen", 1, "en", "Pride and Prejudice");
assert.equal(results.length, 1);
assert.equal(results[0].title, "Pride & Prejudice");
assert.equal(results[0].authors[0], "Jane Austen");
assert.equal(results[0].language, "English");
assert.equal(results[0].downloads[0].format, "epub");
assert.match(requests[0], /req=Pride%20and%20Prejudice.*page=2$/);
assert.equal(source.prepareDownload(results[0].downloads[0].url),
  `https://libgen.li/get.php?md5=${hash}&key=published`);
assert.throws(() => source.prepareDownload(`https://example.org/ads.php?md5=${hash}`), /Invalid/);
context.folio.fetchText = () => "<title>Site Unavailable</title>";
assert.throws(() => source.search("Pride"), /unavailable/);
console.log("PASS LibGen catalogue, pagination, link validation and unavailable-source handling");

// A blocked mirror (403) falls through to the next official mirror, and the
// download page is then read on the mirror that served it.
const tried = [];
context.folio.fetchText = (url) => {
  tried.push(url);
  if (url.startsWith("https://libgen.li/") || url.startsWith("https://libgen.gl/")) throw new Error("libgen.li answered 403");
  if (url.includes("/index.php?")) return search;
  return `<a href="get.php?md5=${hash}&amp;key=mirror">GET</a>`;
};
source.host = "https://libgen.li";
const mirrored = source.search("Pride and Prejudice", 0, "en", "Pride and Prejudice");
assert.equal(mirrored.length, 1);
assert.equal(source.host, "https://libgen.vg");
assert.ok(mirrored[0].downloads[0].url.startsWith("https://libgen.vg/ads.php?md5="));
assert.equal(source.prepareDownload(mirrored[0].downloads[0].url), `https://libgen.vg/get.php?md5=${hash}&key=mirror`);
context.folio.fetchText = () => { throw new Error("answered 403"); };
assert.throws(() => source.search("Pride"), /No mirror answered.*403/);
console.log("PASS LibGen mirror failover after a 403 and a clear error when every mirror is blocked");

// With folio.fetchFirst, every mirror is asked at once; the first readable
// answer wins and later requests go straight to that mirror.
source.host = "https://libgen.li";
source.confirmed = false;
const raced = [];
context.folio.fetchFirst = (urlsJSON, optionsJSON) => {
  const urls = JSON.parse(urlsJSON);
  raced.push({ urls, options: JSON.parse(optionsJSON) });
  const url = urls.find((u) => u.startsWith("https://libgen.gl/"));
  return JSON.stringify({ url, text: search });
};
context.folio.fetchText = (url) => {
  if (url.includes("/index.php?")) return search;
  return `<a href="get.php?md5=${hash}&amp;key=raced">GET</a>`;
};
const fast = source.search("Pride and Prejudice", 0, "en", "Pride and Prejudice");
assert.equal(fast.length, 1);
assert.equal(raced.length, 1);
assert.equal(raced[0].urls.length, 5);
assert.equal(raced[0].options.timeout, 12);
assert.equal(source.host, "https://libgen.gl");
source.search("Pride and Prejudice", 0, "en", "Pride and Prejudice");
assert.equal(raced.length, 1, "a confirmed mirror is used directly");
source.confirmed = false;
context.folio.fetchFirst = () => { throw new Error("libgen.li: Timed out | libgen.gl: Timed out"); };
assert.throws(() => source.search("Pride"), /No mirror answered \(li, gl: timed out\)/);
console.log("PASS LibGen races its mirrors and keeps the fastest");
