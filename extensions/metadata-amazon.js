// Folio metadata source: Amazon, in the store for the book's language (amazon.es for Spanish,
// amazon.fr for French…), as Calibre's Amazon source does. Reads the search page, then each
// matching product page for the full record. Amazon has no public API and sometimes blocks
// automated visits; then this source simply returns nothing.
// See metadata-google-books.js for the call and record shape.
var source = {
  id: "metadata-amazon",
  kind: "metadata",
  name: "Amazon",
  description: "Full records from the Amazon store for the book's language: description, publisher, pages, ISBN, genres and large covers.",
  version: "1.0.2",
  languages: ["*"],
  allowedHosts: ["https://www.amazon.com", "https://www.amazon.es", "https://www.amazon.fr", "https://www.amazon.de",
                 "https://www.amazon.it", "https://www.amazon.nl", "https://www.amazon.com.br", "https://www.amazon.co.jp",
                 "https://www.amazon.se", "https://www.amazon.pl", "https://www.amazon.com.tr", "https://www.amazon.co.uk",
                 "https://www.amazon.com.mx", "https://www.amazon.ca"],
  settings: [],

  hosts: { es: "www.amazon.es", fr: "www.amazon.fr", de: "www.amazon.de", it: "www.amazon.it", nl: "www.amazon.nl",
           pt: "www.amazon.com.br", ja: "www.amazon.co.jp", sv: "www.amazon.se", pl: "www.amazon.pl",
           tr: "www.amazon.com.tr", ca: "www.amazon.es" },

  // Detail labels in each store's language.
  labels: {
    publisher: ["publisher", "editorial", "éditeur", "editeur", "herausgeber", "verlag", "editore", "uitgever", "editora", "出版社", "förlag", "wydawca", "yayıncı"],
    language: ["language", "idioma", "langue", "sprache", "lingua", "taal", "言語", "språk", "język", "dil"],
    pages: ["print length", "paperback", "hardcover", "tapa blanda", "tapa dura", "longitud de impresión", "broché", "relié",
            "nombre de pages", "taschenbuch", "gebundene ausgabe", "seitenzahl", "copertina flessibile", "copertina rigida",
            "lunghezza stampa", "paperback", "capa comum", "número de páginas", "単行本", "ページ数"],
    date: ["publication date", "fecha de publicación", "date de publication", "erscheinungstermin", "data di pubblicazione",
           "publicatiedatum", "data da publicação", "発売日"],
    isbn13: ["isbn-13"]
  },

  // Language names on Amazon pages, to Folio's two-letter codes.
  languages: { english: "en", inglés: "en", anglais: "en", englisch: "en", inglese: "en", engels: "en", inglês: "en",
               spanish: "es", español: "es", espagnol: "es", spanisch: "es", spagnolo: "es", spaans: "es", espanhol: "es",
               french: "fr", francés: "fr", français: "fr", französisch: "fr", francese: "fr", frans: "fr", francês: "fr",
               german: "de", alemán: "de", allemand: "de", deutsch: "de", tedesco: "de", duits: "de", alemão: "de",
               italian: "it", italiano: "it", italien: "it", italienisch: "it", italiaans: "it",
               portuguese: "pt", portugués: "pt", portugais: "pt", portugiesisch: "pt", portoghese: "pt", português: "pt",
               dutch: "nl", neerlandés: "nl", néerlandais: "nl", niederländisch: "nl", nederlands: "nl",
               catalan: "ca", catalán: "ca", català: "ca", japanese: "ja", 日本語: "ja" },

  headers: function (language) {
    return {
      "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
      "Accept": "text/html,application/xhtml+xml",
      "Accept-Language": (language || "en") + ",en;q=0.5"
    };
  },

  get: function (url, language) {
    try {
      var html = folio.fetchWith(url, JSON.stringify({ headers: this.headers(language) }));
      if (!html || /captcha|api-services-support@amazon/i.test(html.slice(0, 20000))) {
        folio.log("Amazon asked for a check at " + url);
        return null;
      }
      return html;
    } catch (e) {
      folio.log("Amazon: " + e);
      return null;
    }
  },

  // "Autor", "Author", "Auteur", "Autore", "Författare", "Yazar", "著"…
  isAuthorRole: function (role) {
    return /aut|author|auteur|verfasser|författare|yazar|著/i.test(role);
  },

  // Amazon pages write accents as HTML references ("Mu&ntilde;oz"); decode all of
  // them with Folio's full decoder, or the common ones on older Folio builds.
  entities: function (text) {
    if (typeof folio !== "undefined" && typeof folio.decodeHTML === "function") return folio.decodeHTML(text);
    return text.replace(/&nbsp;/g, " ").replace(/&quot;/g, "\"").replace(/&#39;|&apos;/g, "'")
      .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&amp;/g, "&");
  },

  text: function (html) {
    return this.entities(String(html || "")
      .replace(/<br\s*\/?>/gi, "\n").replace(/<\/p>/gi, "\n\n").replace(/<[^>]+>/g, " "))
      .replace(/\u00a0/g, " ").replace(/&rlm;|&lrm;|‏|‎/g, "")
      .replace(/[ \t]+/g, " ").replace(/\n[ \t]+/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
  },

  words: function (text) {
    return String(text || "").toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "")
      .split(/[^a-z0-9]+/).filter(function (w) { return w.length > 1; });
  },

  matches: function (wanted, title) {
    var have = this.words(title);
    if (!wanted.length) return false;
    return wanted.filter(function (w) { return have.indexOf(w) >= 0; }).length / wanted.length >= 0.6;
  },

  // "Editorial : Nova (1 de marzo de 2015)" and the like, from the detail bullets or table.
  details: function (html) {
    var out = {};
    var self = this;
    var rows = [];
    var bullet = /<span class="a-text-bold">([\s\S]*?)<\/span>\s*<span[^>]*>([\s\S]*?)<\/span>/g;
    var m;
    while ((m = bullet.exec(html))) rows.push([self.text(m[1]), self.text(m[2])]);
    var table = /<th[^>]*>([\s\S]*?)<\/th>\s*<td[^>]*>([\s\S]*?)<\/td>/g;
    while ((m = table.exec(html))) rows.push([self.text(m[1]), self.text(m[2])]);
    rows.forEach(function (row) {
      var label = row[0].replace(/[:\s‏‎]+$/g, "").trim().toLowerCase();
      var value = row[1].trim();
      if (!label || !value) return;
      function is(kind) { return self.labels[kind].some(function (l) { return label.indexOf(l) === 0; }); }
      if (!out.publisher && is("publisher")) {
        out.publisher = value.replace(/\s*[;(].*$/, "").trim();
        var y = value.match(/(1[5-9]\d\d|20\d\d)/);
        if (y && !out.year) out.year = parseInt(y[1], 10);
      } else if (!out.language && is("language")) {
        out.language = self.languages[value.toLowerCase().split(/[\s,(]/)[0]] || null;
      } else if (!out.pages && is("pages")) {
        var p = value.match(/(\d[\d.,]*)/);
        if (p) out.pages = parseInt(p[1].replace(/[.,]/g, ""), 10);
      } else if (!out.year && is("date")) {
        var d = value.match(/(1[5-9]\d\d|20\d\d)/);
        if (d) out.year = parseInt(d[1], 10);
      } else if (!out.isbn && is("isbn13")) {
        out.isbn = value.replace(/[^0-9X]/gi, "");
      }
    });
    return out;
  },

  product: function (host, asin, language) {
    var html = this.get("https://" + host + "/dp/" + asin, language);
    if (!html) return null;
    var title = (html.match(/<span id="productTitle"[^>]*>([\s\S]*?)<\/span>/) || [])[1];
    if (!title) return null;
    var self = this;
    var authors = [];
    var byline = (html.match(/<div id="bylineInfo"[\s\S]*?<\/div>\s*<\/div>/) || [""])[0];
    var m;
    // Each contributor is its own <span class="author">: a name link, then a role
    // such as "(Autor)" or "(Traductor)". Translators, illustrators and narrators
    // are not the book's authors.
    var chunks = byline.split(/<span class="author\b/).slice(1);
    if (!chunks.length) chunks = [byline];
    chunks.forEach(function (chunk) {
      var link = chunk.match(/<a class="a-link-normal"[^>]*>([^<]+)<\/a>/);
      if (!link) return;
      var name = self.text(link[1]);
      var role = (chunk.match(/class="contribution"[\s\S]*?\(([^)]+)\)/) || [])[1] || "";
      if (role && !self.isAuthorRole(role)) return;
      if (name && authors.indexOf(name) < 0 && !/^(visit|visita|visitez|besuchen|\d)/i.test(name)) authors.push(name);
    });
    var description = null;
    var block = html.match(/<div[^>]*id="bookDescription_feature_div"[\s\S]*?<div[^>]*class="a-expander-content[^"]*"[^>]*>([\s\S]*?)<\/div>/);
    if (!block) block = html.match(/<div[^>]*id="bookDescription_feature_div"[\s\S]*?<noscript>([\s\S]*?)<\/noscript>/);
    if (block) description = self.text(block[1]) || null;
    var cover = null;
    var hires = html.match(/data-old-hires="(https:[^"]+)"/) || html.match(/"hiRes":"(https:[^"]+)"/) ||
                html.match(/data-a-dynamic-image="\{&quot;(https:[^&]+)&quot;/);
    if (hires) cover = hires[1].replace(/\._[^/]*_\./, ".");
    var genres = [];
    var crumbs = (html.match(/id="wayfinding-breadcrumbs_feature_div"[\s\S]*?<\/ul>/) || [""])[0];
    var c = /<a[^>]*>([\s\S]*?)<\/a>/g;
    while ((m = c.exec(crumbs))) {
      var g = self.text(m[1]);
      if (g && !/^(books|libros|livres|bücher|libri|boeken|livros|kindle)/i.test(g)) genres.push(g);
    }
    var rating = html.match(/<span[^>]*id="acrPopover"[^>]*title="([\d.,]+)/);
    var info = self.details(html);
    var series = html.match(/id="seriesBulletWidget_feature_div"[\s\S]*?>\s*(?:Book|Libro|Livre|Buch|Libro|Boek|Livro)\s+(\d+)[^<]*?(?:of|de|sur|von|di|van)\s+\d+\s*:\s*([^<]+)</i);
    return {
      source: "Amazon " + host.replace("www.amazon", ""),
      title: self.text(title),
      authors: authors.join(", ") || null,
      description: description,
      publisher: info.publisher || null,
      language: info.language || language || null,
      isbn: info.isbn || (/^\d{9}[\dX]$/.test(asin) ? asin : null),
      series: series ? self.text(series[2]) : null,
      seriesIndex: series ? parseFloat(series[1]) : null,
      year: info.year || null,
      pages: info.pages || null,
      cover: cover,
      genres: genres,
      rating: rating ? parseFloat(rating[1].replace(",", ".")) : null
    };
  },

  metadata: function (book) {
    var host = this.hosts[book.language] || "www.amazon.com";
    var author = String(book.author || "").split(/,|&/)[0].trim();
    var query = book.isbn || (String(book.title || "").split(/[:(]/)[0] + " " + author);
    var html = this.get("https://" + host + "/s?i=stripbooks&k=" + encodeURIComponent(query), book.language);
    if (!html) return [];
    var wanted = this.words(String(book.title || "").split(/[:(]/)[0]);
    var self = this;
    var asins = [];
    var results = html.split('data-component-type="s-search-result"');
    for (var i = 0; i < results.length - 1 && asins.length < 2; i++) {
      var asin = (results[i].match(/data-asin="([A-Z0-9]{10})"[^>]*$/) || [])[1];
      var alt = (results[i + 1].match(/<img[^>]*class="s-image"[^>]*alt="([^"]*)"/) || [])[1];
      if (asin && asins.indexOf(asin) < 0 && (book.isbn || self.matches(wanted, self.text(alt)))) asins.push(asin);
    }
    var out = [];
    asins.forEach(function (asin) {
      var record = self.product(host, asin, book.language);
      if (record) out.push(record);
    });
    return out;
  }
};
