import Foundation

// MARK: - Open Library and Wikidata: keyless discovery data
//
// Browsing (Discover rows, series, similar books, more by an author) needs many
// requests and no account, so it comes from Open Library and Wikidata: both
// are free, need no API key, and have no daily cap. Hardcover is kept for the
// reader's own data (shelves, progress, ratings), where its limits are plenty.
//
// Books found here are HCBooks with a negative id (-N for Open Library work
// OLnW), so every screen that shows Hardcover books shows them too, and a book
// page matches its Hardcover record by title and author when it opens.

/// Paces requests per host and keeps every answer on disk, so a page opened
/// again, or reopened after relaunch, costs nothing.
actor FolioOpenData {
    static let shared = FolioOpenData()

    /// Open Library asks identified clients to stay under 3 requests a second.
    /// Wikidata's query service allows five queries at once; a quarter second
    /// apart keeps a page's two or three queries from queueing behind each other.
    private static let spacing: [String: TimeInterval] = ["openlibrary.org": 0.34, "query.wikidata.org": 0.25]
    private var next: [String: Date] = [:]
    private var blockedUntil: [String: Date] = [:]
    private var memory: [String: (saved: Date, json: JSON)] = [:]
    private var inFlight: [String: Task<JSON, Error>] = [:]

    static let userAgent = "Folio/1.0 (personal reading app; https://github.com/Alehaaaa/Folio)"

    private nonisolated static var directory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("folio-open-data", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private nonisolated static func file(for key: String) -> URL {
        var hash: UInt64 = 1469598103934665603
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return directory.appendingPathComponent(String(hash, radix: 16) + ".json")
    }

    /// The answer for a URL: from memory or disk while younger than `fresh`,
    /// else from the network; a failed request falls back to any older copy.
    func json(_ url: URL, fresh: TimeInterval, accept: String = "application/json") async throws -> JSON {
        let key = url.absoluteString
        let now = Date()
        if let hit = memory[key], now.timeIntervalSince(hit.saved) < fresh { return hit.json }
        let file = Self.file(for: key)
        var stale: JSON?
        if let data = try? Data(contentsOf: file), let json = try? JSONDecoder().decode(JSON.self, from: data) {
            let saved = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            memory[key] = (saved, json)
            if now.timeIntervalSince(saved) < fresh { return json }
            stale = json
        }
        if let running = inFlight[key] { return try await running.value }
        let task = Task { try await self.fetch(url, accept: accept) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            let json = try await task.value
            memory[key] = (Date(), json)
            return json
        } catch {
            if let stale, !(error is CancellationError) { return stale }
            throw error
        }
    }

    private func turn(_ host: String) async throws {
        while true {
            try Task.checkCancellation()
            let now = Date()
            let ready = max(next[host] ?? .distantPast, blockedUntil[host] ?? .distantPast)
            if ready <= now {
                next[host] = now.addingTimeInterval(Self.spacing[host] ?? 0.5)
                return
            }
            try await Task.sleep(for: .seconds(ready.timeIntervalSince(now)))
        }
    }

    private func fetch(_ url: URL, accept: String) async throws -> JSON {
        let host = url.host ?? ""
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let asked = Date()
        for attempt in 0..<3 {
            try await turn(host)
            let started = Date()
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Self.logTiming(url, status: status, waited: started.timeIntervalSince(asked),
                           took: Date().timeIntervalSince(started), bytes: data.count)
            if status == 429 || status == 503 || status == 502 || status == 504 {
                // Busy: back off for what the server asks (or a growing pause), then try again.
                let asked = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                let pause = min(30, asked ?? Double(2 << attempt))
                blockedUntil[host] = Date().addingTimeInterval(pause)
                continue
            }
            guard (200..<300).contains(status) else {
                throw HCError(message: "\(host) answered with error \(status).", transient: status >= 500)
            }
            guard let json = try? JSONDecoder().decode(JSON.self, from: data) else {
                throw HCError(message: "\(host) sent an unexpected answer.", transient: true)
            }
            let file = Self.file(for: url.absoluteString)
            Task.detached(priority: .utility) { try? data.write(to: file, options: .atomic) }
            return json
        }
        throw HCError(message: "\(host) is busy right now. Try again shortly.", rateLimited: true)
    }
}

extension FolioOpenData {
    /// Logs slow or failed requests, so a slow page can be traced to the request behind it.
    nonisolated static func logTiming(_ url: URL, status: Int, waited: TimeInterval, took: TimeInterval, bytes: Int) {
        #if os(iOS)
        guard !(200..<300).contains(status) || took > 1.5 || waited > 1 else { return }
        func seconds(_ t: TimeInterval) -> String { t.formatted(.number.precision(.fractionLength(1))) + " s" }
        let what = url.host == "query.wikidata.org" ? "sparql" : url.path
        FolioLog.log("\(what): HTTP \(status) in \(seconds(took)) after \(seconds(waited)) waiting, \(bytes / 1024) KB", "open-data")
        #endif
    }
}

enum FolioOpenLibrary {
    static let day: TimeInterval = 24 * 60 * 60

    private static let fields = [
        "key", "title", "author_name", "author_key", "cover_i", "first_publish_year", "number_of_pages_median",
        "ratings_average", "ratings_count", "subject", "editions", "editions.title", "editions.cover_i"
    ].joined(separator: ",")

    /// Open Library's work number for a negative Folio id, and back.
    static func workKey(_ id: Int) -> String? { id < 0 ? "OL\(-id)W" : nil }
    static func id(workKey key: String) -> Int? {
        let bare = key.replacingOccurrences(of: "/works/", with: "")
        guard bare.hasPrefix("OL"), bare.hasSuffix("W") else { return nil }
        return Int(bare.dropFirst(2).dropLast()).map { -$0 }
    }

    static func isOpenLibrary(_ book: HCBook) -> Bool { book.id < 0 }

    static func coverURL(_ id: Int?, size: String = "L") -> URL? {
        guard let id, id > 0 else { return nil }
        return URL(string: "https://covers.openlibrary.org/b/id/\(id)-\(size).jpg")
    }

    /// A search result as a book, titled as its edition in the reader's language.
    static func book(_ d: JSON) -> HCBook? {
        guard let key = d["key"].string, let id = id(workKey: key), let title = d["title"].string else { return nil }
        let edition = d["editions"]["docs"].array.first
        let editionTitle = edition?["title"].string.flatMap { $0.isEmpty ? nil : $0 }
        let names = d["author_name"].array.compactMap(\.string)
        let shownTitle = editionTitle ?? title
        // The edition in the reader's language has the cover in that language too.
        let cover = edition?["cover_i"].int ?? d["cover_i"].int
        var book = HCBook(id: id, title: shownTitle, authors: names.prefix(3).joined(separator: ", "),
                          imageURL: coverURL(cover), year: d["first_publish_year"].int,
                          pages: d["number_of_pages_median"].int,
                          rating: d["ratings_average"].double.map { ($0 * 100).rounded() / 100 },
                          ratingsCount: d["ratings_count"].int, description: nil, slug: nil)
        book.authorRefs = names.prefix(3).map { HCAuthorRef(id: nil, name: $0) }
        // The work's own title (often the original) and other edition titles, so a book
        // read in one language is recognised when it is shown in another.
        book.alternateTitles = HCBook.otherTitles([title] + d["editions"]["docs"].array.compactMap { $0["title"].string },
                                                  besides: shownTitle)
        return book
    }

    private static func language() -> String { BookLanguage.reading }

    /// Open Library search, cached for `fresh`.
    static func search(_ q: String, sort: String? = nil, limit: Int = 24, offset: Int = 0,
                       fresh: TimeInterval = day) async throws -> [JSON] {
        var parts = URLComponents(string: "https://openlibrary.org/search.json")!
        var items = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "fields", value: fields),
                     URLQueryItem(name: "lang", value: language()),
                     URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))]
        if let sort { items.append(URLQueryItem(name: "sort", value: sort)) }
        parts.queryItems = items
        return try await FolioOpenData.shared.json(parts.url!, fresh: fresh)["docs"].array
    }

    /// Books worth showing: with a cover and an author, each work once.
    static func books(_ docs: [JSON]) -> [HCBook] {
        var seen = Set<Int>()
        return docs.compactMap(book).filter { $0.imageURL != nil && !$0.authors.isEmpty && seen.insert($0.id).inserted }
    }

    // MARK: Discover

    static func trending() async throws -> [HCBook] {
        let url = URL(string: "https://openlibrary.org/trending/weekly.json?limit=60")!
        let works = try await FolioOpenData.shared.json(url, fresh: 6 * 60 * 60)["works"].array
        let keys = works.compactMap { $0["key"].string }.prefix(40)
        guard !keys.isEmpty else { return [] }
        // Trending entries lack ratings and translated titles: look them up in one search.
        let found = try await lookup(Array(keys))
        return keys.compactMap { key in id(workKey: key).flatMap { found[$0] } }
    }

    /// Several works in one request, by Open Library work key.
    static func lookup(_ keys: [String]) async throws -> [Int: HCBook] {
        guard !keys.isEmpty else { return [:] }
        let bare = keys.map { $0.hasPrefix("/works/") ? $0 : "/works/" + $0 }
        let docs = try await search("key:(\(bare.joined(separator: " OR ")))", limit: bare.count, fresh: 3 * day)
        return Dictionary(books(docs).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Open Library's subject names for the Discover genres.
    static func subject(_ genre: String) -> String {
        switch genre.lowercased() {
        case "science fiction": "science_fiction"
        case "historical fiction": "historical_fiction"
        case "literary fiction": "literary_fiction"
        case "young adult": "young_adult_fiction"
        case "graphic novels": "graphic_novels"
        case "self help": "self-help"
        case "nonfiction": "nonfiction"
        default: genre.lowercased().replacingOccurrences(of: " ", with: "_")
        }
    }

    static func discoverBooks(_ topic: FolioDiscoverTopic, filters: FolioDiscoverFilters = .init(),
                              limit: Int = 24, offset: Int = 0) async throws -> [HCBook] {
        if case .trending = topic.kind {
            guard offset == 0 else { return [] }
            return filters.apply(try await trending())
        }
        let year = Calendar.current.component(.year, from: .now)
        var terms: [String] = []
        var sort = filters.sort
        func years(_ from: Int?, _ to: Int?) {
            guard from != nil || to != nil else { return }
            terms.append("first_publish_year:[\(from.map(String.init) ?? "*") TO \(to.map { String($0 - 1) } ?? "*")]")
        }
        switch topic.kind {
        case .trending: break
        case .popular: terms.append("ratings_count:[50 TO *]")
        case .newThisYear: years(year, nil)
        case .acclaimed:
            terms.append("ratings_count:[150 TO *]")
            if filters.sort == .popular { sort = .rated }
        case .shortReads: terms.append("number_of_pages_median:[60 TO 249]"); terms.append("ratings_count:[20 TO *]")
        case .longReads: terms.append("number_of_pages_median:[601 TO *]"); terms.append("ratings_count:[20 TO *]")
        case .years(let from, let to): years(from, to); terms.append("ratings_count:[10 TO *]")
        case .genre(let genre): terms.append("subject_key:\(subject(genre))")
        case .author(let name): terms.append("author:(\(quoted(name)))")
        }
        var byAuthor = false
        if case .author = topic.kind { byAuthor = true }
        if let range = filters.published.range { years(range.from, range.to) }
        if let minimum = filters.rating.minimum {
            terms.append("ratings_average:[\(minimum) TO *]")
            terms.append("ratings_count:[10 TO *]")
        }
        // One author's list is short already: rank it by rating without dropping lesser-known books.
        if sort == .rated, filters.rating.minimum == nil, topic.kind != .acclaimed, !byAuthor {
            terms.append("ratings_count:[50 TO *]")
        }
        let order: String = switch sort {
        case .popular: "readinglog"
        case .rated: "rating"
        case .newest: "new"
        case .oldest: "old"
        }
        // Exam prep and textbooks fill "new" and "short" lists on Open Library; leave them out.
        terms += ["-subject_key:examinations", "-subject_key:study_guides", "-subject_key:textbooks",
                  "-subject_key:examinations_questions_etc", "-subject_key:study_guide", "-subject_key:test_preparation", "-subject_key:board_exam_preparation"]
        // Ask for a few more than shown: results without a cover are left out.
        let docs = try await search(terms.joined(separator: " "), sort: order, limit: limit + 8, offset: offset,
                                    fresh: 12 * 60 * 60)
        return Array(books(docs).prefix(limit))
    }

    // MARK: Related books

    /// The Open Library work for a Hardcover book, by title and author.
    static func work(title: String, author: String) async -> HCBook? {
        let cleanAuthor = author.split(separator: ",").first.map(String.init) ?? author
        guard let docs = try? await search("title:(\(quoted(title))) author:(\(quoted(cleanAuthor)))", limit: 5, fresh: 7 * day)
        else { return nil }
        return books(docs).first ?? docs.compactMap(book).first
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\"", with: " ").replacingOccurrences(of: "\\", with: " ") + "\""
    }

    /// The work's plain subjects ("Fantasy", "Magic"), without Open Library's tagged ones ("series:…").
    static func subjects(of book: HCBook) async -> [String] {
        guard let key = workKey(book.id),
              let doc = try? await search("key:/works/\(key)", limit: 1, fresh: 7 * day).first else { return [] }
        return doc["subject"].array.compactMap(\.string).filter { !$0.contains(":") && $0.count < 30 }.prefix(6).map { $0 }
    }

    /// The work's description, for books opened from Open Library.
    static func description(of book: HCBook) async -> String? {
        guard let key = workKey(book.id),
              let work = try? await FolioOpenData.shared.json(URL(string: "https://openlibrary.org/works/\(key).json")!, fresh: 7 * day)
        else { return nil }
        let text = (work["description"]["value"].string ?? work["description"].string)?
            .components(separatedBy: "\n----------").first?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    /// The author's best-known books.
    /// The book page and the author page both ask for `authorPageLimit`, so opening
    /// the author from a book reuses the answer the book page already has.
    static let authorPageLimit = 60

    static func booksBy(author: String, sort: String = "readinglog", limit: Int = 30) async throws -> [HCBook] {
        let docs = try await search("author:(\(quoted(author)))", sort: sort, limit: limit, fresh: 3 * day)
        return books(docs)
    }

    /// What an author's books are filed under, most common first, from the same
    /// request as their popular books (so it is usually already saved).
    static func authorSubjects(name: String) async -> [String] {
        guard let docs = try? await search("author:(\(quoted(name)))", sort: "readinglog", limit: authorPageLimit, fresh: 3 * day)
        else { return [] }
        let vague: Set<String> = [
            "fiction", "juvenile fiction", "accessible book", "protected daisy", "in library", "large type books",
            "lending library", "general", "adult", "nonfiction", "non-fiction", "english language", "literature",
            "american literature", "english literature", "children's fiction", "juvenile literature", "novel", "novels",
            "open library staff picks", "american fiction", "english fiction", "fiction in english", "translations into english"
        ]
        var counts: [String: (name: String, count: Int)] = [:]
        for doc in docs {
            var seen = Set<String>()
            for subject in doc["subject"].array.compactMap(\.string) {
                let key = subject.lowercased().trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, key.count < 30, !key.contains(":"), !key.contains(", general"),
                      !key.hasPrefix("reading level"), !key.contains("award"), !key.contains("medal"),
                      !vague.contains(key), seen.insert(key).inserted else { continue }
                counts[key, default: (subject, 0)].count += 1
            }
        }
        let floor = docs.count >= 6 ? 2 : 1
        return counts.values.filter { $0.count >= floor }.sorted { $0.count > $1.count }.map(\.name)
    }

    /// Popular books sharing the book's genres.
    static func similar(to book: HCBook, genres: [String]) async throws -> [HCBook] {
        let picked = genres.prefix(2).map { "subject:(\(quoted($0)))" }
        guard !picked.isEmpty else { return [] }
        let docs = try await search(picked.joined(separator: " AND "), sort: "readinglog", limit: 30, fresh: 3 * day)
        let firstAuthor = book.authors.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) }
        return books(docs).filter {
            !BookAutoMatch.sameTitle($0.title, book.title) && $0.authors.split(separator: ",").first.map {
                $0.trimmingCharacters(in: .whitespaces) } != firstAuthor
        }
    }
}

