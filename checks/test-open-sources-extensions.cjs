// Offline checks for the Wikisource, Internet Archive and OAPEN sources:
// request shape, parsing, language handling and download links.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

function load(file, fetchText) {
  const requests = [];
  const context = { folio: { fetchText(url) { requests.push(url); return fetchText(url); }, log() {} } };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, "../extensions", file), "utf8"), context);
  vm.runInNewContext("folio.fetchJSON = function (u) { return JSON.parse(folio.fetchText(u)); };", context);
  return { source: context.source, requests };
}

// Wikisource
{
  const { source, requests } = load("wikisource.js", (url) => {
    if (url.includes("action=query")) return JSON.stringify({ query: { pages: [
      { title: "Orgueil et Préjugés (Austen)/Chapitre 1", index: 1 },
      { title: "Orgueil et Préjugés (Austen)", index: 2 },
      { title: "Orgueil", index: 3, pageprops: { disambiguation: "" } },
      { title: "Sans en-tête", index: 4 }
    ] } });
    if (url.includes("Sans%20en-t")) return JSON.stringify({ parse: { text: "<p>Rien</p>" } });
    return JSON.stringify({ parse: { text:
      '<div id="ws-data" class="ws-noexport"><span id="ws-title">Orgueil et Préjugés</span>' +
      '<span class="ws-author">Jane Austen</span><span id="ws-year">1813</span></div>' } });
  });
  const results = source.search("Orgueil Austen", 0, "fr", "Orgueil et Préjugés", "Jane Austen");
  assert.match(requests[0], /^https:\/\/fr\.wikisource\.org\/w\/api\.php\?/);
  assert.match(requests[0], /gsrsearch=Orgueil%20et%20Pr%C3%A9jug%C3%A9s/);
  assert.equal(results.length, 1);
  assert.equal(results[0].title, "Orgueil et Préjugés");
  assert.deepEqual(Array.from(results[0].authors), ["Jane Austen"]);
  assert.equal(results[0].language, "fr");
  assert.equal(results[0].year, 1813);
  assert.equal(results[0].downloads[0].format, "epub");
  assert.equal(results[0].downloads[0].url,
    "https://ws-export.wmcloud.org/?format=epub-3&lang=fr&page=Orgueil_et_Pr%C3%A9jug%C3%A9s_(Austen)");
  for (const url of [requests[0], results[0].downloads[0].url]) {
    assert.ok(source.allowedHosts.includes(new URL(url).origin), url);
  }
  assert.equal(source.search("x", 0, "xx", "x").length, 0, "no edition, no request");
  assert.equal(source.edition("nb"), "no");
  assert.equal(source.editions.length + 1, source.allowedHosts.length);
  console.log("PASS Wikisource search, header metadata, language edition and EPUB export link");
}

// Internet Archive
{
  const { source, requests } = load("internet-archive.js", (url) => {
    if (url.includes("/advancedsearch.php")) return JSON.stringify({ response: { docs: [
      { identifier: "prideprejudice00aust", title: "Pride and Prejudice", creator: ["Austen, Jane", "Jane Austen"],
        language: ["eng"], year: "1813", downloads: 5400, format: ["EPUB", "Text PDF", "DjVuTXT"] },
      { identifier: "orgueil00aust", title: "Orgueil et préjugés", creator: "Jane Austen", language: "French",
        downloads: 20, format: ["EPUB"] },
      { identifier: "scans-only", title: "Pride and Prejudice", creator: "Jane Austen", format: ["DjVuTXT"] },
      { identifier: "../bad", title: "Pride and Prejudice", format: ["EPUB"] }
    ] } });
    if (url.endsWith("/metadata/prideprejudice00aust")) return JSON.stringify({ metadata: {}, files: [
      { name: "prideprejudice00aust_lcp.epub", format: "LCP Encrypted EPUB", source: "derivative" },
      { name: "prideprejudice00aust.epub", format: "EPUB", source: "derivative" },
      { name: "Pride and Prejudice.epub", format: "EPUB", source: "original" },
      { name: "prideprejudice00aust.pdf", format: "Text PDF", source: "derivative" }
    ] });
    if (url.endsWith("/metadata/lent")) return JSON.stringify({ metadata: { "access-restricted-item": "true" }, files: [] });
    throw new Error("unexpected " + url);
  });
  const results = source.search("Pride Austen", 0, "en", "Pride and Prejudice: A Novel", "Jane Austen");
  const q = decodeURIComponent(requests[0].split("q=")[1].split("&")[0]);
  assert.match(q, /^title:\("Pride and Prejudice"\) AND creator:\(Austen\)/);
  assert.match(q, /NOT access-restricted-item:true/);
  assert.equal(results.length, 1, "French edition, scan-only and unsafe ids are left out");
  assert.equal(results[0].language, "eng");
  assert.equal(results[0].downloadCount, 5400);
  assert.deepEqual(Array.from(results[0].downloads, (d) => d.format), ["epub", "pdf"]);
  assert.equal(source.prepareDownload(results[0].downloads[0].url),
    "https://archive.org/download/prideprejudice00aust/Pride%20and%20Prejudice.epub");
  assert.equal(source.prepareDownload(results[0].downloads[1].url),
    "https://archive.org/download/prideprejudice00aust/prideprejudice00aust.pdf");
  assert.throws(() => source.prepareDownload("https://archive.org/details/lent?folio-format=epub"), /borrowed/);
  assert.throws(() => source.prepareDownload("https://evil.example/details/x?folio-format=epub"), /Invalid/);
  console.log("PASS Internet Archive open-access filter, language, original EPUB first, no borrow-only files");
}

