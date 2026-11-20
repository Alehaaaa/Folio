var source = {
  id: "gutenberg",
  name: "Project Gutenberg",
  description: "Over 70,000 free public-domain books from Project Gutenberg, one of the stores Calibre's Get Books searches.",
  version: "1.1.0",
  // gutenberg.pglaf.org is Project Gutenberg's own mirror; www.gutenberg.org often answers 503 (busy).
  allowedHosts: ["https://gutendex.com", "https://gutenberg.pglaf.org", "https://www.gutenberg.org"],
  mirror: "https://gutenberg.pglaf.org/cache/epub/",
  settings: [],

  toResult: function (b) {
    var f = b.formats || {};
    var m = this.mirror + b.id + "/pg" + b.id;
    var downloads = [];
    if (f["application/epub+zip"]) downloads.push({ format: "epub", url: m + "-images-3.epub" });
    if (f["text/plain; charset=utf-8"] || f["text/plain"]) downloads.push({ format: "txt", url: m + ".txt" });
    for (var k in f) {
      var u = f[k];
      if (/\.zip$/.test(u)) continue;
      if (k.indexOf("application/epub+zip") === 0) downloads.push({ format: "epub", url: u });
      else if (k.indexOf("application/pdf") === 0) downloads.push({ format: "pdf", url: u });
      else if (k.indexOf("text/plain") === 0) downloads.push({ format: "txt", url: u });
      else if (k.indexOf("text/html") === 0) downloads.push({ format: "html", url: u });
    }
    var authors = (b.authors || []).map(function (a) {
      var p = String(a.name || "").split(", ");
      return p.length === 2 ? p[1] + " " + p[0] : (a.name || "");
    });
    return {
      id: "pg" + b.id,
      title: b.title || "Untitled",
      authors: authors,
      cover: f["image/jpeg"] ? m + ".cover.medium.jpg" : null,
      year: null,
      origin: "gutenberg.org",
      downloads: downloads
    };
  },

  list: function (url) {
    var r = folio.fetchJSON(url);
    var out = [];
    var items = r.results || [];
    for (var i = 0; i < items.length; i++) out.push(this.toResult(items[i]));
    return out;
  },

  search: function (query, page) {
    return this.list("https://gutendex.com/books/?search=" + encodeURIComponent(query) + "&page=" + (page + 1));
  },

  recent: function (page) {
    return this.list("https://gutendex.com/books/?sort=popular&page=" + (page + 1));
  }
};