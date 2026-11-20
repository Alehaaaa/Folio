/// Built-in book source extensions. Each is plain JavaScript run in its own isolated engine
/// (see Extensions.swift); it can only reach the servers listed in its own settings.
enum DefaultSources {
    static let builtIn: [(id: String, script: String)] = [("demeter", demeter), ("gutenberg", gutenberg)]

    /// Project Gutenberg's public-domain catalogue (one of Calibre's own Get Books stores),
    /// read through the Gutendex API.
    static let gutenberg = #"""
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
"""#

    /// Calibre libraries, read the way demeter (github.com/gnur/demeter) does:
    /// /ajax/search lists book ids, /ajax/books gives titles, authors and the main format to download,
    /// and a full check for new books runs at most every 12 hours per source.
    static let demeter = #"""
var source = {
  id: "demeter",
  name: "Calibre Libraries",
  description: "Browse and add books from Calibre content servers, like demeter does. Only add libraries you own or are allowed to use.",
  version: "1.0.0",
  syncIntervalHours: 12,
  settings: [
    { key: "hosts", label: "Calibre server addresses", kind: "list", placeholder: "http://192.168.1.20:8080" }
  ],

  hosts: function () {
    var list = (folio.config.hosts || []);
    var out = [];
    for (var i = 0; i < list.length; i++) {
      var m = String(list[i]).trim().match(/^(https?:\/\/[^\/?#]+)/i);
      if (m) out.push(m[1]);
    }
    return out;
  },

  toResult: function (host, id, b) {
    var downloads = [];
    var seen = {};
    var main = b.main_format || {};
    for (var f in main) {
      var fmt = f.toLowerCase();
      seen[fmt] = true;
      downloads.push({ format: fmt, url: host + decodeURIComponent(main[f]) });
    }
    var others = b.formats || [];
    for (var j = 0; j < others.length; j++) {
      var o = String(others[j]).toLowerCase();
      if (!seen[o]) { seen[o] = true; downloads.push({ format: o, url: host + "/get/" + o + "/" + id }); }
    }
    var cover = b.cover || b.thumbnail;
    return {
      id: host + "#" + id,
      title: b.title || "Untitled",
      authors: b.authors || [],
      cover: cover ? host + cover : null,
      year: b.pubdate ? parseInt(String(b.pubdate).slice(0, 4), 10) : null,
      origin: host.replace(/^https?:\/\//i, ""),
      downloads: downloads
    };
  },

  books: function (host, ids) {
    var out = [];
    for (var i = 0; i < ids.length; i += 50) {
      var chunk = ids.slice(i, i + 50);
      var r = folio.fetchJSON(host + "/ajax/books?ids=" + chunk.join(","));
      for (var k = 0; k < chunk.length; k++) {
        var b = r[String(chunk[k])];
        if (b) out.push(this.toResult(host, chunk[k], b));
      }
    }
    return out;
  },

  search: function (query, page) {
    var out = [];
    var hosts = this.hosts();
    for (var i = 0; i < hosts.length; i++) {
      try {
        var url = hosts[i] + "/ajax/search?num=40&offset=" + (page * 40) + "&sort=timestamp&sort_order=desc";
        if (query) url += "&query=" + encodeURIComponent(query);
        var s = folio.fetchJSON(url);
        out = out.concat(this.books(hosts[i], s.book_ids || []));
      } catch (e) {
        folio.log(hosts[i] + ": " + e);
      }
    }
    return out;
  },

  recent: function (page) { return this.search("", page); },

  // demeter's scrape: collect every id, keep the ones not seen on an earlier check.
  sync: function (state) {
    state = state || {};
    var fresh = [];
    var hosts = this.hosts();
    for (var i = 0; i < hosts.length; i++) {
      var host = hosts[i];
      try {
        var all = [];
        var offset = 0;
        while (offset < 50000) {
          var s = folio.fetchJSON(host + "/ajax/search?num=500&offset=" + offset);
          var ids = s.book_ids || [];
          all = all.concat(ids);
          offset += ids.length;
          if (!ids.length || offset >= (s.total_num || 0)) break;
        }
        var seen = {};
        var before = state[host] || [];
        for (var j = 0; j < before.length; j++) seen[before[j]] = true;
        var newIDs = all.filter(function (x) { return !seen[x]; });
        if (before.length === 0) newIDs = newIDs.slice(0, 200);
        fresh = fresh.concat(this.books(host, newIDs));
        state[host] = all;
      } catch (e) {
        folio.log(host + ": " + e);
      }
    }
    return { books: fresh, state: state };
  }
};
"""#
}
