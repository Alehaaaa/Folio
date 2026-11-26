// Library Genesis catalogue source for Folio. Uses links the provider publishes.
var source = {
  id: "libgen",
  name: "Library Genesis",
  description: "Search Library Genesis for EPUB and PDF editions.",
  version: "1.2.0",
  languages: ["*"],
  // The same catalogue answers on several official mirrors. Networks often
  // block one (libgen.li answering 403) while another still works.
  mirrors: ["https://libgen.li", "https://libgen.gl", "https://libgen.vg", "https://libgen.la", "https://libgen.bz"],
  allowedHosts: ["https://libgen.li", "https://libgen.gl", "https://libgen.vg", "https://libgen.la", "https://libgen.bz"],
  settings: [],
  host: "https://libgen.li",
  // True once a mirror answered in this source session; later requests go
  // straight to it instead of racing every mirror again.
  confirmed: false,
  // A mirror that does not answer within this many seconds is skipped.
  probeSeconds: 12,

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

  usable: function (html) {
    return typeof html === "string" && html.trim() &&
      !/<title>\s*(?:Site Unavailable|Access Denied|Just a moment)/i.test(html);
  },

  fetch: function (url) {
    var html = folio.fetchText(url);
    if (!this.usable(html)) throw new Error("Library Genesis is unavailable on this network.");
    return html;
  },

  // "libgen.li: The request timed out." ×5 reads as "li, gl, …: timed out".
  summary: function (problems) {
    var groups = {}, order = [];
    for (var i = 0; i < problems.length; i++) {
      var text = String(problems[i]).replace(/(?:Error: )+/g, "").replace(/https:\/\//g, "");
      var cut = text.indexOf(": ");
      var host = cut > 0 ? text.slice(0, cut).replace(/^libgen\./, "") : "";
      var reason = (cut > 0 ? text.slice(cut + 2) : text).replace(/^libgen\.[a-z]+ /, "").replace(/\.$/, "");
      if (/timed? ?out/i.test(reason)) reason = "timed out";
      else if (/secure connection|tls|ssl/i.test(reason)) reason = "secure connection failed";
      else if (/hostname could not be found|could not resolve/i.test(reason)) reason = "address not found";
      if (!groups[reason]) { groups[reason] = []; order.push(reason); }
      groups[reason].push(host);
    }
    return order.map(function (reason) { return groups[reason].join(", ") + ": " + reason; }).join("; ");
  },

  short: function (mirror) { return mirror.replace("https://", ""); },

  // The first search asks every mirror at once and keeps the first one that
  // answers, so one slow or blocked mirror (libgen.li timing out on mobile
  // data) costs a few seconds instead of half a minute. Later requests use
  // that mirror directly. Without folio.fetchFirst (older Folio), or when the
  // fastest answer is a challenge page, mirrors are tried one by one.
  fetchAny: function (path) {
    if (this.confirmed) {
      try { return this.fetch(this.host + path); }
      catch (e) {
        this.log(this.short(this.host) + " stopped answering; checking the other mirrors.");
        this.confirmed = false;
      }
    }
    var order = [this.host].concat(this.mirrors.filter(function (m) { return m !== this.host; }, this));
    if (typeof folio.fetchFirst === "function") {
      var answer = null;
      try {
        answer = JSON.parse(folio.fetchFirst(JSON.stringify(order.map(function (m) { return m + path; })),
          JSON.stringify({timeout: this.probeSeconds})));
      } catch (e) {
        throw new Error("No mirror answered (" + this.summary(String((e && e.message) || e).split(" | ")) + ").");
      }
      var winner = this.mirrorFor(answer.url);
      if (winner && this.usable(answer.text)) {
        if (winner !== this.mirrors[0]) this.log("using " + this.short(winner) + ".");
        this.host = winner;
        this.confirmed = true;
        return answer.text;
      }
      order = order.filter(function (m) { return m !== winner; });
    }
    var problems = [];
    for (var i = 0; i < order.length; i++) {
      try {
        var html = this.fetch(order[i] + path);
        if (order[i] !== this.mirrors[0]) this.log("using " + this.short(order[i]) + ".");
        this.host = order[i];
        this.confirmed = true;
        return html;
      } catch (e) {
        problems.push(this.short(order[i]) + ": " + String((e && e.message) || e));
      }
    }
    throw new Error("No mirror answered (" + this.summary(problems) + ").");
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
