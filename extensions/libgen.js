// Library Genesis catalogue source for Folio. Uses links the provider publishes.
var source = {
  id: "libgen",
  name: "Library Genesis",
  description: "Search Library Genesis for EPUB and PDF editions.",
  version: "1.1.0",
  languages: ["*"],
  // The same catalogue answers on several official mirrors. Networks often
  // block one (libgen.li answering 403) while another still works.
  mirrors: ["https://libgen.li", "https://libgen.gl", "https://libgen.vg", "https://libgen.la", "https://libgen.bz"],
  allowedHosts: ["https://libgen.li", "https://libgen.gl", "https://libgen.vg", "https://libgen.la", "https://libgen.bz"],
  settings: [],
  host: "https://libgen.li",

  log: function (message) {
    if (typeof folio.log === "function") folio.log("Library Genesis: " + message);
  },

  mirrorFor: function (url) {
    var value = String(url || "");
    for (var i = 0; i < this.mirrors.length; i++) {
      if (value.indexOf(this.mirrors[i] + "/") === 0) return this.mirrors[i];
    }
    return null;
  },

  decode: function (value) {
    var entities = {amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " "};
    return value.replace(/&(#x[0-9a-f]+|#[0-9]+|[a-z]+);/gi, function (match, entity) {
      if (entity.charAt(0) !== "#") return entities[entity.toLowerCase()] || match;
      var hex = entity.charAt(1).toLowerCase() === "x";
      var number = parseInt(entity.slice(hex ? 2 : 1), hex ? 16 : 10);
      return number > 31 && number <= 0x10FFFF ? String.fromCodePoint(number) : match;
    });
  },

  text: function (html) {
    return this.decode(html.replace(/<i\b[^>]*>[\s\S]*?<\/i>/gi, " ").replace(/<[^>]*>/g, " "))
      .replace(/\s+/g, " ").trim();
  },

  links: function (html) {
    var links = [];
    var pattern = /<a\b[^>]*\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>([\s\S]*?)<\/a>/gi;
    var match;
    while ((match = pattern.exec(html))) {
      links.push({ href: this.decode(match[1] || match[2] || match[3]).trim(), label: this.text(match[4]) });
    }
    return links;
  },

  endpoint: function (href, endpoint, hash, host) {
    host = host || this.host;
    var path = href.indexOf(host + "/") === 0 ? href.slice(host.length) : href;
    if (path.charAt(0) !== "/") path = "/" + path;
    if (path.indexOf("/" + endpoint + "?") !== 0 || /[\s#\\]/.test(path)) return null;
    var pairs = path.split("?")[1].split("&");
    var digest = pairs.filter(function (pair) { return /^md5=[a-f0-9]{32}$/i.test(pair); });
    if (digest.length !== 1 || (hash && digest[0].slice(4).toLowerCase() !== hash)) return null;
    if (endpoint === "get.php" && !pairs.some(function (pair) { return /^key=[A-Za-z0-9_%+=-]+$/.test(pair); })) return null;
    return { url: host + path, hash: digest[0].slice(4).toLowerCase() };
  },

  fetch: function (url) {
    var html = folio.fetchText(url);
    if (typeof html !== "string" || !html.trim() || /<title>\s*(?:Site Unavailable|Access Denied|Just a moment)/i.test(html)) {
      throw new Error("Library Genesis is unavailable on this network.");
    }
    return html;
  },

  // Tries the mirror that last worked first, then the others. A blocked
  // mirror (403, a challenge page, no answer) just moves on to the next.
  fetchAny: function (path) {
    var order = [this.host].concat(this.mirrors.filter(function (m) { return m !== this.host; }, this));
    var problems = [];
    for (var i = 0; i < order.length; i++) {
      try {
        var html = this.fetch(order[i] + path);
        if (order[i] !== this.host) this.log("using " + order[i].replace("https://", "") + ".");
        this.host = order[i];
        return html;
      } catch (e) {
        var message = String((e && e.message) || e);
        problems.push(order[i].replace("https://", "") + ": " + message);
        this.log(order[i].replace("https://", "") + " failed: " + message);
      }
    }
    throw new Error("Library Genesis is unavailable on this network (" + problems.join("; ") + ").");
  },

  search: function (query, page, preferredLanguage, expectedTitle) {
    var term = String(expectedTitle || query || "").trim();
    if (!term) return [];
    var index = Math.max(0, parseInt(page, 10) || 0) + 1;
    var fields = expectedTitle ? "&columns%5B%5D=t" : "&columns%5B%5D=t&columns%5B%5D=a";
    var path = "/index.php?req=" + encodeURIComponent(term) + fields
      + "&objects%5B%5D=f&objects%5B%5D=e&objects%5B%5D=w&topics%5B%5D=l&topics%5B%5D=f&res=25&page=" + index;
    var table = this.fetchAny(path).match(/<table\b[^>]*\bid\s*=\s*["']?tablelibgen\b[^>]*>([\s\S]*?)<\/table>/i);
    if (!table) return [];
    var rows = table[1].match(/<tr\b[^>]*>[\s\S]*?<\/tr>/gi) || [];
    var results = [];
    var seen = {};
    for (var i = 0; i < rows.length; i++) {
      var cells = rows[i].match(/<td\b[^>]*>[\s\S]*?<\/td>/gi) || [];
      var offset = cells.length > 9 && /<img\b/i.test(cells[0]) ? 1 : 0;
      if (cells.length < offset + 9) continue;
      var format = this.text(cells[offset + 7]).toLowerCase();
      if (format !== "epub" && format !== "pdf") continue;
      var links = this.links(cells[offset + 8]);
      var landing = null;
      for (var j = 0; j < links.length && !landing; j++) landing = this.endpoint(links[j].href, "ads.php");
      if (!landing || seen[landing.hash]) continue;
      var title = this.text(cells[offset]);
      if (!title) continue;
      var authorLinks = this.links(cells[offset + 1]);
      var authors = authorLinks.map(function (link) { return link.label; }).filter(Boolean);
      if (!authors.length) authors = [this.text(cells[offset + 1])].filter(Boolean);
      var language = this.text(cells[offset + 4]);
      var year = parseInt(this.text(cells[offset + 3]), 10);
      seen[landing.hash] = true;
      results.push({
        id: landing.hash, title: title, authors: authors, language: language || null,
        year: year > 0 ? year : null, origin: landing.url,
        downloads: [{ format: format, url: landing.url }]
      });
    }
    return results;
  },

  prepareDownload: function (url) {
    var mirror = this.mirrorFor(url);
    var landing = mirror && this.endpoint(url, "ads.php", null, mirror);
    if (!landing || url !== landing.url) throw new Error("Invalid Library Genesis download page.");
    var links = this.links(this.fetch(landing.url));
    for (var i = 0; i < links.length; i++) {
      if (links[i].label.toUpperCase() !== "GET") continue;
      var file = this.endpoint(links[i].href, "get.php", landing.hash, mirror);
      if (file) return file.url;
    }
    throw new Error("Library Genesis did not publish a matching file link.");
  }
};
