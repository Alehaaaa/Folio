import Foundation

// MARK: - Lists

/// A reader-made list on Hardcover ("Best Fantasy of the 2010s"), with the
/// covers of its first books for the card.
struct HCList: Identifiable, Hashable, Codable {
    var id: Int
    var name: String
    var description: String?
    var slug: String?
    var owner: String?
    var booksCount: Int?
    var likes: Int?
    var covers: [URL] = []

    var webURL: URL? {
        guard let owner, let slug else { return nil }
        return URL(string: "https://hardcover.app/@\(owner)/lists/\(slug)")
    }

    static func from(_ j: JSON) -> HCList? {
        guard let id = j["id"].int, let name = j["name"].string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return nil }
        let text = j["description"].string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let covers = j["list_books"].array.compactMap { row in
            (row["book"]["image"]["url"].string ?? row["book"]["cached_image"]["url"].string).flatMap(URL.init(string:))
        }
        return HCList(id: id, name: name, description: text?.isEmpty == false ? text : nil,
                      slug: j["slug"].string, owner: j["user"]["username"].string,
                      booksCount: j["books_count"].int, likes: j["likes_count"].int, covers: covers)
    }
}

extension HardcoverClient {
    static let listFields = "id name description slug books_count likes_count user { username } list_books(order_by: {position: asc}, limit: 3) { book { image { url } } }"
    /// The same without the owner or covers, for schemas that refuse them.
    static let plainListFields = "id name description slug books_count likes_count"

    /// Lists worth opening: some books in them, most liked first.
    private static let worthShowing = "books_count: {_gt: 4}"

    /// Runs the first query the schema accepts. Lists are new to Folio and
    /// their fields were taken from Hardcover's docs, so each request has a
    /// plainer twin that drops the parts a stricter schema might refuse.
    private func firstAccepted(_ queries: [(String, [String: Any])]) async throws -> JSON {
        var lastError: Error?
        for (text, variables) in queries {
            do {
                return try await query(text, variables)
            } catch let error as HCError where !error.rateLimited && !error.transient {
                lastError = error
                #if os(iOS)
                FolioLog.log("Lists query refused (\(error.message)); trying a plainer one", "hardcover")
                #endif
            }
        }
        throw lastError ?? HCError(message: "Hardcover didn't return any lists.")
    }

    /// Hardcover's featured lists, then the most liked ones.
    func featuredLists(limit: Int = 20) async throws -> [HCList] {
        let d = try await firstAccepted([
            ("""
            query FeaturedLists($limit: Int!) {
              featured: lists(where: {featured: {_eq: true}, \(Self.worthShowing)}, order_by: {likes_count: desc}, limit: $limit) { \(Self.listFields) }
              liked: lists(where: {\(Self.worthShowing)}, order_by: {likes_count: desc}, limit: $limit) { \(Self.listFields) }
            }
            """, ["limit": limit]),
            ("""
            query LikedLists($limit: Int!) { liked: lists(where: {\(Self.worthShowing)}, order_by: {likes_count: desc}, limit: $limit) { \(Self.listFields) } }
            """, ["limit": limit]),
            ("""
            query PlainLists($limit: Int!) { liked: lists(order_by: {likes_count: desc}, limit: $limit) { \(Self.plainListFields) } }
            """, ["limit": limit])
        ])
        return Self.uniqueLists(d["featured"].array + d["liked"].array)
    }

