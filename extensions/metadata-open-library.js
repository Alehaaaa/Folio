// Folio metadata source: Open Library. See metadata-google-books.js for the call and record shape.
var source = {
  id: "metadata-open-library",
  kind: "metadata",
  name: "Open Library",
  description: "Editions and covers in the book's language, subjects and page counts.",
  version: "1.0.1",
  languages: ["*"],
  allowedHosts: ["https://openlibrary.org"],
  settings: [],

  // ISO 639-2 codes Open Library uses, to the two-letter codes Folio uses.
  codes: { eng: "en", spa: "es", fre: "fr", fra: "fr", ger: "de", deu: "de", ita: "it", por: "pt",
           dut: "nl", nld: "nl", jpn: "ja", chi: "zh", zho: "zh", rus: "ru", pol: "pl", swe: "sv",
           nor: "no", dan: "da", fin: "fi", cat: "ca", cze: "cs", ces: "cs", tur: "tr", gre: "el",
           ell: "el", kor: "ko", ara: "ar", heb: "he", hin: "hi", ukr: "uk" },

  code: function (list) {
    if (!list || !list.length) return null;
    var self = this;
    var codes = list.map(function (l) { return self.codes[l] || null; }).filter(function (c) { return c; });
    return codes.length === 1 ? codes[0] : null;
  },

  cover: function (id) { return id && id > 0 ? "https://covers.openlibrary.org/b/id/" + id + "-L.jpg" : null; },

  metadata: function (book) {
    var title = String(book.title || "").replace(/\s*[\(\[].*?[\)\]]\s*/g, " ").split(/[:;]/)[0].trim();
    var author = String(book.author || "").split(/,|&/)[0].trim();
    var url = "https://openlibrary.org/search.json?limit=6&title=" + encodeURIComponent(title) +
      "&author=" + encodeURIComponent(author) +
      "&fields=title,author_name,first_publish_year,publisher,isbn,cover_i,language,number_of_pages_median,subject," +
      "editions,editions.title,editions.cover_i,editions.language,editions.publisher,editions.isbn,editions.publish_date,editions.number_of_pages_median";
    if (book.language) url += "&lang=" + encodeURIComponent(book.language);
    var docs;
    try { docs = folio.fetchJSON(url).docs || []; } catch (e) { folio.log("Open Library: " + e); return []; }
    var self = this;
    var out = [];
    docs.forEach(function (doc) {
      var authors = (doc.author_name || []).join(", ");
      var genres = (doc.subject || []).slice(0, 6);
      var edition = doc.editions && doc.editions.docs && doc.editions.docs[0];
      if (edition && book.language && self.code(edition.language) === book.language) {
        var year = edition.publish_date && edition.publish_date[0] && (edition.publish_date[0].match(/\d{4}/) || [])[0];
        out.push({
          source: "Open Library", title: edition.title || doc.title, authors: authors,
          publisher: (edition.publisher || [])[0] || null, language: book.language,
          isbn: (edition.isbn || []).filter(function (i) { return i.length === 13; })[0] || null,
          year: year ? parseInt(year, 10) : null, pages: edition.number_of_pages_median || null,
          cover: self.cover(edition.cover_i), genres: genres
        });
      }
      if (!doc.title) return;
      out.push({
        source: "Open Library", title: doc.title, authors: authors,
        publisher: (doc.publisher || [])[0] || null, language: self.code(doc.language),
        isbn: (doc.isbn || []).filter(function (i) { return i.length === 13; })[0] || null,
        year: doc.first_publish_year || null, pages: doc.number_of_pages_median || null,
        cover: self.cover(doc.cover_i), genres: genres
      });
    });
    return out;
  }
};
