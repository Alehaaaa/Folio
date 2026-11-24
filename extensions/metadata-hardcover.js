// Folio metadata source: Hardcover, through the reader's own Hardcover account.
// folio.hardcover(query, variablesJSON) is a bridge Folio gives only to this bundled source: it runs
// the GraphQL query with the reader's token and Folio's rate limiting, and returns the data as JSON
// text (null when not signed in). See metadata-google-books.js for the call and record shape.
var source = {
  id: "metadata-hardcover",
  kind: "metadata",
  name: "Hardcover",
  description: "The work and its editions in the book's language: titles, covers, publishers, pages, ISBNs and series.",
  version: "1.0.1",
  languages: ["*"],
  allowedHosts: [],
  settings: [],

  editionFields: "id title image { url } release_date pages isbn_10 isbn_13 edition_format physical_format publisher { name } language { language }",

  names: { english: "en", spanish: "es", french: "fr", german: "de", italian: "it", portuguese: "pt", dutch: "nl",
           japanese: "ja", chinese: "zh", russian: "ru", polish: "pl", swedish: "sv", norwegian: "no", danish: "da",
           finnish: "fi", catalan: "ca", czech: "cs", turkish: "tr", greek: "el", korean: "ko", arabic: "ar",
           hebrew: "he", hindi: "hi", ukrainian: "uk" },

  ask: function (query, variables) {
    if (typeof folio.hardcover !== "function") return null;
    var text = folio.hardcover(query, JSON.stringify(variables || {}));
    return text ? JSON.parse(text) : null;
  },

  code: function (name) {
    if (!name) return null;
    return this.names[String(name).toLowerCase().split(/[;,]/)[0].trim()] || null;
  },

  words: function (text) {
    return String(text || "").toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "")
      .split(/[^a-z0-9]+/).filter(function (w) { return w.length > 1; }).join(" ");
  },

  // The work behind a file: its title, or any edition title (translations), by the same author.
  findWork: function (book) {
    var data = this.ask('query S($q: String!) { search(query: $q, query_type: "Book", per_page: 20, page: 1) { results } }',
                        { q: book.title + " " + String(book.author || "").split(/,|&/)[0] });
    if (!data) return null;
    var results = data.search && data.search.results;
    if (typeof results === "string") { try { results = JSON.parse(results); } catch (e) { results = null; } }
    var hits = (results && results.hits) || [];
    var title = this.words(String(book.title).split(/[:(]/)[0]);
    var surname = this.words(String(book.author || "").split(/,|&/)[0]).split(" ").pop();
    for (var i = 0; i < hits.length; i++) {
      var doc = hits[i].document || {};
      var authors = this.words((doc.author_names || []).join(" "));
      if (surname && authors.indexOf(surname) < 0) continue;
      var titles = [doc.title].concat(doc.alternative_titles || []);
      for (var j = 0; j < titles.length; j++) {
        if (this.words(String(titles[j] || "").split(/[:(]/)[0]) === title) return parseInt(doc.id, 10);
      }
    }
    return null;
  },

  record: function (edition, work, book, language) {
    var year = edition.release_date ? parseInt(String(edition.release_date).slice(0, 4), 10) : null;
    var format = edition.edition_format || edition.physical_format || "Edition";
    return {
      source: "Hardcover · " + format,
      title: edition.title || null,
      authors: work.authors,
      publisher: edition.publisher ? edition.publisher.name : null,
      language: this.code(edition.language && edition.language.language) || language,
      isbn: edition.isbn_13 || edition.isbn_10 || null,
      series: work.series, seriesIndex: work.seriesIndex,
      year: year, pages: edition.pages || null,
      cover: edition.image ? edition.image.url : null,
      genres: work.genres
    };
  },

  metadata: function (book) {
    var id = book.hardcoverBookID || this.findWork(book);
    if (!id) return [];
    var data = this.ask('query W($id: Int!) { books(where: {id: {_eq: $id}}, limit: 1) { id title description pages release_year image { url } cached_contributors cached_tags } ' +
                        'book_series(where: {book_id: {_eq: $id}}) { position series { name } } }', { id: id });
    var b = data && data.books && data.books[0];
    if (!b) return [];
    var authors = (b.cached_contributors || []).map(function (c) { return c.author && c.author.name; })
      .filter(function (n) { return n; }).join(", ");
    var series = (data.book_series || [])[0];
    var genres = ((b.cached_tags && b.cached_tags.Genre) || []).map(function (t) { return t.tag; }).slice(0, 6);
    var work = { authors: authors, series: series ? series.series.name : null,
                 seriesIndex: series ? series.position : null, genres: genres };
    var out = [];
    var seen = {};
    var self = this;
    // The edition the reader linked or marked on their shelf comes first.
    if (book.hardcoverEditionID) {
      var linked = this.ask("query L($id: Int!) { editions(where: {id: {_eq: $id}}, limit: 1) { " + this.editionFields + " } }",
                            { id: book.hardcoverEditionID });
      (linked && linked.editions || []).forEach(function (e) { seen[e.id] = true; out.push(self.record(e, work, book, null)); });
    }
    var filter = "";
    var name = String(book.languageName || "").replace(/[^A-Za-z ]/g, "");
    if (name) filter = ', language: {language: {_ilike: "' + name + '%"}}';
    var editions = this.ask("query E($id: Int!) { editions(where: {book_id: {_eq: $id}" + filter + "}, order_by: {users_count: desc}, limit: 12) { " +
                            this.editionFields + " } }", { id: id });
    (editions && editions.editions || []).forEach(function (e) {
      if (seen[e.id]) return;
      seen[e.id] = true;
      out.push(self.record(e, work, book, name ? book.language : null));
    });
    // The work itself: the original title, description and best-known cover.
    out.push({
      source: "Hardcover", title: b.title, authors: authors, description: b.description || null,
      language: null, series: work.series, seriesIndex: work.seriesIndex, year: b.release_year || null,
      pages: b.pages || null, cover: b.image ? b.image.url : null, genres: genres
    });
    return out;
  }
};