// MARK: - Authors

extension FolioOpenLibrary {
    /// The author as Open Library knows them (bio, photo, dates) and their Wikidata
    /// id, for the series. Author ids are negative (-N for OLnA).
    static func authorProfile(name: String) async throws -> (author: HCAuthor, wikidata: String?)? {
        guard let doc = try await authorRecord(name: name), let key = doc["key"].string,
              let number = Int(key.dropFirst(2).dropLast()) else { return nil }
        let record = (try? await FolioOpenData.shared.json(URL(string: "https://openlibrary.org/authors/\(key).json")!, fresh: 7 * day)) ?? .null
        let bio = (record["bio"]["value"].string ?? record["bio"].string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let photo = record["photos"].array.compactMap(\.int).first { $0 > 0 }
        func year(_ text: String?) -> Int? {
            text?.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.first { $0 > 999 }
        }
        let author = HCAuthor(id: -number, name: record["name"].string ?? doc["name"].string ?? name, slug: nil,
                              bio: bio?.isEmpty == false ? bio : nil,
                              imageURL: photo == nil ? nil : authorPhotoURL(key: key),
                              bornYear: year(record["birth_date"].string), deathYear: year(record["death_date"].string),
                              booksCount: doc["work_count"].int, followers: nil)
        return (author, record["remote_ids"]["wikidata"].string)
    }

    /// The author's search record ("key", "name", "work_count"): one quick request.
    /// The same name can have several records: the one with the most works is the author.
    static func authorRecord(name: String) async throws -> JSON? {
        var parts = URLComponents(string: "https://openlibrary.org/search/authors.json")!
        parts.queryItems = [URLQueryItem(name: "q", value: name), URLQueryItem(name: "limit", value: "5"),
                            URLQueryItem(name: "fields", value: "key,name,work_count")]
        let docs = try await FolioOpenData.shared.json(parts.url!, fresh: 7 * day)["docs"].array
        let named = docs.filter { BookAutoMatch.sameAuthor($0["name"].string ?? "", name) }
        guard let doc = (named.isEmpty ? docs : named).max(by: { ($0["work_count"].int ?? 0) < ($1["work_count"].int ?? 0) }),
              let key = doc["key"].string, key.hasPrefix("OL"), key.hasSuffix("A") else { return nil }
        return doc
    }

    /// The author's photo by record key, so it can load as soon as the search
    /// answers instead of after the full record. Without a photo it is a 404.
    static func authorPhotoURL(key: String) -> URL? {
        URL(string: "https://covers.openlibrary.org/a/olid/\(key)-L.jpg?default=false")
    }

    /// The photo for an author's name, after the one search request.
    static func authorPhoto(name: String) async -> URL? {
        guard let key = (try? await authorRecord(name: name))?["key"].string else { return nil }
        return authorPhotoURL(key: key)
    }

    /// The author's newest books, most recent first, without announced titles far ahead.
    static func newestBooks(author: String) async throws -> [HCBook] {
        let thisYear = Calendar.current.component(.year, from: Date())
        return try await booksBy(author: author, sort: "new", limit: 30).filter { ($0.year ?? 0) <= thisYear + 1 }
    }
}

// MARK: - Series from Wikidata

/// Series and their reading order, from Wikidata's "part of the series" statements.
/// Series ids are negative Wikidata numbers (-268100 for Q268100), so they never
/// collide with Hardcover series saved before.
enum FolioWikidataSeries {
    struct Membership: Hashable { var id: Int; var name: String; var position: Double? }