// OAPEN
{
  const { source, requests } = load("oapen.js", () => JSON.stringify([
    { handle: "20.500.12657/1", name: "Open Book",
      metadata: [{ key: "dc.title", value: "Open Book" }, { key: "dc.contributor.author", value: "Doe, Jane" },
                 { key: "dc.language", value: "English" }, { key: "dc.date.issued", value: "2020-05-01" }],
      bitstreams: [
        { bundleName: "ORIGINAL", name: "book.pdf", mimeType: "application/pdf", retrieveLink: "/bitstreams/aa-11/retrieve" },
        { bundleName: "ORIGINAL", name: "book.epub", mimeType: "application/epub+zip", retrieveLink: "/rest/bitstreams/bb-22/retrieve" },
        { bundleName: "THUMBNAIL", name: "book.pdf.jpg", mimeType: "image/jpeg", retrieveLink: "/bitstreams/cc-33/retrieve" },
        { bundleName: "LICENSE", name: "license.txt", mimeType: "text/plain", retrieveLink: "/bitstreams/dd-44/retrieve" },
        { bundleName: "ORIGINAL", name: "x.epub", mimeType: "application/epub+zip", retrieveLink: "https://evil.example/x" }
      ] },
    { handle: "20.500.12657/2", name: "No files", metadata: [], bitstreams: [] }
  ]));
  const results = source.search("Open", 1, "en", "Open Book");
  assert.match(requests[0], /^https:\/\/library\.oapen\.org\/rest\/search\?query=Open%20Book&expand=metadata,bitstreams&limit=20&offset=20$/);
  assert.equal(results.length, 1);
  assert.deepEqual(Array.from(results[0].authors), ["Jane Doe"]);
  assert.equal(results[0].language, "English");
  assert.equal(results[0].year, 2020);
  assert.equal(results[0].cover, "https://library.oapen.org/rest/bitstreams/cc-33/retrieve");
  assert.deepEqual(Array.from(results[0].downloads, (d) => d.format + " " + d.url), [
    "pdf https://library.oapen.org/rest/bitstreams/aa-11/retrieve",
    "epub https://library.oapen.org/rest/bitstreams/bb-22/retrieve"
  ]);
  console.log("PASS OAPEN search, metadata, cover and EPUB/PDF links on the library's own host");
}

// OAPEN failures from a real phone log: a 403 refusal and a stall each end
// the OAPEN search at once with one short reason, and are not retried.
{
  for (const [failure, expected] of [
    ["library.oapen.org answered 403", /turning away automated searches/],
    ["The request timed out.", /did not answer in time/],
    ["library.oapen.org answered 429", /turning away automated searches/],
  ]) {
    const { source, requests } = load("oapen.js", () => { throw new Error(failure); });
    assert.throws(() => source.search("Sistemas críticos", 0), expected);
    assert.equal(requests.length, 1, "one request, no retry storm");
  }
  const html = load("oapen.js", () => "<html>Just a moment…</html>");
  assert.throws(() => html.source.search("Sistemas críticos", 0), /unexpected page/);
  console.log("PASS OAPEN refusals, timeouts and challenge pages fail fast with one readable reason");
}
