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
