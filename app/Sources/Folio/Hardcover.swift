import Foundation
import Observation
import Security

// MARK: - Loose JSON (Hardcover returns jsonb columns whose shape varies)

enum JSON: Decodable, Hashable {
    case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSON].self) { self = .object(o) }
        else { self = .null }
    }

    subscript(_ key: String) -> JSON {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    var array: [JSON] { if case .array(let a) = self { return a }; return [] }
    var string: String? {
        switch self {
        case .string(let s): s
        case .number(let n): n == n.rounded() ? String(Int(n)) : String(n)
        default: nil
        }
    }
    var int: Int? {
        switch self {
        case .number(let n): Int(n)
        case .string(let s): Int(s)
        default: nil
        }
    }
    var double: Double? {
        switch self {
        case .number(let n): n
        case .string(let s): Double(s)
        default: nil
        }
    }
    var isNull: Bool { if case .null = self { return true }; return false }
}

// MARK: - Models

/// Hardcover's reading statuses (user_books.status_id).
enum HCStatus: Int, CaseIterable, Identifiable, Codable {
    case wantToRead = 1, reading = 2, read = 3, paused = 4, dnf = 5
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .wantToRead: "Want to Read"
        case .reading: "Currently Reading"
        case .read: "Read"
        case .paused: "Paused"
        case .dnf: "Did Not Finish"
        }
    }

    /// Short label for the row of status buttons.
    var shortLabel: String {
        switch self {
        case .wantToRead: "Want to Read"
        case .reading: "Reading"
        case .read: "Read"
        case .paused: "Paused"
        case .dnf: "DNF"
        }
    }

    var symbol: String {
        switch self {
        case .wantToRead: "bookmark"
        case .reading: "book"
        case .read: "checkmark.circle"
        case .paused: "pause.circle"
        case .dnf: "xmark.circle"
        }
    }

    var local: ReadingStatus {
        switch self {
        case .wantToRead: .wantToRead
        case .reading, .paused: .reading
        case .read: .finished
        case .dnf: .none
        }
    }
}

struct HCBook: Identifiable, Hashable {
    var id: Int
    var title: String
    var authors: String
    var imageURL: URL?
    var year: Int?
    var pages: Int?
    var rating: Double?
    var ratingsCount: Int?
    var description: String?
    var slug: String?

    var webURL: URL? { slug.flatMap { URL(string: "https://hardcover.app/books/\($0)") } }

    static func from(book j: JSON) -> HCBook? {
        guard let id = j["id"].int else { return nil }
        var names: [String] = []
        for c in j["cached_contributors"].array {
            if let n = c["author"]["name"].string ?? c["name"].string { names.append(n) }
        }
        if names.isEmpty {
            for c in j["contributions"].array { if let n = c["author"]["name"].string { names.append(n) } }
        }
        let img = j["image"]["url"].string ?? j["cached_image"]["url"].string
        return HCBook(
            id: id,
            title: j["title"].string ?? "Untitled",
            authors: names.joined(separator: ", "),
            imageURL: img.flatMap(URL.init(string:)),
            year: j["release_year"].int,
            pages: j["pages"].int,
            rating: j["rating"].double,
            ratingsCount: j["ratings_count"].int,
            description: j["description"].string,
            slug: j["slug"].string
        )
    }

    static func from(searchDocument d: JSON) -> HCBook? {
        guard let id = d["id"].int else { return nil }
        let authors = d["author_names"].array.compactMap(\.string)
        let img = d["image"]["url"].string
        return HCBook(
            id: id,
            title: d["title"].string ?? "Untitled",
            authors: authors.joined(separator: ", "),
            imageURL: img.flatMap(URL.init(string:)),
            year: d["release_year"].int,
            pages: d["pages"].int,
            rating: d["rating"].double,
            ratingsCount: d["ratings_count"].int,
            description: d["description"].string,
            slug: d["slug"].string
        )
    }
}

struct HCUserBook: Identifiable, Hashable {
    var id: Int
    var status: HCStatus?
    var rating: Double?
    var book: HCBook
    var readID: Int?
    var progressPages: Int?
    var startedAt: String?
    var finishedAt: String?
    var dateAdded: String?

    static func from(_ j: JSON) -> HCUserBook? {
        guard let id = j["id"].int, let book = HCBook.from(book: j["book"]) else { return nil }
        let read = j["user_book_reads"].array.first ?? .null
        return HCUserBook(
            id: id,
            status: j["status_id"].int.flatMap(HCStatus.init(rawValue:)),
            rating: j["rating"].double,
            book: book,
            readID: read["id"].int,
            progressPages: read["progress_pages"].int,
            startedAt: read["started_at"].string,
            finishedAt: read["finished_at"].string,
            dateAdded: j["date_added"].string
        )
    }
}

