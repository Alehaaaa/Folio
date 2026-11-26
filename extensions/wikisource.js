// Wikisource source for Folio. Searches the Wikisource edition in the book's
// language and downloads the EPUB that Wikisource's own export tool
// (ws-export, the same one behind its OPDS feeds and "Download" links) builds.
var source = {
  id: "wikisource",
  name: "Wikisource",
  description: "Public-domain classics and source texts from Wikisource, in many languages, as EPUBs built by Wikisource's own export tool.",
  version: "1.0.0",
  languages: ["*"],
  // One Wikisource per language. Folio only searches the edition in the
  // language the book is wanted in; languages not listed here are skipped.
  editions: ["en", "es", "fr", "de", "it", "pt", "ca", "nl", "sv", "no", "da", "fi", "pl", "cs", "ru",
             "uk", "tr", "el", "ja", "zh", "ko", "ar", "he", "hi", "la", "eu", "gl", "ro", "hu"],
  allowedHosts: [
    "https://ws-export.wmcloud.org",
    "https://en.wikisource.org", "https://es.wikisource.org", "https://fr.wikisource.org",
    "https://de.wikisource.org", "https://it.wikisource.org", "https://pt.wikisource.org",
    "https://ca.wikisource.org", "https://nl.wikisource.org", "https://sv.wikisource.org",
    "https://no.wikisource.org", "https://da.wikisource.org", "https://fi.wikisource.org",
    "https://pl.wikisource.org", "https://cs.wikisource.org", "https://ru.wikisource.org",
    "https://uk.wikisource.org", "https://tr.wikisource.org", "https://el.wikisource.org",
    "https://ja.wikisource.org", "https://zh.wikisource.org", "https://ko.wikisource.org",
    "https://ar.wikisource.org", "https://he.wikisource.org", "https://hi.wikisource.org",
    "https://la.wikisource.org", "https://eu.wikisource.org", "https://gl.wikisource.org",
    "https://ro.wikisource.org", "https://hu.wikisource.org"
  ],
  settings: [],
  pageSize: 10,
  // Reading every candidate's header is one request each: keep it bounded.
  detailLimit: 8,

  log: function (message) {
    if (typeof folio.log === "function") folio.log("Wikisource: " + message);
  },

  edition: function (language) {
    var code = String(language || "").toLowerCase().split(/[-_]/)[0];
    if (code === "nb" || code === "nn") code = "no";
    if (!code) code = "en";
    return this.editions.indexOf(code) >= 0 ? code : null;
  },

  api: function (lang, params) {
    var parts = [];
    for (var k in params) parts.push(k + "=" + encodeURIComponent(params[k]));
    return "https://" + lang + ".wikisource.org/w/api.php?format=json&formatversion=2&" + parts.join("&");
  },

  decode: function (value) {
    if (typeof folio.decodeHTML === "function") return folio.decodeHTML(value);
    return value.replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
      .replace(/&quot;/g, '"').replace(/&#0?39;/g, "'").replace(/&nbsp;/g, " ");
  },

  text: function (html) {
    return this.decode(String(html || "").replace(/<[^>]*>/g, " ")).replace(/\s+/g, " ").trim();
  },

  // The header microformat ws-export reads: <span id="ws-author">…</span>
  // (or class="ws-author"). Every Wikisource header template emits it.
  field: function (html, name) {
    var pattern = new RegExp("<(\\w+)\\b[^>]*\\b(?:id|class)\\s*=\\s*[\"'](?:[^\"']*\\s)?ws-" + name +
      "(?:\\s[^\"']*)?[\"'][^>]*>([\\s\\S]*?)</\\1>", "i");
    var m = html.match(pattern);
    return m ? this.text(m[2]) : "";
  },

  authors: function (value) {
    return String(value || "").split(/\s*(?:;|\/|,\s*(?=[A-ZÀ-Ý])| and | y | et | und | e )\s*/)
      .map(function (a) { return a.trim(); }).filter(Boolean);
  },

  details: function (lang, title) {
    try {
      var r = folio.fetchJSON(this.api(lang, { action: "parse", page: title, prop: "text", section: 0, redirects: 1, disablelimitreport: 1 }));
      var html = (r && r.parse && r.parse.text) || "";
      return { author: this.field(html, "author"), title: this.field(html, "title"), year: parseInt(this.field(html, "year"), 10) };
    } catch (e) {
      this.log("could not read the header of " + title + ": " + e);
      return null;
    }
  },

  exportURL: function (lang, title) {
    return "https://ws-export.wmcloud.org/?format=epub-3&lang=" + lang + "&page=" + encodeURIComponent(title.replace(/ /g, "_"));
  },

  search: function (query, page, preferredLanguage, expectedTitle, expectedAuthor) {
    var lang = this.edition(preferredLanguage);
    if (!lang) {
      this.log("no Wikisource edition for " + preferredLanguage + ".");
      return [];
    }
    var term = String(expectedTitle || query || "").split(":")[0].trim();
    if (!term) return [];
    var offset = Math.max(0, parseInt(page, 10) || 0) * this.pageSize;
    var r = folio.fetchJSON(this.api(lang, {
      action: "query", generator: "search", gsrsearch: term, gsrnamespace: 0,
      gsrlimit: this.pageSize, gsroffset: offset, redirects: 1, prop: "pageprops", ppprop: "disambiguation"
    }));
    var pages = ((r && r.query && r.query.pages) || []).slice().sort(function (a, b) {
      return (a.index || 0) - (b.index || 0);
    });
    var results = [];
    var looked = 0;
    for (var i = 0; i < pages.length && looked < this.detailLimit; i++) {
      var p = pages[i];
      // Chapters live on subpages ("Title/Chapter 1"); the export of the
      // top page already includes them. Disambiguation pages hold no text.
      if (!p.title || p.title.indexOf("/") >= 0 || (p.pageprops && "disambiguation" in p.pageprops)) continue;
      looked++;
      var info = this.details(lang, p.title);
      if (!info || !info.author) continue;
      results.push({
        id: lang + ":" + p.title,
        title: info.title || p.title,
        authors: this.authors(info.author),
        cover: null,
        year: info.year > 0 ? info.year : null,
        language: lang,
        origin: "https://" + lang + ".wikisource.org/wiki/" + encodeURIComponent(p.title.replace(/ /g, "_")),
        downloads: [{ format: "epub", url: this.exportURL(lang, p.title) }]
      });
    }
    return results;
  },

  recent: function () { return []; }
};
