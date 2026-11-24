// Folio metadata source: Google Books.
// Called by Edit Details as source.metadata(book) with
// { title, author, language, languageName, isbn, hardcoverBookID, hardcoverEditionID, series, seriesIndex }.
// Returns records: { source, title, authors, description, publisher, language, isbn, series,
// seriesIndex, year, pages, cover, genres, rating }.
var source = {
  id: "metadata-google-books",
  kind: "metadata",
  name: "Google Books",
  description: "Descriptions, covers, publishers and categories in the book's language.",
  version: "1.0.1",
  languages: ["*"],
  allowedHosts: ["https://www.googleapis.com"],
  settings: [],

  plain: function (title) {
    return String(title || "").replace(/\s*[\(\[].*?[\)\]]\s*/g, " ").split(/[:;]/)[0].trim();
  },

  surname: function (author) {
    var first = String(author || "").split(/,|&| and | y /)[0].trim();
    var parts = first.split(/\s+/);
    return parts[parts.length - 1] || first;
  },

  query: function (q, language) {
    var url = "https://www.googleapis.com/books/v1/volumes?maxResults=12&printType=books&q=" + encodeURIComponent(q);
    if (language) url += "&langRestrict=" + encodeURIComponent(language);
    try { return folio.fetchJSON(url).items || []; } catch (e) { folio.log("Google Books: " + e); return []; }
  },

  metadata: function (book) {
    var items = [];
    if (book.isbn) items = this.query("isbn:" + book.isbn, "");
    var more = this.query("intitle:" + this.plain(book.title) + " inauthor:" + this.surname(book.author), book.language);
    var seen = {};
    var out = [];
    items.concat(more).forEach(function (v) {
      if (!v || seen[v.id]) return;
      seen[v.id] = true;
      var info = v.volumeInfo || {};
      if (!info.title) return;
      var ids = info.industryIdentifiers || [];
      var isbn = null;
      ids.forEach(function (i) { if (i.type === "ISBN_13") isbn = i.identifier; });
      if (!isbn) ids.forEach(function (i) { if (i.type === "ISBN_10") isbn = i.identifier; });
      var cover = null;
      var links = info.imageLinks || {};
      var raw = links.extraLarge || links.large || links.medium || links.thumbnail || links.smallThumbnail;
      if (raw) cover = raw.replace("http://", "https://").replace("&edge=curl", "") + (links.thumbnail === raw ? "&fife=w800-h1200" : "");
      out.push({
        source: "Google Books",
        title: info.title + (info.subtitle ? ": " + info.subtitle : ""),
        authors: (info.authors || []).join(", "),
        description: info.description || null,
        publisher: info.publisher || null,
        language: info.language || null,
        isbn: isbn,
        year: info.publishedDate ? parseInt(info.publishedDate.slice(0, 4), 10) || null : null,
        pages: info.pageCount || null,
        cover: cover,
        genres: info.categories || [],
        rating: info.averageRating || null
      });
    });
    return out.slice(0, 10);
  }
};
