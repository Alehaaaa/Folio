// OAPEN Library source for Folio: peer-reviewed open-access academic books,
// read through the library's public REST API. Every file is free to download.
var source = {
  id: "oapen",
  name: "OAPEN",
  description: "Open-access academic books from the OAPEN Library, free to download as EPUB or PDF.",
  version: "1.1.0",
  languages: ["*"],
  allowedHosts: ["https://library.oapen.org"],
  settings: [],
  host: "https://library.oapen.org",
  pageSize: 20,

  meta: function (item, key) {
    var out = [];
    var list = item.metadata || [];
    for (var i = 0; i < list.length; i++) {
      if (list[i] && list[i].key === key && list[i].value) out.push(String(list[i].value).trim());
    }
    return out;
  },

  // OAPEN lists people as "Surname, Given".
  person: function (name) {
    var p = String(name).split(/,\s*/);
    return p.length === 2 && p[1] ? p[1] + " " + p[0] : String(name);
  },

  link: function (bitstream) {
    var path = String(bitstream.retrieveLink || "");
    if (!/^\/(?:rest\/)?bitstreams\/[A-Za-z0-9-]+\/retrieve$/.test(path)) return null;
    return this.host + (path.indexOf("/rest/") === 0 ? path : "/rest" + path);
  },

  format: function (bitstream) {
    var mime = String(bitstream.mimeType || "").toLowerCase();
    var name = String(bitstream.name || "").toLowerCase();
    if (mime === "application/epub+zip" || /\.epub$/.test(name)) return "epub";
    if (mime === "application/pdf" || /\.pdf$/.test(name)) return "pdf";
    return null;
  },

  toResult: function (item) {
    var downloads = [], cover = null;
    var streams = item.bitstreams || [];
    for (var i = 0; i < streams.length; i++) {
      var b = streams[i];
      var url = this.link(b);
      if (!url) continue;
      if (b.bundleName === "THUMBNAIL") { cover = cover || url; continue; }
      if (b.bundleName && b.bundleName !== "ORIGINAL") continue;
      var format = this.format(b);
      if (format) downloads.push({ format: format, url: url });
    }
    if (!downloads.length) return null;
    var people = this.meta(item, "dc.contributor.author");
    if (!people.length) people = this.meta(item, "dc.contributor.editor");
    var year = parseInt((this.meta(item, "dc.date.issued")[0] || "").slice(0, 4), 10);
    return {
      id: String(item.handle || item.uuid || item.name),
      title: this.meta(item, "dc.title")[0] || item.name || "Untitled",
      authors: people.map(this.person),
      cover: cover,
      year: year > 0 ? year : null,
      language: this.meta(item, "dc.language")[0] || null,
      origin: item.handle ? this.host + "/handle/" + item.handle : this.host,
      downloads: downloads
    };
  },

  // OAPEN is under heavy bot traffic and sometimes refuses (403) or stalls.
  // Folio respects a refusal: one short request, then a short readable reason,
  // and no retry within this search. Other sources carry on.
  fetchItems: function (url) {
    try {
      var text = typeof folio.fetchWith === "function"
        ? folio.fetchWith(url, JSON.stringify({headers: {"Accept": "application/json"}, timeout: 15}))
        : folio.fetchText(url);
      return JSON.parse(text);
    } catch (e) {
      var message = String((e && e.message) || e).replace(/^Error: /, "");
      if (/\b(?:403|429)\b/.test(message)) throw new Error("OAPEN is turning away automated searches right now; skipped.");
      if (/timed? ?out/i.test(message)) throw new Error("OAPEN did not answer in time; skipped.");
      if (/JSON|Unexpected token/i.test(message)) throw new Error("OAPEN sent an unexpected page instead of results; skipped.");
      throw new Error(message);
    }
  },

  search: function (query, page, preferredLanguage, expectedTitle) {
    var term = String(expectedTitle || query || "").trim();
    if (!term) return [];
    var offset = Math.max(0, parseInt(page, 10) || 0) * this.pageSize;
    var items = this.fetchItems(this.host + "/rest/search?query=" + encodeURIComponent(term)
      + "&expand=metadata,bitstreams&limit=" + this.pageSize + "&offset=" + offset);
    var results = [];
    for (var i = 0; i < (items || []).length; i++) {
      var r = this.toResult(items[i]);
      if (r) results.push(r);
    }
    return results;
  },

  recent: function () { return []; }
};