    /// Lists about a genre or theme, from Hardcover's list search, most liked first.
    func searchLists(_ text: String, page: Int = 1) async throws -> [HCList] {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return [] }
        let d = try await query("""
        query SearchLists($q: String!, $page: Int!) { search(query: $q, query_type: "List", per_page: 25, page: $page) { results } }
        """, ["q": typed, "page": page])
        var results = d["search"]["results"]
        if case .string(let s) = results, let data = s.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(JSON.self, from: data) { results = decoded }
        let ids = results["hits"].array.compactMap { $0["document"]["id"].int }
        guard !ids.isEmpty else { return [] }
        let rows = try await firstAccepted([
            ("query ListsByID($ids: [Int!]) { lists(where: {id: {_in: $ids}}) { \(Self.listFields) } }", ["ids": ids]),
            ("query ListsByIDPlain($ids: [Int!]) { lists(where: {id: {_in: $ids}}) { \(Self.plainListFields) } }", ["ids": ids])
        ])
        let found = Dictionary(rows["lists"].array.compactMap(HCList.from).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Search order is relevance; nearly empty lists say little about a genre.
        return ids.compactMap { found[$0] }.filter { ($0.booksCount ?? 5) >= 3 }
    }

    /// The lists a book is on, most liked first.
    func lists(containing bookID: Int, limit: Int = 30) async throws -> [HCList] {
        let d = try await firstAccepted([
            ("""
            query ListsWithBook($id: Int!, $limit: Int!) {
              list_books(where: {book_id: {_eq: $id}, list: {\(Self.worthShowing)}}, order_by: {list: {likes_count: desc}}, limit: $limit) { list { \(Self.listFields) } }
            }
            """, ["id": bookID, "limit": limit]),
            ("""
            query ListsWithBookPlain($id: Int!, $limit: Int!) {
              list_books(where: {book_id: {_eq: $id}}, limit: $limit) { list { \(Self.plainListFields) } }
            }
            """, ["id": bookID, "limit": limit])
        ])
        let lists = Self.uniqueLists(d["list_books"].array.map { $0["list"] })
        return lists.sorted { ($0.likes ?? 0) > ($1.likes ?? 0) }
    }

    /// A page of a list's books, in the list's order, and the list itself on the first page.
    func listBooks(_ listID: Int, offset: Int = 0, limit: Int = 30) async throws -> (list: HCList?, books: [HCBook]) {
        let d = try await firstAccepted([
            ("""
            query ListBooks($id: Int!, $offset: Int!, $limit: Int!) {
              lists(where: {id: {_eq: $id}}, limit: 1) {
                \(Self.listFields)
                entries: list_books(order_by: {position: asc}, offset: $offset, limit: $limit) { book { \(Self.bookFields) } }
              }
            }
            """, ["id": listID, "offset": offset, "limit": limit]),
            ("""
            query ListBooksFlat($id: Int!, $offset: Int!, $limit: Int!) {
              lists(where: {id: {_eq: $id}}, limit: 1) { \(Self.plainListFields) }
              list_books(where: {list_id: {_eq: $id}}, order_by: {position: asc}, offset: $offset, limit: $limit) { book { \(Self.bookFields) } }
            }
            """, ["id": listID, "offset": offset, "limit": limit])
        ])
        let row = d["lists"].array.first ?? .null
        let entries = row["entries"].array.isEmpty ? d["list_books"].array : row["entries"].array
        var seen = Set<Int>()
        let books = entries.compactMap { HCBook.from(book: $0["book"]) }.filter { seen.insert($0.id).inserted }
        return (HCList.from(row), books)
    }

    static func uniqueLists(_ rows: [JSON]) -> [HCList] {
        var seen = Set<Int>()
        return rows.compactMap(HCList.from).filter { seen.insert($0.id).inserted }
    }

    // MARK: Charts

