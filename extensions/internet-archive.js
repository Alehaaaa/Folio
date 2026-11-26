// Internet Archive source for Folio. Searches openly downloadable texts and
// fetches the EPUB the item publishes. Lending-library (borrow-only) items
// and DRM-protected EPUBs are never offered.
var source = {
  id: "internet-archive",
  name: "Internet Archive",
  description: "Openly downloadable books from the Internet Archive, in any language. Borrow-only and DRM-protected items are left out.",
  version: "1.0.0",
  languages: ["*"],
  allowedHosts: ["https://archive.org"],
  settings: [],
  host: "https://archive.org",
  pageSize: 25,

  log: function (message) {
    if (typeof folio.log === "function") folio.log("Internet Archive: " + message);
  },

  // The archive's language field holds codes ("eng", "spa", "fr") or names
  // ("English", "Español"). Folio reads both, so pass the first one through.
  language: function (value) {
    var list = Array.isArray(value) ? value : (value ? [value] : []);
    for (var i = 0; i < list.length; i++) {
      var v = String(list[i] || "").trim();
      if (v) return v;
    }
    return null;
  },

  // ISO 639-2 codes and English names Folio may ask for, to keep other
  // languages out before Folio's own check of every result.
  codes: {
    en: ["eng", "english", "en"], es: ["spa", "spanish", "español", "es"], fr: ["fre", "fra", "french", "français", "fr"],
    de: ["ger", "deu", "german", "deutsch", "de"], it: ["ita", "italian", "italiano", "it"],
    pt: ["por", "portuguese", "português", "pt"], ca: ["cat", "catalan", "català", "ca"],
    nl: ["dut", "nld", "dutch", "nederlands", "nl"], ru: ["rus", "russian", "ru"], pl: ["pol", "polish", "pl"]
  },

  wrongLanguage: function (value, wanted) {
    if (!value || !wanted) return false;
    var known = this.codes[String(wanted).toLowerCase().split(/[-_]/)[0]];
    if (!known) return false;
    var v = String(value).toLowerCase();
    for (var code in this.codes) {
      if (this.codes[code].indexOf(v) >= 0) return this.codes[code] !== known;
    }
    return false;
  },

  quote: function (value) {
    return '"' + String(value).replace(/["\\]/g, " ").replace(/\s+/g, " ").trim() + '"';
  },

  list: function (value) {
    if (Array.isArray(value)) return value.map(String);
    return value ? [String(value)] : [];
  },

  search: function (query, page, preferredLanguage, expectedTitle, expectedAuthor) {
    var title = String(expectedTitle || "").split(":")[0].trim();
    var free = String(query || "").trim();
    if (!title && !free) return [];
    var q = title ? "title:(" + this.quote(title) + ")" : "(" + free.replace(/[()"\\]/g, " ") + ")";
    var last = String(expectedAuthor || "").trim().split(/\s+/).pop();
    if (title && last) q += " AND creator:(" + last.replace(/[()"\\:]/g, " ") + ")";
    // Only texts with an open EPUB or PDF: no lending-library items.
    q += " AND mediatype:texts AND format:(EPUB OR \"Text PDF\") AND NOT access-restricted-item:true";
    var url = this.host + "/advancedsearch.php?q=" + encodeURIComponent(q)
      + ["identifier", "title", "creator", "language", "year", "date", "downloads", "format"]
        .map(function (f) { return "&fl%5B%5D=" + f; }).join("")
      + "&sort%5B%5D=" + encodeURIComponent("downloads desc")
      + "&rows=" + this.pageSize + "&page=" + (Math.max(0, parseInt(page, 10) || 0) + 1) + "&output=json";
    var r = folio.fetchJSON(url);
    var docs = (r && r.response && r.response.docs) || [];
    var results = [];
    for (var i = 0; i < docs.length; i++) {
      var d = docs[i];
      if (!d.identifier || !/^[A-Za-z0-9._-]+$/.test(d.identifier)) continue;
      var language = this.language(d.language);
      if (this.wrongLanguage(language, preferredLanguage)) continue;
      var formats = this.list(d.format);
      var downloads = [];
      if (formats.indexOf("EPUB") >= 0) downloads.push({ format: "epub", url: this.host + "/details/" + d.identifier + "?folio-format=epub" });
      if (formats.indexOf("Text PDF") >= 0) downloads.push({ format: "pdf", url: this.host + "/details/" + d.identifier + "?folio-format=pdf" });
      if (!downloads.length) continue;
      var year = parseInt(d.year || String(d.date || "").slice(0, 4), 10);
      results.push({
        id: d.identifier,
        title: this.list(d.title)[0] || d.identifier,
        authors: this.list(d.creator),
        cover: this.host + "/services/img/" + d.identifier,
        year: year > 0 ? year : null,
        downloadCount: typeof d.downloads === "number" ? d.downloads : null,
        language: language,
        origin: this.host + "/details/" + d.identifier,
        downloads: downloads
      });
    }
    return results;
  },

  // The item's file list names the real EPUB or PDF. A file the uploader
  // supplied wins over one the archive generated from page scans, and
  // encrypted (borrow-only) files are never used.
  prepareDownload: function (url) {
    var m = String(url).match(/^https:\/\/archive\.org\/details\/([A-Za-z0-9._-]+)\?folio-format=(epub|pdf)$/);
    if (!m) throw new Error("Invalid Internet Archive item link.");
    var id = m[1], format = m[2];
    var meta = folio.fetchJSON(this.host + "/metadata/" + id);
    if (meta && meta.metadata && String(meta.metadata["access-restricted-item"]) === "true") {
      throw new Error("This Internet Archive item can only be borrowed.");
    }
    var files = (meta && meta.files) || [];
    var wanted = format === "epub" ? ["EPUB"] : ["Text PDF", "Additional Text PDF", "Image Container PDF"];
    var best = null, bestScore = -1;
    for (var i = 0; i < files.length; i++) {
      var f = files[i];
      var name = String(f.name || "");
      if (!name || name.indexOf("..") >= 0 || /encrypted|lcp|acsm/i.test(String(f.format) + " " + name)) continue;
      var score = wanted.indexOf(f.format);
      if (score < 0 && !(new RegExp("\\." + format + "$", "i")).test(name)) continue;
      // Original uploads first, then the archive's derived file.
      var s = (f.source === "original" ? 10 : 0) + (score < 0 ? 0 : wanted.length - score);
      if (s > bestScore) { best = name; bestScore = s; }
    }
    if (!best) throw new Error("This Internet Archive item has no open " + format.toUpperCase() + " file.");
    return this.host + "/download/" + id + "/" + best.split("/").map(encodeURIComponent).join("/");
  },

  recent: function () { return []; }
};