struct HCUser: Hashable {
    var id: Int
    var username: String
    var name: String?
    var imageURL: URL?
}

// MARK: - Token storage (Keychain)

enum Keychain {
    static let service = "Folio.Hardcover"
    static let account = "api-token"

    static func read() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func write(_ token: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let token, !token.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Client

struct HCError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

@Observable
@MainActor
final class HardcoverClient {
    static let shared = HardcoverClient()

    var user: HCUser?
    var connecting = false
    var lastError: String?
    /// Bumped whenever something changes on Hardcover, so shelves reload.
    var revision = 0

    private var token: String?
    private let endpoint = URL(string: "https://api.hardcover.app/v1/graphql")!

    var isConnected: Bool { user != nil }
    var hasToken: Bool { token != nil }

    private init() {
        // Isolated screenshot builds should never request access to a person's
        // production keychain item (which can block launch behind a prompt).
        token = ProcessInfo.processInfo.environment["FOLIO_PREVIEW_NO_KEYCHAIN"] == "1"
            ? nil : Keychain.read()
    }

    func restore() async {
        guard token != nil, user == nil else { return }
        await loadMe()
    }

    static func normalize(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("bearer ") { t = String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
        return t
    }

    func connect(token raw: String) async {
        let t = Self.normalize(raw)
        guard !t.isEmpty else { return }
        token = t
        await loadMe()
        if user != nil { Keychain.write(t) } else { token = Keychain.read() }
    }

    func disconnect() {
        Keychain.write(nil)
        token = nil
        user = nil
        revision += 1
    }

    private func loadMe() async {
        connecting = true
        defer { connecting = false }
        do {
            let d = try await query("query { me { id username name image { url } } }")
            let me = d["me"].array.first ?? d["me"]
            guard let id = me["id"].int else { throw HCError(message: "Hardcover didn't recognise this token.") }
            user = HCUser(id: id, username: me["username"].string ?? "reader", name: me["name"].string,
                          imageURL: me["image"]["url"].string.flatMap(URL.init(string:)))
            lastError = nil
            revision += 1
            LibraryStore.shared.enqueueUnlinkedEPUBs()
        } catch {
            user = nil
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func query(_ q: String, _ variables: [String: Any] = [:]) async throws -> JSON {
        guard let token else { throw HCError(message: "Connect your Hardcover account in Settings first.") }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("Folio/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["query": q, "variables": variables])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = try JSONDecoder().decode(JSON.self, from: data)
        if let msg = json["errors"].array.first?["message"].string { throw HCError(message: msg) }
        if let msg = json["error"].string ?? json["message"].string { throw HCError(message: msg) }
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw HCError(message: "Hardcover answered with error \(http.statusCode).")
        }
        return json["data"]
    }

    static let bookFields = "id title slug pages release_year rating ratings_count description cached_contributors image { url }"
    static let userBookFields = "id status_id rating date_added book { \(bookFields) } user_book_reads(order_by: {id: desc}, limit: 1) { id progress_pages started_at finished_at }"

    // MARK: Reads

    func shelf(_ status: HCStatus) async throws -> [HCUserBook] {
        guard let user else { throw HCError(message: "Not connected.") }
        let d = try await query("""
        query Shelf($uid: Int!, $status: Int!) {
          user_books(where: {user_id: {_eq: $uid}, status_id: {_eq: $status}}, order_by: {updated_at: desc}, limit: 200) { \(Self.userBookFields) }
        }
        """, ["uid": user.id, "status": status.rawValue])
        return d["user_books"].array.compactMap(HCUserBook.from)
    }

    func allUserBooks() async throws -> [HCUserBook] {
        guard let user else { throw HCError(message: "Not connected.") }
        let d = try await query("""
        query All($uid: Int!) {
          user_books(where: {user_id: {_eq: $uid}}, order_by: {updated_at: desc}, limit: 1000) { \(Self.userBookFields) }
        }
        """, ["uid": user.id])
        return d["user_books"].array.compactMap(HCUserBook.from)
    }

    func userBook(bookID: Int) async throws -> HCUserBook? {
        guard let user else { return nil }
        let d = try await query("""
        query Mine($uid: Int!, $bid: Int!) {
          user_books(where: {user_id: {_eq: $uid}, book_id: {_eq: $bid}}, limit: 1) { \(Self.userBookFields) }
        }
        """, ["uid": user.id, "bid": bookID])
        return d["user_books"].array.first.flatMap(HCUserBook.from)
    }

    func book(id: Int) async throws -> HCBook? {
        let d = try await query("query Book($id: Int!) { books(where: {id: {_eq: $id}}, limit: 1) { \(Self.bookFields) } }", ["id": id])
        return d["books"].array.first.flatMap(HCBook.from(book:))
    }

    /// The series (sagas) a book belongs to, with its place in each.
    func series(forBook id: Int) async throws -> [(id: Int, name: String, position: Double?)] {
        let d = try await query("""
        query BookSeries($id: Int!) { book_series(where: {book_id: {_eq: $id}}) { position series { id name } } }
        """, ["id": id])
        let all: [(id: Int, name: String, position: Double?)] = d["book_series"].array.compactMap { r in
            guard let sid = r["series"]["id"].int, let name = r["series"]["name"].string else { return nil }
            return (sid, name, r["position"].double)
        }
        // Hardcover often lists the same saga twice ("Red Rising" and "Red Rising Saga"):
        // keep one per name, preferring the fuller name.
        var out: [(id: Int, name: String, position: Double?)] = []
        for s in all {
            let key = Self.seriesKey(s.name)
            if let i = out.firstIndex(where: { Self.seriesKey($0.name) == key && ($0.position == nil || s.position == nil || $0.position == s.position) }) {
                if s.name.count > out[i].name.count { out[i] = (s.id, s.name, s.position ?? out[i].position) }
            } else {
                out.append(s)
            }
        }
        return out
    }

    static func seriesKey(_ name: String) -> String {
        var words = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let filler: Set<String> = ["the", "saga", "series", "trilogy", "cycle", "chronicles", "sequence", "books", "novels", "universe"]
        let trimmed = words.filter { !filler.contains($0) }
        if !trimmed.isEmpty { words = trimmed }
        return words.joined()
    }

    func seriesID(named name: String) async throws -> Int? {
        let d = try await query("query SeriesByName($n: String!) { series(where: {name: {_eq: $n}}, order_by: {books_count: desc}, limit: 1) { id } }", ["n": name])
        return d["series"].array.first?["id"].int
    }

    func seriesBooks(_ id: Int) async throws -> [(position: Double?, book: HCBook)] {
        // Hardcover lists every edition and translation that joined a series. Ask for the most-read
        // first so each place in the series shows the edition most readers know.
        var rows: [JSON] = []
        var popularity = true
        if let d = try? await query("""
        query SeriesBooks($id: Int!) { book_series(where: {series_id: {_eq: $id}}, order_by: [{position: asc}, {book: {users_count: desc}}], limit: 200) { position book { users_count \(Self.bookFields) } } }
        """, ["id": id]) {
            rows = d["book_series"].array
        } else {
            popularity = false
            let d = try await query("""
            query SeriesBooksPlain($id: Int!) { book_series(where: {series_id: {_eq: $id}}, order_by: {position: asc}, limit: 200) { position book { \(Self.bookFields) } } }
            """, ["id": id])
            rows = d["book_series"].array
        }
        let top = popularity ? (rows.compactMap { $0["book"]["users_count"].int }.max() ?? 0) : 0
        var seen = Set<Int>()
        var out: [(Double?, HCBook)] = []
        for r in rows {
            guard let b = HCBook.from(book: r["book"]), !seen.contains(b.id) else { continue }
            let pos = r["position"].double
            if let pos, out.contains(where: { $0.0 == pos }) { continue } // another edition of the same entry
            // Rarely-read entries are usually split or foreign editions (e.g. "Partie 1"): leave them out.
            if popularity, top > 50, (r["book"]["users_count"].int ?? 0) < max(5, top / 40) { continue }
            seen.insert(b.id)
            out.append((pos, b))
        }
        return out.map { (position: $0.0, book: $0.1) }
    }

    func search(_ text: String) async throws -> [HCBook] {
        let d = try await query("""
        query Search($q: String!) { search(query: $q, query_type: "Book", per_page: 30, page: 1) { results } }
        """, ["q": text])
        var results = d["search"]["results"]
        if case .string(let s) = results, let data = s.data(using: .utf8), let j = try? JSONDecoder().decode(JSON.self, from: data) { results = j }
        return results["hits"].array.compactMap { HCBook.from(searchDocument: $0["document"]) }
    }

    func bookID(isbn: String) async throws -> Int? {
        let d = try await query("""
        query ISBN($isbn: String!) { editions(where: {_or: [{isbn_13: {_eq: $isbn}}, {isbn_10: {_eq: $isbn}}]}, limit: 1) { book_id } }
        """, ["isbn": isbn])
        return d["editions"].array.first?["book_id"].int
    }

    /// Match imported EPUB ISBNs only when all matching editions point to one book.
    func bookIDs(isbn: String) async throws -> [Int] {
        let d = try await query("""
        query ISBNBooks($isbn: String!) {
          editions(where: {_or: [{isbn_13: {_eq: $isbn}}, {isbn_10: {_eq: $isbn}}]}, limit: 30) { book_id }
        }
        """, ["isbn": isbn])
        let editions = d["editions"].array
        // A full response might be truncated. Treat it as ambiguous.
        guard editions.count < 30 else { return [] }
        return Set(editions.compactMap { $0["book_id"].int }).sorted()
    }

    func trending() async throws -> [HCBook] {
        let to = Date()
        let from = Calendar.current.date(byAdding: .month, value: -1, to: to)!
        if let d = try? await query("""
        query Trending($from: date!, $to: date!) { books_trending(from: $from, to: $to, limit: 30, offset: 0) { ids } }
        """, ["from": from.isoDay, "to": to.isoDay]) {
            let ids = d["books_trending"]["ids"].array.compactMap(\.int)
            if !ids.isEmpty {
                let b = try await query("query Books($ids: [Int!]) { books(where: {id: {_in: $ids}}) { \(Self.bookFields) } }", ["ids": ids])
                let books = b["books"].array.compactMap(HCBook.from(book:))
                let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
                return books.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
            }
        }
        let d = try await query("query Popular { books(order_by: {users_count: desc}, limit: 30) { \(Self.bookFields) } }")
        return d["books"].array.compactMap(HCBook.from(book:))
    }

    // MARK: Writes

    @discardableResult
    func setStatus(bookID: Int, status: HCStatus) async -> HCUserBook? {
        do {
            if let existing = try await userBook(bookID: bookID) {
                try await query("""
                mutation Status($id: Int!, $status: Int!) { update_user_book(id: $id, object: {status_id: $status}) { id error } }
                """, ["id": existing.id, "status": status.rawValue])
                if status == .read, let rid = existing.readID {
                    _ = try? await query("""
                    mutation Done($id: Int!, $d: date) { update_user_book_read(id: $id, object: {finished_at: $d}) { id error } }
                    """, ["id": rid, "d": Date().isoDay])
                }
            } else {
                try await query("""
                mutation Add($bid: Int!, $status: Int!) { insert_user_book(object: {book_id: $bid, status_id: $status}) { id error } }
                """, ["bid": bookID, "status": status.rawValue])
            }
            revision += 1
            lastError = nil
            return try await userBook(bookID: bookID)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func setRating(userBookID: Int, rating: Double?) async {
        do {
            try await query("""
            mutation Rate($id: Int!, $r: numeric) { update_user_book(id: $id, object: {rating: $r}) { id error } }
            """, ["id": userBookID, "r": rating.map { $0 as Any } ?? NSNull()])
            revision += 1
        } catch { lastError = error.localizedDescription }
    }

    func remove(userBookID: Int) async {
        do {
            try await query("mutation Remove($id: Int!) { delete_user_book(id: $id) { id } }", ["id": userBookID])
            revision += 1
        } catch { lastError = error.localizedDescription }
    }

    /// Records how many pages are read (user_book_reads.progress_pages), starting a read if needed.
    @discardableResult
    func setProgress(bookID: Int, pages: Int) async -> Bool {
        do {
            var ub = try await userBook(bookID: bookID)
            if ub == nil || ub?.status == .wantToRead || ub?.status == .paused {
                ub = await setStatus(bookID: bookID, status: .reading)
            }
            guard let ub else { return false }
            if let rid = ub.readID, ub.finishedAt == nil {
                try await query("""
                mutation Progress($id: Int!, $p: Int) { update_user_book_read(id: $id, object: {progress_pages: $p}) { id error } }
                """, ["id": rid, "p": pages])
            } else {
                try await query("""
                mutation StartRead($ub: Int!, $p: Int, $d: date) { insert_user_book_read(user_book_id: $ub, user_book_read: {progress_pages: $p, started_at: $d}) { id error } }
                """, ["ub": ub.id, "p": pages, "d": Date().isoDay])
            }
            revision += 1
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