    static func id(_ uri: String) -> Int? {
        guard let q = uri.split(separator: "/").last, q.hasPrefix("Q"), let n = Int(q.dropFirst()) else { return nil }
        return -n
    }

    private static func sparql(_ query: String, fresh: TimeInterval) async throws -> [JSON] {
        var parts = URLComponents(string: "https://query.wikidata.org/sparql")!
        parts.queryItems = [URLQueryItem(name: "query", value: query), URLQueryItem(name: "format", value: "json")]
        return try await FolioOpenData.shared.json(parts.url!, fresh: fresh, accept: "application/sparql-results+json")["results"]["bindings"].array
    }

    private static func label() -> String {
        let code = BookLanguage.reading
        return code == "en" ? "en" : "\(code),en"
    }

    /// The series an Open Library work belongs to, most specific (numbered) first.
    static func series(ofWork key: String) async throws -> [Membership] {
        let bare = key.replacingOccurrences(of: "/works/", with: "")
        guard bare.allSatisfy({ $0.isLetter || $0.isNumber }) else { return [] }
        let rows = try await sparql("""
        SELECT ?series ?seriesLabel ?ord WHERE {
          ?book wdt:P648 "\(bare)" . ?book p:P179 ?st . ?st ps:P179 ?series .
          OPTIONAL { ?st pq:P1545 ?ord }
          SERVICE wikibase:label { bd:serviceParam wikibase:language "\(label())". }
        }
        """, fresh: 7 * FolioOpenLibrary.day)
        var out: [Membership] = []
        for r in rows {
            guard let uri = r["series"]["value"].string, let id = id(uri),
                  let name = r["seriesLabel"]["value"].string, !out.contains(where: { $0.id == id }) else { continue }
            out.append(Membership(id: id, name: name, position: r["ord"]["value"].string.flatMap(Double.init)))
        }
        // A numbered place ("Mistborn #2") says more than a universe ("Cosmere").
        return out.sorted { ($0.position != nil ? 0 : 1) < ($1.position != nil ? 0 : 1) }
    }

