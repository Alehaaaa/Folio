// Folio source extension. Independent of Folio's application code and of Calibre.
// Free-only Anna's Archive search and Slow Partner EPUB links.
// Official mirror list: https://github.com/guillem-gelabert/annas-mcp/blob/main/src/config.ts
// The extension makes no member API requests, uses no accounts and downloads no private code.

var source = {
  id: "annas-archive-free",
  name: "Anna's Archive",
  description: "Anna's Archive EPUB search and free Slow Partner links, with official mirror fallback. No key, membership or paid API. Some mirrors require browser verification.",
  version: "1.0.0",
  allowedHosts: [
    "https://raw.githubusercontent.com",
    "https://annas-archive.gl",
    "https://annas-archive.pk",
    "https://annas-archive.gd"
  ],
  settings: [],

  // Explicit host boundary, independent of anything downloaded from GitHub.
  trustedHosts: ["annas-archive.gl", "annas-archive.pk", "annas-archive.gd"],
  githubList: "https://raw.githubusercontent.com/guillem-gelabert/annas-mcp/main/src/config.ts",
  mirrorCache: null,
  preferredMirror: "",
  maxResults: 12,

  mirrors: function () {
    var now = Date.now();
    if (this.mirrorCache && now - this.mirrorCache.checkedAt < 86400000)
      return this.mirrorCache.hosts.slice();

    var hosts = this.trustedHosts.slice();
    try {
      var definition = folio.fetchText(this.githubList);
      // Parse just the OFFICIAL_MIRRORS constant, never arbitrary URLs from README text.
      var match = definition.match(/\bOFFICIAL_MIRRORS\s*=\s*\[([^\]]+)\]/);
      if (!match) throw new Error("Official mirror declaration missing");
      var names = match[1].match(/["']annas-archive\.[a-z]{2,}["']/gi) || [];
      var verified = [];
      for (var i = 0; i < names.length; i++) {
        var host = names[i].slice(1, -1).toLowerCase();
        if (this.trustedHosts.indexOf(host) >= 0 && verified.indexOf(host) < 0)
          verified.push(host);
      }
      if (!verified.length) throw new Error("No supported official mirrors in declaration");
      hosts = verified;
    } catch (error) {
      folio.log("GitHub mirror refresh unavailable; using known official hosts: " + error);
    }
    this.mirrorCache = {checkedAt: now, hosts: hosts};
    return hosts.slice();
  },

  orderedMirrors: function () {
    var hosts = this.mirrors();
    if (this.preferredMirror && hosts.indexOf(this.preferredMirror) > 0) {
      hosts.splice(hosts.indexOf(this.preferredMirror), 1);
      hosts.unshift(this.preferredMirror);
    }
    return hosts;
  },

  unescape: function (value) {
    var named = {amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " "};
    return String(value || "").replace(/&(#x[0-9a-f]+|#[0-9]+|[a-z]+);/gi, function (entire, key) {
      key = key.toLowerCase();
      if (key.charAt(0) === "#") {
        var code = key.charAt(1) === "x" ? parseInt(key.slice(2), 16) : parseInt(key.slice(1), 10);
        return code > 31 && code < 65536 ? String.fromCharCode(code) : " ";
      }
      return named[key] || entire;
    });
  },

  plainText: function (html) {
    return this.unescape(String(html || "")
      .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, "")
      .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, "")
      .replace(/<[^>]+>/g, " ")
      .replace(/\s+/g, " ").trim());
  },

  verifyPage: function (html, pageType) {
    if (/\.well-known\/ddos-guard\/js-challenge\/|just a moment|attention required|cf-challenge-running/i.test(html))
      throw new Error("The mirror requires verification in a web browser");
    if (/this domain may be for sale|forsale\.min\.js/i.test(html))
      throw new Error("This domain is parked and is not an Anna's Archive mirror");
    if (pageType === "search" && !/(\/md5\/[0-9a-f]{32}|no files found|no results found|no results)/i.test(html))
      throw new Error("Unrecognized search page; possibly a browser check");
    if (pageType === "detail" && !/js-download-link|\/slow_download\//i.test(html))
      throw new Error("The record contains no published free partner links");
  },

  // Parse archive search cards from the older /md5/<hash> layout. The original
  // Calibre plugin depends on an HTML table; cards also work without Python/lxml.
  searchCards: function (html) {
    this.verifyPage(html, "search");
    var links = [];
    var pattern = /<a\b[^>]*href\s*=\s*["'](?:https?:\/\/[^\/"']+)?\/md5\/([0-9a-f]{32})["'][^>]*>/gi;
    var match;
    while ((match = pattern.exec(html)) !== null) {
      links.push({hash: match[1].toLowerCase(), at: match.index});
    }
    var records = [];
    var seen = {};
    for (var i = 0; i < links.length; i++) {
      var id = links[i].hash;
      if (seen[id]) continue;
      seen[id] = true;
      var next = html.length;
      for (var j = i + 1; j < links.length; j++) {
        if (links[j].hash !== id) { next = links[j].at; break; }
      }
      var block = html.slice(links[i].at, Math.min(next, links[i].at + 20000));
      var title = "";
      var anchorPattern = /<a\b([^>]*)>([\s\S]*?)<\/a>/gi;
      var anchor;
      while ((anchor = anchorPattern.exec(block)) !== null) {
        if (anchor[1].toLowerCase().indexOf("/md5/" + id) < 0) continue;
        var proposed = this.plainText(anchor[2]);
        if (proposed && proposed.length > title.length && proposed.length < 250) title = proposed;
      }
      if (!title) continue;
      var author = "";
      var authorTag = block.match(/<a\b[^>]*href=["'][^"']*\/search[^"']*["'][^>]*>[\s\S]*?mdi--user-edit[\s\S]*?<\/a>/i);
      if (authorTag) author = this.plainText(authorTag[0]);
      var meta = block.match(/<div\b[^>]*class=["'][^"']*text-gray-800[^"']*["'][^>]*>([\s\S]*?)<\/div>/i);
      var info = meta ? this.plainText(meta[1]) : "";
      var format = info.match(/\b(epub|pdf|mobi|azw3|cbz|txt)\b/i);
      if (!format || format[1].toLowerCase() !== "epub") continue;
      var year = info.match(/\b(?:18|19|20)[0-9]{2}\b/);
      records.push({
        hash: id, title: title, author: author,
        year: year ? parseInt(year[0], 10) : null
      });
    }
    if (!records.length && !/no files found|no results found|no results/i.test(html))
      throw new Error("The site changed its search layout or returned a verification page");
    return records;
  },

  // Extract only actual free links from the record, never generate guessed paths.
  slowLinks: function (html, hash, baseURL) {
    this.verifyPage(html, "detail");
    var links = [];
    var anchors = /<a\b[^>]*>/gi;
    var tag;
    while ((tag = anchors.exec(html)) !== null) {
      if (!/\bjs-download-link\b/i.test(tag[0])) continue;
      var attr = tag[0].match(/\bhref\s*=\s*["']([^"']+)["']/i);
      if (!attr) continue;
      var path = this.unescape(attr[1]);
      var required = new RegExp("^/slow_download/" + hash + "/[0-9]+/[0-9]+(?:\\?.*)?$", "i");
      if (!required.test(path)) continue;
      var url = baseURL + path;
      if (!links.some(function (item) { return item.url === url; }))
        links.push({format: "epub", url: url});
    }
    return links;
  },

  resolveFreeEPUB: function (hash, firstHost) {
    var hosts = this.orderedMirrors();
    if (firstHost && hosts.indexOf(firstHost) > 0) {
      hosts.splice(hosts.indexOf(firstHost), 1);
      hosts.unshift(firstHost);
    }
    for (var i = 0; i < hosts.length; i++) {
      var host = hosts[i];
      try {
        var origin = "https://" + host;
        var html = folio.fetchText(origin + "/md5/" + hash);
        var links = this.slowLinks(html, hash, origin);
        if (links.length) {
          this.preferredMirror = host;
          return links;
        }
      } catch (error) {
        folio.log(host + " free detail: " + error);
      }
    }
    return [];
  },

  search: function (query, page) {
    query = String(query || "").trim();
    if (!query) return [];
    page = Math.max(0, Math.floor(Number(page) || 0));
    var hosts = this.orderedMirrors();
    var failures = [];
    for (var i = 0; i < hosts.length; i++) {
      var host = hosts[i];
      try {
        var origin = "https://" + host;
        var url = origin + "/search?q=" + encodeURIComponent(query) + "&display=table&ext=epub&page=" + (page + 1);
        var cards = this.searchCards(folio.fetchText(url));
        this.preferredMirror = host;
        var results = [];
        for (var j = 0; j < cards.length && j < this.maxResults; j++) {
          var card = cards[j];
          var files = this.resolveFreeEPUB(card.hash, host);
          if (!files.length) continue;
          results.push({
            id: card.hash,
            title: card.title,
            authors: card.author ? [card.author] : [],
            year: card.year,
            origin: host,
            downloads: files
          });
        }
        if (cards.length && !results.length)
          throw new Error("Search worked, but free EPUB partner links could not be resolved (browser verification may be required)");
        return results;
      } catch (error) {
        failures.push(host + ": " + error);
        folio.log(host + " search: " + error);
      }
    }
    throw new Error("Anna's Archive free search is unavailable. " + failures.join("; "));
  },

  // A blank query is not sent to a scrape server; Folio asks search(query) when
  // looking up a particular title, and this extension is intended for that flow.
  recent: function () { return []; }
};
