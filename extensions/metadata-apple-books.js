// Folio metadata source: Apple Books, through the public iTunes Search API, in the store
// for the book's language. See metadata-google-books.js for the call and record shape.
var source = {
  id: "metadata-apple-books",
  kind: "metadata",
  name: "Apple Books",
  description: "Large covers, descriptions and genres from the Apple Books store for the book's language.",
  version: "1.0.0",
  allowedHosts: ["https://itunes.apple.com"],
  settings: [],

  countries: { en: "us", es: "es", fr: "fr", de: "de", it: "it", pt: "br", nl: "nl", ja: "jp", sv: "se",
               no: "no", da: "dk", fi: "fi", pl: "pl", ru: "ru", tr: "tr", zh: "cn", ko: "kr", ca: "es" },

  words: function (text) {
    return String(text || "").toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "")
      .split(/[^a-z0-9]+/).filter(function (w) { return w.length > 1; });
  },

  matches: function (wanted, title) {
    var have = this.words(title);
    if (!wanted.length) return false;
    var hits = wanted.filter(function (w) { return have.indexOf(w) >= 0; }).length;
    return hits / wanted.length >= 0.6;
  },

  metadata: function (book) {
    var country = this.countries[book.language] || "us";
    var term = String(book.title || "") + " " + String(book.author || "").split(/,|&/)[0];
    var url = "https://itunes.apple.com/search?media=ebook&entity=ebook&limit=12&country=" + country +
      "&term=" + encodeURIComponent(term);
    var results;
    try { results = folio.fetchJSON(url).results || []; } catch (e) { folio.log("Apple Books: " + e); return []; }
    var wanted = this.words(String(book.title || "").split(/[:(]/)[0]);
    var self = this;
    return results.filter(function (r) { return self.matches(wanted, r.trackName); }).map(function (r) {
      return {
        source: "Apple Books",
        title: r.trackName,
        authors: r.artistName || null,
        description: r.description || null,
        // The store matches the language; a title that matched the file's is that edition.
        language: book.language || null,
        year: r.releaseDate ? parseInt(r.releaseDate.slice(0, 4), 10) : null,
        cover: r.artworkUrl100 ? r.artworkUrl100.replace(/\/\d+x\d+bb\./, "/1400x1400bb.") : null,
        genres: (r.genres || []).filter(function (g) { return !/^(books|libros|livres|bücher|libri)$/i.test(g); }),
        rating: r.averageUserRating || null
      };
    }).slice(0, 6);
  }
};