    /// The most-read books of the last `days` days, from Hardcover's trending counts.
    func trending(days: Int, limit: Int = 30) async throws -> [HCBook] {
        let to = Date()
        let from = Calendar.current.date(byAdding: .day, value: -days, to: to)!
        let d = try await query("""
        query TrendingDays($from: date!, $to: date!, $limit: Int!) { books_trending(from: $from, to: $to, limit: $limit, offset: 0) { ids } }
        """, ["from": from.isoDay, "to": to.isoDay, "limit": limit])
        var seen = Set<Int>()
        let ids = d["books_trending"]["ids"].array.compactMap(\.int).filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return [] }
        let b = try await query("query TrendingBooks($ids: [Int!]) { books(where: {id: {_in: $ids}}) { \(Self.bookFields) } }", ["ids": ids])
        let order = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return b["books"].array.compactMap(HCBook.from(book:)).sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
    }

    enum ReleaseOrder { case popular, rated, newest }

    /// Books released between two days (inclusive), with some readers already.
    func releases(from: Date, to: Date, order: ReleaseOrder = .popular, minimumRating: Double? = nil,
                  genre: String? = nil, limit: Int = 30, offset: Int = 0) async throws -> [HCBook] {
        let sort = switch order {
        case .popular: "{users_count: desc}"
        case .rated: "{rating: desc_nulls_last}"
        case .newest: "{release_date: desc}"
        }
        var conditions = ["release_date: {_gte: $from, _lte: $to}", "users_count: {_gt: 3}", "image_id: {_is_null: false}"]
        if let minimumRating { conditions.append("rating: {_gte: \(minimumRating)}") }
        var variables: [String: Any] = ["from": from.isoDay, "to": to.isoDay, "limit": limit, "offset": offset]
        var tagVariable = ""
        if let genre {
            conditions.append("cached_tags: {_contains: $tags}")
            variables["tags"] = ["Genre": [["tag": genre]]]
            tagVariable = ", $tags: jsonb!"
        }
        let text = """
        query Releases($from: date!, $to: date!, $limit: Int!, $offset: Int!\(tagVariable)) {
          books(where: {\(conditions.joined(separator: ", "))}, order_by: \(sort), limit: $limit, offset: $offset) { \(Self.bookFields) }
        }
        """
        do {
            return try await query(text, variables)["books"].array.compactMap(HCBook.from(book:))
        } catch let error as HCError where Self.isSchemaRefusal(error) {
            // Without the cover filter: books without one are dropped here instead.
            let plain = text.replacingOccurrences(of: ", image_id: {_is_null: false}", with: "")
            return try await query(plain, variables)["books"].array.compactMap(HCBook.from(book:)).filter { $0.imageURL != nil }
        }
    }

    /// Popular books in genres you read, the ones that fit most of them first.
    func picks(genres: [String], limit: Int = 30) async throws -> [HCBook] {
        guard !genres.isEmpty else { return [] }
        var out: [HCBook] = []
        var seen = Set<Int>()
        // Pairs of your top genres say more than any one of them.
        var groups: [[String]] = []
        for i in 0..<min(3, genres.count) {
            for j in (i + 1)..<min(4, genres.count) { groups.append([genres[i], genres[j]]) }
        }
        if groups.isEmpty { groups = [[genres[0]]] }
        for group in groups.prefix(3) {
            let tags: [String: Any] = ["Genre": group.map { ["tag": $0] }]
            guard let d = try? await query("""
            query Picks($tags: jsonb!) { books(where: {_and: [{cached_tags: {_contains: $tags}}, {users_count: {_gt: 50}}]}, order_by: {users_count: desc}, limit: 25) { \(Self.bookFields) } }
            """, ["tags": tags]) else { continue }
            for book in d["books"].array.compactMap(HCBook.from(book:)) where seen.insert(book.id).inserted {
                out.append(book)
            }
        }
        return Array(out.prefix(limit))
    }

    // MARK: Book page extras

    /// The number of editions and the characters Hardcover knows for a book.
    func bookExtras(bookID: Int) async -> (editions: Int?, characters: [String]) {
        if let d = try? await query("""
        query BookExtras($id: Int!) { books(where: {id: {_eq: $id}}, limit: 1) { editions_count book_characters(limit: 12) { character { name } } } }
        """, ["id": bookID]), let b = d["books"].array.first {
            let names = b["book_characters"].array.compactMap { $0["character"]["name"].string }
            return (b["editions_count"].int, names)
        }
        let d = try? await query("""
        query BookEditionsCount($id: Int!) { books(where: {id: {_eq: $id}}, limit: 1) { editions_count } }
        """, ["id": bookID])
        return (d?["books"].array.first?["editions_count"].int, [])
    }
}