    /// An author's series, the one with the most of their books first.
    static func series(ofAuthor qid: String) async throws -> [HCSeriesRef] {
        guard qid.hasPrefix("Q"), qid.dropFirst().allSatisfy(\.isNumber) else { return [] }
        let rows = try await sparql("""
        SELECT ?series ?seriesLabel (COUNT(DISTINCT ?book) AS ?n) (GROUP_CONCAT(DISTINCT ?olid; separator=" ") AS ?olids) WHERE {
          ?book wdt:P50 wd:\(qid) ; wdt:P179 ?series .
          OPTIONAL { ?book wdt:P648 ?olid }
          SERVICE wikibase:label { bd:serviceParam wikibase:language "\(label())". ?series rdfs:label ?seriesLabel }
        } GROUP BY ?series ?seriesLabel ORDER BY DESC(?n) LIMIT 30
        """, fresh: 7 * FolioOpenLibrary.day)
        return rows.compactMap { r in
            guard let uri = r["series"]["value"].string, let id = id(uri),
                  let name = r["seriesLabel"]["value"].string, !name.hasPrefix("Q") || name.contains(" ") else { return nil }
            let ids = (r["olids"]["value"].string ?? "").split(separator: " ").compactMap { FolioOpenLibrary.id(workKey: String($0)) }
            return HCSeriesRef(id: id, name: name, booksCount: r["n"]["value"].string.flatMap(Int.init), bookIDs: ids)
        }
    }

