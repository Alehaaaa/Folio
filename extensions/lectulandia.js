// Folio book source for the Spanish-language Lectulandia catalogue.
// Reads the site's published listings and EPUB/PDF links without credentials.
var source = {
  id: "lectulandia",
  name: "Lectulandia",
  description: "Spanish-language books listed by Lectulandia, with its published EPUB and PDF links.",
  version: "1.0.1",
  languages: ["es"],
  allowedHosts: [
    "https://ww3.lectulandia.com",
    "https://ww3.lectulandia.co",
    "https://assets.lectulandia.com",
    "https://assets.lectulandia.co",
    // The published download flow on both Lectulandia mirrors redirects to
    // Antupload after its site-managed wait, then exposes an EPUB/PDF link.
    "https://www.antupload.com"
  ],
  settings: [],
  // Both current entry domains redirect to these two matching WordPress
  // catalogues. Historical Lectulandia-looking sites are not interchangeable.
  mirrors: ["https://ww3.lectulandia.com", "https://ww3.lectulandia.co"],
  host: "https://ww3.lectulandia.com",
  pageSize: 12,

  status: function (message) {
    if (typeof folio.status === "function") folio.status(message);
  },

  log: function (message) {
    if (typeof folio.log === "function") folio.log("Lectulandia: " + message);
  },

  // Keep all navigation on the declared catalogue host. In particular, do
  // not follow advertising, third-party download mirrors or arbitrary links.
  path: function (path) {
    var value = this.unescape(String(path || "").trim());
    if (value.indexOf("/") === 0 && value.indexOf("//") !== 0) return value;
    for (var i = 0; i < this.mirrors.length; i++) {
      if (value.indexOf(this.mirrors[i] + "/") === 0)
        return value.slice(this.mirrors[i].length);
    }
    return null;
  },

  // A download candidate belongs to exactly one approved mirror. The Folio
  // downloader already walks the independently listed mirror candidates on
  // failure; retrying every mirror inside preparation would multiply waits.
  mirrorFor: function (url) {
    var value = String(url || "").trim();
    for (var i = 0; i < this.mirrors.length; i++) {
      if (value.indexOf(this.mirrors[i] + "/") === 0) return this.mirrors[i];
    }
    return null;
  },

  url: function (path) {
    var relative = this.path(path);
    return relative ? this.host + relative : null;
  },

  unescape: function (value) {
    var named = {amp: "&", quot: '"', apos: "'", lt: "<", gt: ">", nbsp: " "};
    return String(value || "").replace(/&(#x[0-9a-f]+|#[0-9]+|[a-z]+);/gi, function (full, code) {
      var lower = code.toLowerCase();
      if (lower.charAt(0) === "#") {
        var num = lower.charAt(1) === "x" ? parseInt(lower.slice(2), 16) : parseInt(lower.slice(1), 10);
        return num > 31 && num < 65536 ? String.fromCharCode(num) : " ";
      }
      return named[lower] || full;
    });
  },

  text: function (html) {
    return this.unescape(String(html || "")
      .replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, "")
      .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, "")
      .replace(/<[^>]*>/g, " ")
      .replace(/\s+/g, " ").trim());
  },

  attribute: function (tag, key) {
    var pattern = new RegExp("\\b" + key + "\\s*=\\s*(['\"])([\\s\\S]*?)\\1", "i");
    var value = String(tag || "").match(pattern);
    return value ? this.unescape(value[2]) : "";
  },

  normalize: function (text) {
    var value = String(text || "").toLowerCase();
    if (typeof value.normalize === "function") value = value.normalize("NFD").replace(/[\u0300-\u036f]/g, "");
    return value.replace(/[^a-z0-9]+/g, " ").trim();
  },

  validPage: function (html, path) {
    if (!/<html\b/i.test(html) || /checking your browser|just a moment/i.test(html)) return false;
    if (/^\/book\//.test(path))
      return /<div\b[^>]*\bid\s*=\s*["']book["']/i.test(html) &&
        /<div\b[^>]*\bid\s*=\s*["']title["']/i.test(html);
    if (/^\/search\//.test(path) || path === "/" || /^\/page\//.test(path))
      return /\bbooks-grid\b/i.test(html) || /<article\b[^>]*\bcard\b/i.test(html) ||
        /la busqueda no dio resultados/i.test(html);
    return true;
  },

  fetchPage: function (url) {
    var path = this.path(url);
    if (!path) throw new Error("Blocked unapproved catalogue URL");
    var order = [this.host];
    for (var i = 0; i < this.mirrors.length; i++)
      if (order.indexOf(this.mirrors[i]) < 0) order.push(this.mirrors[i]);
    var failures = [];
    for (var n = 0; n < order.length; n++) {
      var mirror = order[n], candidate = mirror + path;
      try {
        var html = folio.fetchText(candidate);
        if (this.validPage(html, path)) {
          this.host = mirror;
          return html;
        }
        throw new Error("Unexpected response or browser-check page");
      } catch (error) {
        this.log("Direct request failed for " + candidate + ": " + error);
        if (folio.browser && typeof folio.browser.open === "function") {
          try {
            this.status("Checking Lectulandia in the background browser…");
            var rendered = folio.browser.open(candidate);
            if (this.validPage(rendered, path)) {
              this.host = mirror;
              return rendered;
            }
            throw new Error("Browser did not return a catalogue page");
          } catch (browserError) {
            this.log("Browser could not load " + candidate + ": " + browserError);
          }
        }
        failures.push(mirror + " (" + error + ")");
      }
    }
    throw new Error("Lectulandia mirrors unavailable: " + failures.join("; "));
  },

  authors: function (html) {
    var matches = String(html || "").match(/<a\b[^>]*href\s*=\s*["'][^"']*\/autor\/[^"']+["'][^>]*>[\s\S]*?<\/a>/gi) || [];
    var list = [], seen = {};
    for (var i = 0; i < matches.length; i++) {
      var name = this.text(matches[i]);
      if (name && !seen[name]) { list.push(name); seen[name] = true; }
    }
    return list;
  },

  cards: function (html) {
    var matches = String(html || "").match(/<article\b[^>]*class\s*=\s*["'][^"']*\bcard\b[^"']*["'][^>]*>[\s\S]*?<\/article>/gi) || [];
    var results = [], seen = {};
    for (var i = 0; i < matches.length; i++) {
      var card = matches[i];
      var link = card.match(/<a\b[^>]*class\s*=\s*["'][^"']*\btitle\b[^"']*["'][^>]*>[\s\S]*?<\/a>/i);
      if (!link) continue;
      var href = this.attribute(link[0], "href");
      var detailURL = this.url(href);
      if (!detailURL || !/^\/book\/[a-z0-9-]+\/?$/i.test(href) || seen[detailURL]) continue;
      var title = this.attribute(link[0], "title") || this.text(link[0]);
      var byline = card.match(/<div\b[^>]*class\s*=\s*["'][^"']*\bsubdetail\b[^"']*["'][^>]*>[\s\S]*?<\/div>/i);
      var coverTag = card.match(/<img\b[^>]*class\s*=\s*["'][^"']*\bcover\b[^"']*["'][^>]*>/i);
      if (!title) continue;
      seen[detailURL] = true;
      results.push({
        id: href,
        url: detailURL,
        title: title,
        authors: this.authors(byline ? byline[0] : ""),
        cover: coverTag ? this.attribute(coverTag[0], "src") : ""
      });
    }
    return results;
  },

  details: function (card) {
    var html = this.fetchPage(card.url);
    // A details page may also contain "related books" cards: only inspect the
    // actual book's own controls and metadata.
    var bookStart = html.search(/<div\b[^>]*id\s*=\s*["']book["']/i);
    if (bookStart < 0) throw new Error("Book details are unavailable: " + card.url);
    var book = html.slice(bookStart);
    var titleTag = book.match(/<div\b[^>]*id\s*=\s*["']title["'][^>]*>[\s\S]*?<\/div>/i);
    var authorTag = book.match(/<div\b[^>]*id\s*=\s*["']autor["'][^>]*>[\s\S]*?<\/div>/i);
    var cover = book.match(/<div\b[^>]*id\s*=\s*["']cover["'][^>]*>[\s\S]*?<img\b[^>]*>/i);
    var control = book.match(/<div\b[^>]*id\s*=\s*["']downloadContainer["'][^>]*>[\s\S]*?<\/div>/i);
    var anchors = control ? control[0].match(/<a\b[^>]*href\s*=\s*["'][^"']+["'][^>]*>[\s\S]*?<\/a>/gi) || [] : [];
    var downloads = [];
    for (var i = 0; i < anchors.length; i++) {
      var path = this.attribute(anchors[i], "href");
      if (!/^\/download\.php\?/.test(path)) continue;
      var type = path.match(/[?&]t=(1|2)(?:&|$)/);
      var target = this.url(path);
      if (!type || !target || !/[?&]d=[A-Za-z0-9%+/_=-]+(?:&|$)/.test(path)) continue;
      var format = type[1] === "1" ? "epub" : "pdf";
      var relative = this.path(target);
      var order = [this.host];
      for (var j = 0; j < this.mirrors.length; j++)
        if (order.indexOf(this.mirrors[j]) < 0) order.push(this.mirrors[j]);
      // Folio retries another link of the same format if preparation or the
      // final transfer fails. Both are independently approved catalogue hosts.
      for (var m = 0; m < order.length; m++)
        downloads.push({format: format, url: order[m] + relative});
    }
    if (!downloads.length) this.log("No published EPUB or PDF links: " + card.url);
    var result = {
      id: card.id,
      title: titleTag ? this.text(titleTag[0]) : card.title,
      authors: authorTag ? this.authors(authorTag[0]) : card.authors,
      cover: cover ? this.attribute(cover[0].match(/<img\b[^>]*>/i)[0], "src") : card.cover,
      origin: this.url(card.url),
      language: "es",
      downloads: downloads
    };
    return result;
  },

  search: function (query, page, preferredLanguage, expectedTitle, expectedAuthor) {
    var language = String(preferredLanguage || "").trim().toLowerCase().split(/[-_]/)[0];
    if (language && language !== "es" && language !== "spa" && language !== "spanish") {
      this.log("Skipped: catalogue is Spanish, requested " + language);
      return [];
    }
    var q = String(query || "").trim();
    if (!q) return this.recent(page);
    var pages = Math.max(0, Math.min(100, parseInt(page, 10) || 0));
    var self = this;
    var find = function (term, pageIndex) {
      var url = self.host + "/search/" + encodeURIComponent(term).replace(/%20/g, "+") + "/";
      if (pageIndex > 0) url += "page/" + (pageIndex + 1) + "/";
      self.status("Searching Lectulandia…");
      var html = self.fetchPage(url);
      return {
        cards: self.cards(html),
        hasNext: new RegExp("/page/" + (pageIndex + 2) + "/").test(html)
      };
    };
    var wantedTitle = this.normalize(expectedTitle);
    var wantedAuthor = this.normalize(expectedAuthor);
    var matching = function (cards) {
      if (!wantedTitle) return cards;
      return cards.filter(function (card) {
        var name = self.normalize(card.title);
        var author = self.normalize(card.authors.join(" "));
        var wantedParts = wantedAuthor.split(" ").filter(function (part) { return part.length > 2; });
        var partsFound = wantedParts.filter(function (part) {
          return (" " + author + " ").indexOf(" " + part + " ") >= 0;
        }).length;
        return (name.indexOf(wantedTitle) === 0 || wantedTitle.indexOf(name) === 0) &&
          (!wantedAuthor || !author || author.indexOf(wantedAuthor) >= 0 ||
           wantedAuthor.indexOf(author) >= 0 ||
           (wantedParts.length > 1 && partsFound >= 2) ||
           (wantedParts.length === 1 && partsFound === 1));
      });
    };
    var initial = find(q, pages);
    var cards = matching(initial.cards);
    var seen = {};
    for (var c = 0; c < cards.length; c++) seen[cards[c].id] = true;
    var append = function (extra) {
      var matches = matching(extra.cards);
      for (var i = 0; i < matches.length; i++) {
        if (!seen[matches[i].id]) {
          cards.push(matches[i]);
          seen[matches[i].id] = true;
        }
      }
    };
    var exact = function (card) { return wantedTitle && self.normalize(card.title) === wantedTitle; };
    // Automatic searches include the author's surname in the free-text query.
    // The site often returns many annotated editions before the exact book.
    // Recheck the title alone, then at most two more advertised result pages.
    if (wantedTitle && pages === 0 && !cards.some(exact)) {
      var titlePage = initial;
      if (this.normalize(q) !== wantedTitle) {
        titlePage = find(expectedTitle, 0);
        append(titlePage);
      }
      for (var next = 1; next <= 2 && titlePage.hasNext && !cards.some(exact); next++) {
        try {
          titlePage = find(expectedTitle, next);
          append(titlePage);
        } catch (error) {
          this.log("Cannot search Lectulandia title page " + (next + 1) + ": " + error);
          break;
        }
      }
    }
    if (wantedTitle) cards.sort(function (a, b) { return Number(exact(b)) - Number(exact(a)); });
    var results = [];
    for (var i = 0; i < cards.length && results.length < this.pageSize; i++) {
      try {
        var result = this.details(cards[i]);
        if (result.downloads.length) results.push(result);
      } catch (error) {
        this.log("Cannot read " + cards[i].url + ": " + error);
      }
    }
    this.status("Found " + results.length + " Spanish-language books");
    return results;
  },

  // A /download.php page is HTML. Its own JavaScript waits ~11 seconds and
  // navigates to Antupload. Only the final /filed/ link serves actual bytes.
  // Folio waits in its isolated WebKit session and validates the EPUB magic.
  prepareDownload: function (landingURL) {
    var path = this.path(landingURL);
    var mirror = this.mirrorFor(landingURL);
    if (!mirror || !path || !/^\/download\.php\?t=[12]&/.test(path) ||
        !/[?&]d=[A-Za-z0-9%+/_=-]+(?:&|$)/.test(path))
      throw new Error("Invalid Lectulandia download page");
    if (!folio.browser || typeof folio.browser.open !== "function" ||
        typeof folio.browser.waitFor !== "function")
      throw new Error("Lectulandia download requires Folio's background browser");

    try {
      this.status("Waiting for Lectulandia's download page…");
      folio.browser.open(mirror + path);
      // The redirect belongs to the provider. Wait for its own published
      // download button on the final Antupload page.
      if (folio.browser.waitFor("#downloadB") !== "true")
        throw new Error("Download button did not appear after site countdown");
      var url = String(folio.browser.url());
      if (!/^https:\/\/www\.antupload\.com\/file\/[A-Za-z0-9]+\/?$/.test(url))
        throw new Error("Unexpected destination after Lectulandia countdown: " + url);
      var html = folio.browser.html();
      var anchor = html.match(/<a\b[^>]*id\s*=\s*["']downloadB["'][^>]*>/i);
      if (!anchor) throw new Error("Antupload did not publish a final file link");
      var href = this.attribute(anchor[0], "href");
      if (!/^\/filed\/[A-Za-z0-9]+\/[A-Za-z0-9%+._-]+(?:[A-Za-z0-9%+._-]|\/)?$/.test(href))
        throw new Error("Antupload returned an unexpected file path");
      this.host = mirror;
      this.status("Antupload provided the final book file link");
      return "https://www.antupload.com" + href;
    } catch (error) {
      this.log("Download preparation failed: " + mirror + ": " + error);
      throw new Error("Lectulandia download preparation failed on " + mirror + ": " + error);
    }
  },

  recent: function (page) {
    var number = Math.max(0, Math.min(100, parseInt(page, 10) || 0));
    var url = this.host + "/" + (number > 0 ? "page/" + (number + 1) + "/" : "");
    var cards = this.cards(this.fetchPage(url));
    var results = [];
    for (var i = 0; i < cards.length && results.length < this.pageSize; i++) {
      try {
        var result = this.details(cards[i]);
        if (result.downloads.length) results.push(result);
      } catch (error) { this.log("Cannot read " + cards[i].url + ": " + error); }
    }
    return results;
  }
};