    /// The series for a book shown anywhere: by its Open Library work, found by title and author when needed.
    static func series(of book: HCBook) async -> [Membership] {
        var key = FolioOpenLibrary.workKey(book.id)
        if key == nil { key = await FolioOpenLibrary.work(title: book.title, author: book.authors).flatMap { FolioOpenLibrary.workKey($0.id) } }
        guard let key else { return [] }
        return (try? await series(ofWork: key)) ?? []
    }

    /// Every book in a series, in reading order, with Open Library's covers and ratings.
    static func books(_ seriesID: Int) async throws -> [HCSeriesBook] {
        guard seriesID < 0 else { return [] }
        let rows = try await sparql("""
        SELECT ?book ?bookLabel ?ord ?olid ?date WHERE {
          ?book p:P179 ?st . ?st ps:P179 wd:Q\(-seriesID) .
          OPTIONAL { ?st pq:P1545 ?ord }
          OPTIONAL { ?book wdt:P648 ?olid }
          OPTIONAL { ?book wdt:P577 ?date }
          SERVICE wikibase:label { bd:serviceParam wikibase:language "\(label())". }
        } LIMIT 200
        """, fresh: 7 * FolioOpenLibrary.day)
        struct Row { var position: Double?; var key: String?; var title: String; var year: Int? }
        var list: [Row] = []
        for r in rows {
            let key = r["olid"]["value"].string.flatMap { $0.hasSuffix("W") ? $0 : nil }
            let position = r["ord"]["value"].string.flatMap(Double.init)
            let title = r["bookLabel"]["value"].string ?? ""
            // One row per book, preferring its work id.
            if let i = list.firstIndex(where: { $0.title == title && $0.position == position }) {
                if list[i].key == nil { list[i].key = key }
                continue
            }
            let year = r["date"]["value"].string.flatMap { Int($0.prefix(4)) }
            list.append(Row(position: position, key: key, title: title, year: year))
        }
        let found = try await FolioOpenLibrary.lookup(Array(Set(list.compactMap(\.key))))
        var out: [HCSeriesBook] = []
        var seen = Set<Int>()
        for row in list {
            guard let key = row.key, let id = FolioOpenLibrary.id(workKey: key), let book = found[id],
                  seen.insert(id).inserted else { continue }
            out.append(HCSeriesBook(position: row.position, book: book))
        }
        return out.sorted { ($0.position ?? .infinity, $0.book.year ?? .max) < ($1.position ?? .infinity, $1.book.year ?? .max) }
    }
}
