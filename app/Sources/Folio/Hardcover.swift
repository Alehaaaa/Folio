import Foundation
import Observation
import Security

// MARK: - Loose JSON (Hardcover returns jsonb columns whose shape varies)

enum JSON: Decodable, Hashable {
    case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])

    /// Plain Foundation values, for JSONSerialization.
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.anyValue)
        case .object(let o): return o.mapValues(\.anyValue)
        }
    }

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

struct HCBook: Identifiable, Hashable, Codable {
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
    /// Credited authors with their Hardcover ids, when the response carried them.
    var authorRefs: [HCAuthorRef] = []
    /// The edition a search found this work by ("El nombre del viento" for
    /// "The Name of the Wind"): its page shows that edition, the work's data stays shared.
    var editionID: Int? = nil
    var editionTitle: String? = nil

    var webURL: URL? {
        if id < 0 { return URL(string: "https://openlibrary.org/works/OL\(-id)W") }
        return slug.flatMap { URL(string: "https://hardcover.app/books/\($0)") }
    }

    static func from(book j: JSON) -> HCBook? {
        guard let id = j["id"].int else { return nil }
        var names: [String] = []
        var refs: [HCAuthorRef] = []
        for c in j["cached_contributors"].array + j["contributions"].array {
            guard let n = c["author"]["name"].string ?? c["name"].string, !names.contains(n) else { continue }
            // Translators, illustrators and editors are credited too; the byline is the authors.
            if let role = c["contribution"].string, !role.isEmpty, role.lowercased() != "author" { continue }
            names.append(n)
            refs.append(HCAuthorRef(id: c["author"]["id"].int ?? c["id"].int, name: n))
        }
        if names.isEmpty, let c = j["cached_contributors"].array.first, let n = c["author"]["name"].string {
            names.append(n)
            refs.append(HCAuthorRef(id: c["author"]["id"].int, name: n))
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
            slug: j["slug"].string,
            authorRefs: refs
        )
    }

    static func from(searchDocument d: JSON) -> HCBook? {
        guard let id = d["id"].int else { return nil }
        let authors = d["author_names"].array.compactMap(\.string)
        var refs: [HCAuthorRef] = []
        for c in d["contributions"].array {
            if let n = c["author"]["name"].string, authors.contains(n), !refs.contains(where: { $0.name == n }) {
                refs.append(HCAuthorRef(id: c["author"]["id"].int, name: n))
            }
        }
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
            slug: d["slug"].string,
            authorRefs: refs
        )
    }
}

struct HCAuthorRef: Hashable, Codable {
    var id: Int?
    var name: String
}

struct HCAuthor: Identifiable, Hashable, Codable {
    var id: Int
    var name: String
    var slug: String?
    var bio: String?
    var imageURL: URL?
    var bornYear: Int?
    var deathYear: Int?
    var booksCount: Int?
    var followers: Int?

    var webURL: URL? {
        if id < 0 { return URL(string: "https://openlibrary.org/authors/OL\(-id)A") }
        return slug.flatMap { URL(string: "https://hardcover.app/authors/\($0)") }
    }

    static func from(_ j: JSON) -> HCAuthor? {
        guard let id = j["id"].int, let name = j["name"].string else { return nil }
        let img = j["image"]["url"].string ?? j["cached_image"]["url"].string
        let bio = j["bio"].string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return HCAuthor(id: id, name: name, slug: j["slug"].string,
                        bio: bio?.isEmpty == false ? bio : nil,
                        imageURL: img.flatMap(URL.init(string:)),
                        bornYear: j["born_year"].int, deathYear: j["death_year"].int,
                        booksCount: j["books_count"].int, followers: j["users_count"].int)
    }
}

/// Community numbers for a book's ratings page.
struct HCBookStats: Hashable, Codable {
    var rating: Double?
    var ratingsCount: Int?
    var reviewsCount: Int?
    var readersCount: Int?
    var readCount: Int?
    var releaseDate: String?
    /// Share of ratings for 5, 4, 3, 2 and 1 stars (half stars round up), in that order.
    var distribution: [Int] = []
}

struct HCEdition: Hashable, Codable {
    var id: Int?
    var title: String?
    var imageURL: URL?
    var publisher: String?
    var releaseDate: String?
    var pages: Int?
    var isbn13: String?
    var isbn10: String?
    var format: String?
    var language: String?
    var editionsCount: Int?
}

struct HCReview: Identifiable, Hashable, Codable {
    var id: Int
    var rating: Double?
    var text: String
    var spoilers: Bool
    var date: String?
    var likes: Int
    var username: String?
    var userImage: URL?
}

/// A series a book belongs to, with the book's place in it.
struct HCBookSeries: Identifiable, Hashable, Codable {
    var id: Int
    var name: String
    var position: Double?
}

struct HCSeriesBook: Identifiable, Hashable, Codable {
    var position: Double?
    var book: HCBook
    var id: Int { book.id }
}

/// Everything the book page shows from Hardcover, fetched in one request.
struct HCBookPage: Codable {
    var book: HCBook?
    var userBook: HCUserBook?
    var stats: HCBookStats?
    var edition: HCEdition?
    var series: [HCBookSeries] = []
    /// Genres, most-tagged first (nil when the page didn't ask for them).
    var genres: [String]?
}

struct HCSeriesRef: Identifiable, Hashable, Codable {
    var id: Int
    var name: String
    var booksCount: Int?
    /// The author's books in this series, as far as the author page knows them.
    var bookIDs: [Int] = []
}

/// Everything the author page shows, from one request.
struct HCAuthorPage: Codable {
    var author: HCAuthor
    var books: [HCBook]
    var series: [HCSeriesRef]
}

struct HCUserBook: Identifiable, Hashable, Codable {
    var id: Int
    var status: HCStatus?
    var rating: Double?
    var book: HCBook
    var readID: Int?
    var progressPages: Int?
    var startedAt: String?
    var finishedAt: String?
    var dateAdded: String?
    /// The edition on the reader's shelf (e.g. a Spanish translation), if one was chosen.
    var editionID: Int? = nil
    var workTitle: String? = nil

    static func from(_ j: JSON) -> HCUserBook? {
        guard let id = j["id"].int, var book = HCBook.from(book: j["book"]) else { return nil }
        let read = j["user_book_reads"].array.first ?? .null
        // Show the edition being read: its title, cover and length, under the work's id.
        let workTitle = book.title
        let edition = j["edition"]
        if let title = edition["title"].string, !title.isEmpty { book.title = title }
        if let url = (edition["image"]["url"].string ?? edition["cached_image"]["url"].string).flatMap(URL.init(string:)) {
            book.imageURL = url
        }
        if let pages = edition["pages"].int, pages > 0 { book.pages = pages }
        return HCUserBook(
            id: id,
            status: j["status_id"].int.flatMap(HCStatus.init(rawValue:)),
            rating: j["rating"].double,
            book: book,
            readID: read["id"].int,
            progressPages: read["progress_pages"].int,
            startedAt: read["started_at"].string,
            finishedAt: read["finished_at"].string,
            dateAdded: j["date_added"].string,
            editionID: j["edition_id"].int,
            workTitle: workTitle
        )
    }
}

struct HCUser: Hashable, Codable {
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
    var rateLimited = false
    var retryableThrottle = false
    /// A server hiccup (5xx or a non-JSON page), not a problem with the account.
    var transient = false
    var errorDescription: String? { message }

    static func isRateLimit(_ error: Error) -> Bool { (error as? HCError)?.rateLimited == true }
}

/// Keeps requests under Hardcover's limits so pages wait a moment instead of failing.
///
/// Hardcover meters every top-level field of a query, not every HTTP request: a
/// book page asking for the book, its editions, series and your shelf entry costs
/// four. Free accounts get a bucket of 10 that refills at 60 a minute, plus 5,000 a
/// day. The gate mirrors that bucket with a safety margin, charges each query its
/// real cost, and follows the `RateLimit` headers Hardcover sends with every answer.
actor HCRateGate {
    static let shared = HCRateGate()

    private(set) var capacity: Double = 8
    private var refillPerSecond: Double = 0.9
    private var tokens: Double = 8
    private var refilled = Date()
    private var blockedUntil = Date.distantPast
    private var nextStart = Date.distantPast

    /// Waits up to this long for a short block (a drained bucket) instead of failing.
    static let patience: TimeInterval = 20

    /// The number of top-level fields in a GraphQL document: what Hardcover charges.
    nonisolated static func cost(of query: String) -> Int {
        var depth = 0, parens = 0, inString = false, escaped = false
        var count = 0
        var chars = Array(query.unicodeScalars)
        chars.append(" ")
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                i += 1; continue
            }
            switch c {
            case "\"": inString = true
            case "(": parens += 1
            case ")": parens -= 1
            case "{" where parens == 0: depth += 1
            case "}" where parens == 0: depth -= 1
            default:
                if depth == 1, parens == 0, c == "_" || CharacterSet.letters.contains(c) {
                    var j = i
                    var word = ""
                    while j < chars.count, chars[j] == "_" || CharacterSet.alphanumerics.contains(chars[j]) {
                        word.unicodeScalars.append(chars[j]); j += 1
                    }
                    var k = j
                    while k < chars.count, CharacterSet.whitespacesAndNewlines.contains(chars[k]) { k += 1 }
                    // `alias: field` names one field; introspection is free.
                    if !(k < chars.count && chars[k] == ":") && !word.hasPrefix("__") { count += 1 }
                    i = j; continue
                }
            }
            i += 1
        }
        return max(1, count)
    }

    private func refill(_ now: Date) {
        tokens = min(capacity, tokens + now.timeIntervalSince(refilled) * refillPerSecond)
        refilled = now
    }

    /// A 429 applies to the entire Hardcover account, not just one view.
    func noteRateLimit(retryAfter: String?) {
        let now = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        let value = retryAfter?.trimmingCharacters(in: .whitespacesAndNewlines)
        let seconds = value.flatMap(Double.init)
            ?? value.flatMap { dateFormatter.date(from: $0)?.timeIntervalSince(now) }
            ?? 20
        let delay = min(60 * 60 * 24, max(2, seconds.isFinite ? seconds : 20))
        blockedUntil = max(blockedUntil, Date().addingTimeInterval(delay))
        tokens = 0
        refilled = Date()
    }

    /// Follows Hardcover's own count, e.g. `RateLimit: "Free";r=8;t=0, "daily";r=4231;t=51234`
    /// and `RateLimit-Policy: "Free";q=60;w=60;burst=10, "daily";q=5000;w=86400`.
    func noteHeaders(rateLimit: String?, policy: String?) {
        let now = Date()
        refill(now)
        for entry in Self.entries(policy) where entry.name != "daily" {
            if let burst = entry.values["burst"], burst > 0 { capacity = max(1, burst - 2) }
            if let q = entry.values["q"], let w = entry.values["w"], q > 0, w > 0 { refillPerSecond = q / w * 0.9 }
        }
        let current = Self.entries(rateLimit)
        for entry in current {
            guard let remaining = entry.values["r"] else { continue }
            let reset = entry.values["t"] ?? 0
            if entry.name == "daily" {
                if remaining <= 0 { blockedUntil = max(blockedUntil, now.addingTimeInterval(max(60, reset))) }
            } else {
                tokens = min(tokens, max(0, remaining - 1))
            }
        }
    }

    private struct Entry { var name: String; var values: [String: Double] }

    private static func entries(_ header: String?) -> [Entry] {
        guard let header else { return [] }
        return header.split(separator: ",").map { part in
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            var values: [String: Double] = [:]
            for piece in pieces.dropFirst() {
                let kv = piece.split(separator: "=", maxSplits: 1)
                if kv.count == 2, let v = Double(kv[1]) { values[String(kv[0])] = v }
            }
            let name = (pieces.first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return Entry(name: name.lowercased(), values: values)
        }
    }

    func wait(cost: Int = 1) async throws {
        let need = min(Double(max(1, cost)), capacity)
        while true {
            try Task.checkCancellation()
            let now = Date()
            if now < blockedUntil {
                let left = blockedUntil.timeIntervalSince(now)
                guard left <= Self.patience else {
                    throw HCError(message: "Hardcover is rate-limiting requests. Retry shortly; cached book data remains available.", rateLimited: true)
                }
                try await Task.sleep(for: .seconds(left))
                continue
            }
            refill(now)
            if tokens >= need, now >= nextStart {
                tokens -= need
                nextStart = now.addingTimeInterval(0.35)
                return
            }
            try await Task.sleep(for: .seconds(max(0.05, nextStart.timeIntervalSince(now),
                                                     (need - tokens) / refillPerSecond)))
        }
    }
}

/// Prevents a status batch and a bulk import from editing the same account's
/// shelves at once. The rate gate meters tokens; this gate preserves write order.
actor HCStatusWriteGate {
    static let shared = HCStatusWriteGate()
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        if !occupied {
            occupied = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func leave() {
        if waiters.isEmpty {
            occupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
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
    /// Bumped when only reading progress changes, so the reading shelf refreshes
    /// without reloading recommendations and every other shelf.
    var progressRevision = 0

    private struct ReadKey: Hashable {
        let token: String
        let body: Data
        let generation: Int
    }
    private var readGeneration = 0
    private var activeReads: [ReadKey: Task<JSON, Error>] = [:]
    private struct EditionKey: Hashable {
        let work: Int
        let language: String
    }
    private var editionRows: [EditionKey: (rows: [JSON], expires: Date)] = [:]
    private var editionRequests: [EditionKey: Task<[Int: [JSON]], Error>] = [:]
    private var editionLanguageNames: [String: [String]]?
    private var editionLanguageLookup: Task<[String: [String]], Error>?
    private var token: String?
    private let endpoint = URL(string: "https://api.hardcover.app/v1/graphql")!
    /// Rapid shelf taps and bulk calls are coalesced by book and sent together.
    /// Hardcover charges GraphQL top-level fields, so batches remain small.
    private struct StatusRequest {
        var status: HCStatus
        var editionID: Int?
        var completions: [CheckedContinuation<HCUserBook?, Never>]
    }
    private var pendingStatuses: [Int: StatusRequest] = [:]
    private var statusFlushTask: Task<Void, Never>?

    var isConnected: Bool { user != nil }
    var hasToken: Bool { token != nil }

    private init() {
        // Isolated screenshot builds should never request access to a person's
        // production keychain item (which can block launch behind a prompt).
        token = ProcessInfo.processInfo.environment["FOLIO_PREVIEW_NO_KEYCHAIN"] == "1"
            ? nil : Keychain.read()
        // Start signed in as the last known account, so cached shelves and pages
        // show at launch instead of waiting for the account check.
        if token != nil, let data = UserDefaults.standard.data(forKey: Self.userDefaultsKey) {
            user = try? JSONDecoder().decode(HCUser.self, from: data)
        }
    }

    private static let userDefaultsKey = "folio.hardcover.user"

    private var verified = false

    func restore() async {
        guard token != nil, !verified, !connecting else { return }
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
        UserDefaults.standard.removeObject(forKey: Self.userDefaultsKey)
        verified = false
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
            let fresh = HCUser(id: id, username: me["username"].string ?? "reader", name: me["name"].string,
                               imageURL: me["image"]["url"].string.flatMap(URL.init(string:)))
            let changed = fresh != user
            user = fresh
            verified = true
            if let data = try? JSONEncoder().encode(fresh) { UserDefaults.standard.set(data, forKey: Self.userDefaultsKey) }
            lastError = nil
            // The cached account already loaded everything; only reload for a different one.
            if changed { revision += 1 }
            LibraryStore.shared.enqueueUnlinkedEPUBs()
        } catch is URLError {
            // Offline or slow network: keep the last known account and its cached data.
            lastError = nil
        } catch let e as HCError where e.rateLimited || e.transient {
            // Hardcover is busy or down: stay signed in and check again next launch.
            lastError = nil
        } catch {
            user = nil
            UserDefaults.standard.removeObject(forKey: Self.userDefaultsKey)
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func query(_ q: String, _ variables: [String: Any] = [:]) async throws -> JSON {
        try Task.checkCancellation()
        guard let token else { throw HCError(message: "Connect your Hardcover account in Settings first.") }
        let body = try JSONSerialization.data(withJSONObject: ["query": q, "variables": variables], options: .sortedKeys)
        let operation = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard operation.hasPrefix("query ") || operation.hasPrefix("{") else {
            readGeneration &+= 1
            defer { readGeneration &+= 1 }
            return try await request(q, body: body, token: token)
        }

        let key = ReadKey(token: token, body: body, generation: readGeneration)
        if let pending = activeReads[key] {
            let result = try await pending.value
            try Task.checkCancellation()
            return result
        }
        let pending = Task { try await request(q, body: body, token: token) }
        activeReads[key] = pending
        defer { activeReads[key] = nil }
        let result = try await pending.value
        try Task.checkCancellation()
        return result
    }

    private func request(_ q: String, body: Data, token: String) async throws -> JSON {
        do {
            return try await send(q, body: body, token: token)
        } catch let error as HCError where error.retryableThrottle {
            return try await send(q, body: body, token: token)
        }
    }

    private func send(_ q: String, body: Data, token: String) async throws -> JSON {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("Folio/1.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = body
        let queued = Date()
        try await HCRateGate.shared.wait(cost: HCRateGate.cost(of: q))
        guard self.token == token else { throw CancellationError() }
        let sent = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        let head = String(decoding: data.prefix(300), as: UTF8.self)
        let throttled = http?.statusCode == 429 ||
            (http?.statusCode == 200 && head.localizedCaseInsensitiveContains("too many requests")
                && head.contains("\"errors\""))
        if throttled {
            await HCRateGate.shared.noteRateLimit(retryAfter: http?.value(forHTTPHeaderField: "Retry-After"))
        }
        await HCRateGate.shared.noteHeaders(rateLimit: http?.value(forHTTPHeaderField: "RateLimit"),
                                            policy: http?.value(forHTTPHeaderField: "RateLimit-Policy"))
        #if os(iOS)
        Self.logTiming(q, status: http?.statusCode, waited: sent.timeIntervalSince(queued),
                       took: Date().timeIntervalSince(sent), bytes: data.count)
        #endif
        if throttled {
            let read = q.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("query")
            throw HCError(message: "Hardcover is busy right now. Try again shortly.", rateLimited: true,
                          retryableThrottle: read || http?.statusCode == 429)
        }
        if let http, http.statusCode >= 500 {
            throw HCError(message: "Hardcover is having trouble right now. Try again in a minute.", transient: true)
        }
        guard let json = try? JSONDecoder().decode(JSON.self, from: data) else {
            throw HCError(message: "Hardcover sent an unexpected answer. Try again in a minute.", transient: true)
        }
        if let msg = json["errors"].array.first?["message"].string { throw HCError(message: msg) }
        if let msg = json["error"].string ?? json["message"].string { throw HCError(message: msg) }
        if let http, http.statusCode >= 400 {
            throw HCError(message: "Hardcover answered with error \(http.statusCode).")
        }
        return json["data"]
    }

    #if os(iOS)
    /// Logs requests that were slow, waited on the rate limit or failed, by operation name.
    private static func logTiming(_ query: String, status: Int?, waited: TimeInterval, took: TimeInterval, bytes: Int) {
        let ok = (200..<300).contains(status ?? 0)
        guard !ok || took > 1.5 || waited > 1 else { return }
        let words = query.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" }).prefix(2)
        let name = words.joined(separator: " ")
        func seconds(_ t: TimeInterval) -> String { t.formatted(.number.precision(.fractionLength(1))) + " s" }
        FolioLog.log("\(name): HTTP \(status.map(String.init) ?? "?") in \(seconds(took)) after \(seconds(waited)) "
                     + "waiting for the rate limit, \(bytes / 1024) KB", "hardcover")
    }
    #endif

    static let bookFields = "id title slug pages release_year rating ratings_count description cached_contributors image { url }"
    static let userBookFields = "id status_id rating date_added edition_id edition { title pages image { url } } book { \(bookFields) } user_book_reads(order_by: {id: desc}, limit: 1) { id progress_pages started_at finished_at }"

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

    /// Read-history pages for recommendation filtering, including older finishes.
    func readHistory() async throws -> [HCUserBook] {
        guard let user else { throw HCError(message: "Not connected.") }
        var cursor = 0
        var history: [HCUserBook] = []
        while true {
            try Task.checkCancellation()
            let data = try await query("""
            query ReadHistory($uid: Int!, $status: Int!, $after: Int!) {
              user_books(where: {user_id: {_eq: $uid}, status_id: {_eq: $status}, id: {_gt: $after}}, order_by: {id: asc}, limit: 200) {
                \(Self.userBookFields)
              }
            }
            """, ["uid": user.id, "status": HCStatus.read.rawValue, "after": cursor])
            let rows = data["user_books"].array
            history.append(contentsOf: rows.compactMap(HCUserBook.from))
            guard rows.count == 200, let next = rows.last?["id"].int, next > cursor else { return history }
            cursor = next
        }
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

    /// Book search that also finds translations: "El nombre del viento" finds
    /// "The Name of the Wind". Hardcover's index carries every edition title
    /// (alternative_titles), so those are weighted like the main title, and
    /// editions published under exactly the typed title are asked for in the
    /// same request. A book found through an edition shows that edition's title.
    func search(_ text: String) async throws -> [HCBook] {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return [] }
        var docs: [JSON]
        var editionRows: [JSON] = []
        do {
            let d = try await query("""
            query SearchAll($q: String!, $titles: [String!]) {
              search(query: $q, query_type: "Book", per_page: 30, page: 1, fields: "title,alternative_titles,series_names,author_names,isbns", weights: "5,5,2,1,1") { results }
              editions(where: {title: {_in: $titles}, book: {users_count: {_gt: 0}}}, order_by: {users_count: desc}, limit: 15) { id title image { url } book { users_count \(Self.bookFields) } }
            }
            """, ["q": typed, "titles": Self.titleSpellings(typed)])
            docs = Self.hits(d["search"]["results"])
            editionRows = d["editions"].array
        } catch let error as HCError where error.rateLimited || error.transient {
            throw error
        } catch {
            // Older or stricter schemas: the plain search alone.
            docs = try await searchDocuments(typed)
        }
        return Self.rank(query: typed, docs: docs, editions: editionRows)
    }

    /// The typed title as an edition would likely be catalogued: as typed,
    /// sentence case ("El nombre del viento") and title case.
    static func titleSpellings(_ text: String) -> [String] {
        let typed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let sentence = typed.prefix(1).uppercased() + String(typed.dropFirst())
        let lowerSentence = typed.prefix(1).uppercased() + String(typed.dropFirst()).lowercased()
        let titled = typed.lowercased().capitalized
        var out: [String] = []
        for t in [typed, sentence, lowerSentence, titled] where !out.contains(t) { out.append(t) }
        return out
    }

    private static func hits(_ raw: JSON) -> [JSON] {
        var results = raw
        if case .string(let s) = results, let data = s.data(using: .utf8), let j = try? JSONDecoder().decode(JSON.self, from: data) { results = j }
        return results["hits"].array.map { $0["document"] }
    }

    /// Puts exact title matches first, in any language, and names each book by
    /// the title the reader typed when that is one of its edition titles.
    static func rank(query: String, docs: [JSON], editions: [JSON]) -> [HCBook] {
        let typed = BookAutoMatch.words(query)
        // 0: same title, 1: every typed title word is in the title, 2: anything else.
        func match(_ title: String, authors: String) -> Int {
            let words = BookAutoMatch.words(title)
            guard !words.isEmpty else { return 2 }
            let authorWords = Set(BookAutoMatch.words(authors))
            // "nombre del viento rothfuss": the author's name is not part of the title.
            var wanted = typed.filter { !authorWords.contains($0) || words.contains($0) }
            if wanted.isEmpty { wanted = typed }
            if words == wanted { return 0 }
            let all = Set(words)
            let last = wanted.last ?? ""
            let covered = wanted.dropLast().allSatisfy(all.contains) && (all.contains(last) || words.contains { $0.hasPrefix(last) })
            return covered ? 1 : 2
        }
        var ranked: [(score: Int, readers: Int, book: HCBook)] = []
        var index: [Int: Int] = [:]
        func add(_ book: HCBook, score: Int, readers: Int) {
            if let i = index[book.id] {
                if score < ranked[i].score { ranked[i] = (score, max(readers, ranked[i].readers), book) }
                return
            }
            index[book.id] = ranked.count
            ranked.append((score, readers, book))
        }
        func readers(_ j: JSON) -> Int { j["users_count"].int ?? j["ratings_count"].int ?? 0 }
        for doc in docs {
            guard var book = HCBook.from(searchDocument: doc) else { continue }
            var score = match(book.title, authors: book.authors)
            if score > 0 {
                for alt in doc["alternative_titles"].array.compactMap(\.string) {
                    let s = match(alt, authors: book.authors)
                    if s < score { score = s; book.title = alt; book.editionTitle = alt }
                    if s == 0 { break }
                }
            }
            add(book, score: score, readers: readers(doc))
        }
        for row in editions {
            guard var book = HCBook.from(book: row["book"]), let title = row["title"].string else { continue }
            if !BookAutoMatch.sameTitle(book.title, title) {
                book.title = title
                book.editionTitle = title
                book.editionID = row["id"].int
                if let cover = row["image"]["url"].string.flatMap(URL.init(string:)) { book.imageURL = cover }
            }
            add(book, score: 0, readers: readers(row["book"]))
        }
        // Hardcover keeps some translations as books of their own, often unread and
        // without the author ("Amanecer rojo" next to "Red Rising"). When the real work
        // is found under the same title, the copy is left out: the work's page shows
        // that edition anyway, with its ratings, series and shelves.
        func sharesAuthor(_ a: HCBook, _ b: HCBook) -> Bool {
            let names = b.authors.components(separatedBy: ", ")
            return a.authors.components(separatedBy: ", ").contains { name in names.contains { BookAutoMatch.sameAuthor(name, $0) } }
        }
        let kept = ranked.filter { entry in
            guard entry.score < 2 else { return true }
            let key = BookAutoMatch.words(entry.book.title)
            return !ranked.contains { other in
                other.book.id != entry.book.id && other.score <= entry.score
                    && BookAutoMatch.words(other.book.title) == key
                    && other.readers >= max(10, entry.readers * 5)
                    && (entry.book.authors.isEmpty || sharesAuthor(entry.book, other.book))
            }
        }
        // Matches first; among them the most-read work. Otherwise Hardcover's own order.
        return kept.enumerated().sorted { a, b in
            if a.element.score != b.element.score { return a.element.score < b.element.score }
            if a.element.score < 2, a.element.readers != b.element.readers { return a.element.readers > b.element.readers }
            return a.offset < b.offset
        }.map(\.element.book)
    }

    /// Raw search documents, which also carry every edition title (alternative_titles).
    func searchDocuments(_ text: String) async throws -> [JSON] {
        let d = try await query("""
        query Search($q: String!) { search(query: $q, query_type: "Book", per_page: 30, page: 1) { results } }
        """, ["q": text])
        return Self.hits(d["search"]["results"])
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
            // Hardcover can repeat an id in the trending list, so keep the first of each.
            var seen = Set<Int>()
            let ids = d["books_trending"]["ids"].array.compactMap(\.int).filter { seen.insert($0).inserted }
            if !ids.isEmpty {
                let b = try await query("query Books($ids: [Int!]) { books(where: {id: {_in: $ids}}) { \(Self.bookFields) } }", ["ids": ids])
                let books = b["books"].array.compactMap(HCBook.from(book:))
                let order = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
                return books.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
            }
        }
        let d = try await query("query Popular { books(order_by: {users_count: desc}, limit: 30) { \(Self.bookFields) } }")
        return d["books"].array.compactMap(HCBook.from(book:))
    }

    // MARK: Authors, ratings, editions

    static let authorFields = "id name slug bio born_year death_year books_count users_count image { url }"

    func author(id: Int) async throws -> HCAuthor? {
        let d = try await query("query Author($id: Int!) { authors(where: {id: {_eq: $id}}, limit: 1) { \(Self.authorFields) } }", ["id": id])
        return d["authors"].array.first.flatMap(HCAuthor.from)
    }

    /// The best-known author with exactly this name (local books only carry a name).
    func author(named name: String) async throws -> HCAuthor? {
        let d = try await query("""
        query AuthorByName($n: String!) { authors(where: {name: {_eq: $n}}, order_by: {users_count: desc}, limit: 1) { \(Self.authorFields) } }
        """, ["n": name])
        return d["authors"].array.first.flatMap(HCAuthor.from)
    }

    /// The author, their books and their series. These are the same separate queries the
    /// page has always used (a single nested query proved unreliable on Hardcover); the page
    /// caches the result, so each author costs these requests at most twice a day.
    func authorPage(id: Int?, name: String) async throws -> HCAuthorPage? {
        // With an id, the author and their books load side by side.
        if let id {
            async let fetchedAuthor = author(id: id)
            async let fetchedBooks = authorBooks(id: id)
            if let found = try await fetchedAuthor {
                let books = try await fetchedBooks
                let series = (try? await self.series(forBooks: books.prefix(80).map(\.id))) ?? []
                return HCAuthorPage(author: found, books: books, series: series)
            }
        }
        guard let found = try await author(named: name) else { return nil }
        let books = try await authorBooks(id: found.id)
        let series = (try? await self.series(forBooks: books.prefix(80).map(\.id))) ?? []
        return HCAuthorPage(author: found, books: books, series: series)
    }

    /// Several authors by name in one request, the best-known match for each name.
    func authors(named names: [String]) async throws -> [String: HCAuthor] {
        guard !names.isEmpty else { return [:] }
        let d = try await query("""
        query AuthorsByName($n: [String!]) { authors(where: {name: {_in: $n}}, order_by: {users_count: desc}, limit: \(names.count * 4)) { \(Self.authorFields) } }
        """, ["n": names])
        var out: [String: HCAuthor] = [:]
        for row in d["authors"].array {
            guard let author = HCAuthor.from(row), out[author.name] == nil else { continue }
            out[author.name] = author
        }
        return out
    }

    /// An author's books, most-read first, one entry per title.
    func authorBooks(id: Int) async throws -> [HCBook] {
        var rows: [JSON]
        if let d = try? await query("""
        query AuthorBooks($id: Int!) { contributions(where: {author_id: {_eq: $id}, contributable_type: {_eq: "Book"}}, order_by: {book: {users_count: desc}}, limit: 120) { contribution book { users_count compilation \(Self.bookFields) } } }
        """, ["id": id]) {
            rows = d["contributions"].array
        } else {
            let d = try await query("""
            query AuthorBooksPlain($id: Int!) { contributions(where: {author_id: {_eq: $id}}, limit: 120) { book { \(Self.bookFields) } } }
            """, ["id": id])
            rows = d["contributions"].array
        }
        return Self.authorBookList(rows)
    }

    /// One entry per title: no compilations, other roles, translations or split editions.
    static func authorBookList(_ input: [JSON]) -> [HCBook] {
        let rows = input.filter { r in
            let role = r["contribution"].string?.lowercased() ?? ""
            return (role.isEmpty || role == "author") && r["book"]["compilation"] != .bool(true)
        }
        let top = rows.compactMap { $0["book"]["users_count"].int }.max() ?? 0
        var titles = Set<String>()
        var out: [HCBook] = []
        for r in rows {
            guard let b = HCBook.from(book: r["book"]) else { continue }
            // Translations and split editions are separate records with few readers.
            if top > 50, (r["book"]["users_count"].int ?? 0) < max(3, top / 200) { continue }
            let key = b.title.lowercased().folding(options: .diacriticInsensitive, locale: nil)
                .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
            guard titles.insert(key).inserted else { continue }
            out.append(b)
        }
        return out
    }

    /// Each book's main series and its number in it, for many books in one request.
    func seriesPlacement(forBooks ids: [Int]) async throws -> [Int: (name: String, position: Double?)] {
        guard !ids.isEmpty else { return [:] }
        let d = try await query("""
        query LibrarySeries($ids: [Int!]) { book_series(where: {book_id: {_in: $ids}}) { book_id position series { name } } }
        """, ["ids": ids])
        var out: [Int: (name: String, position: Double?)] = [:]
        for r in d["book_series"].array {
            guard let id = r["book_id"].int, let name = r["series"]["name"].string, !name.isEmpty else { continue }
            let position = r["position"].double
            // A numbered place wins over a loose membership (omnibuses, companion lists).
            if let current = out[id], current.position != nil || position == nil { continue }
            out[id] = (name, position)
        }
        return out
    }

    /// The series a set of books belongs to, most represented first.
    func series(forBooks ids: [Int]) async throws -> [HCSeriesRef] {
        guard !ids.isEmpty else { return [] }
        let d: JSON
        if let rich = try? await query("""
        query AuthorSeries($ids: [Int!]) { book_series(where: {book_id: {_in: $ids}}) { book_id series { id name books_count primary_books_count } } }
        """, ["ids": ids]) {
            d = rich
        } else {
            d = try await query("""
            query AuthorSeriesPlain($ids: [Int!]) { book_series(where: {book_id: {_in: $ids}}) { book_id series { id name } } }
            """, ["ids": ids])
        }
        return Self.seriesRefs(d["book_series"].array.map { (bookID: $0["book_id"].int, series: $0["series"]) })
    }

    /// Group book_series rows into series, merging differently named copies of one series.
    static func seriesRefs(_ rows: [(bookID: Int?, series: JSON)]) -> [HCSeriesRef] {
        var out: [HCSeriesRef] = []
        for r in rows {
            guard let sid = r.series["id"].int, let name = r.series["name"].string else { continue }
            let bookID = r.bookID
            // Main books only: books_count also counts companions, prequels and other editions.
            let count = r.series["primary_books_count"].int.flatMap { $0 > 0 ? $0 : nil } ?? r.series["books_count"].int
            let key = Self.seriesKey(name)
            if let i = out.firstIndex(where: { $0.id == sid || Self.seriesKey($0.name) == key }) {
                if let bookID, !out[i].bookIDs.contains(bookID) { out[i].bookIDs.append(bookID) }
                if name.count > out[i].name.count, out[i].id != sid {
                    out[i].name = name
                    out[i].id = sid
                    out[i].booksCount = count
                }
            } else {
                out.append(HCSeriesRef(id: sid, name: name, booksCount: count,
                                       bookIDs: bookID.map { [$0] } ?? []))
            }
        }
        return out.sorted { $0.bookIDs.count > $1.bookIDs.count }
    }

    func stats(bookID: Int, distribution: Bool = true) async throws -> HCBookStats {
        let d = try await query("""
        query BookStats($id: Int!) { books(where: {id: {_eq: $id}}, limit: 1) { rating ratings_count reviews_count users_count users_read_count release_date } }
        """, ["id": bookID])
        let b = d["books"].array.first ?? .null
        var stats = HCBookStats(rating: b["rating"].double, ratingsCount: b["ratings_count"].int,
                                reviewsCount: b["reviews_count"].int, readersCount: b["users_count"].int,
                                readCount: b["users_read_count"].int, releaseDate: b["release_date"].string)
        if distribution { stats.distribution = await ratingDistribution(bookID: bookID) }
        return stats
    }

    /// Counts per star (5 to 1). Uses Hardcover's stored distribution when it is
    /// available, otherwise tallies a sample of up to 1,000 public ratings.
    func ratingDistribution(bookID: Int) async -> [Int] {
        var buckets = [0, 0, 0, 0, 0]
        func add(_ rating: Double, _ count: Int) {
            guard rating > 0 else { return }
            let star = min(5, max(1, Int(rating.rounded(.up))))
            buckets[5 - star] += count
        }
        if let d = try? await query("query Dist($id: Int!) { books(where: {id: {_eq: $id}}, limit: 1) { ratings_distribution } }", ["id": bookID]) {
            let dist = d["books"].array.first?["ratings_distribution"] ?? .null
            switch dist {
            case .array(let rows):
                for r in rows { if let rating = r["rating"].double, let n = r["count"].int { add(rating, n) } }
            case .object(let map):
                for (k, v) in map { if let rating = Double(k), let n = v.int { add(rating, n) } }
            default: break
            }
            if buckets.reduce(0, +) > 0 { return buckets }
        }
        if let d = try? await query("""
        query Ratings($id: Int!) { user_books(where: {book_id: {_eq: $id}, rating: {_is_null: false}}, limit: 1000) { rating } }
        """, ["id": bookID]) {
            for r in d["user_books"].array { if let rating = r["rating"].double { add(rating, 1) } }
        }
        return buckets.reduce(0, +) > 0 ? buckets : []
    }

    /// The most-read edition, for publishing details.
    func edition(bookID: Int) async throws -> HCEdition? {
        let d = try await query("""
        query Edition($id: Int!) { editions(where: {book_id: {_eq: $id}}, order_by: {users_count: desc}, limit: 1) { release_date pages isbn_10 isbn_13 edition_format physical_format publisher { name } language { language } } }
        """, ["id": bookID])
        return d["editions"].array.first.map(Self.edition(from:))
    }

    static let editionFields = "id title image { url } release_date pages isbn_10 isbn_13 edition_format physical_format publisher { name } language { language }"

    static func edition(from e: JSON) -> HCEdition {
        let format = [e["edition_format"].string, e["physical_format"].string]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return HCEdition(id: e["id"].int, title: e["title"].string,
                         imageURL: (e["image"]["url"].string ?? e["cached_image"]["url"].string).flatMap(URL.init(string:)),
                         publisher: e["publisher"]["name"].string, releaseDate: e["release_date"].string,
                         pages: e["pages"].int, isbn13: e["isbn_13"].string, isbn10: e["isbn_10"].string,
                         format: format, language: e["language"]["language"].string)
    }

    /// The most-read edition of a book in a language ("es"), preferring one whose
    /// title matches the file's.
    func edition(bookID: Int, language code: String, title: String? = nil) async throws -> HCEdition? {
        guard let wanted = BookLanguage.code(code) else { return nil }
        let books = try await languageEditionRows(bookIDs: [bookID], language: wanted)
        let editions = (books[bookID] ?? []).map(Self.edition(from:))
        let picked = title.flatMap { title in
            editions.first { BookAutoMatch.sameTitle(title, $0.title ?? "") }
                ?? editions.first { EditionTitle.isCatalogueMatch(title, $0.title ?? "") }
        } ?? editions.first
        return picked.map { Self.bestTitled($0, among: editions) }
    }

    /// The edition shown under the best-formed real title its book has in the
    /// same language: "El camino de los reyes" rather than "CAMINO DE LOS REYES
    /// (EL ARCHIVO DE LAS TORMENTAS 1)". Titles are picked, never rewritten.
    static func bestTitled(_ edition: HCEdition, among editions: [HCEdition]) -> HCEdition {
        guard let title = edition.title, !title.isEmpty else { return edition }
        let code = BookLanguage.code(edition.language)
        let siblings = editions.filter { $0.id != edition.id && BookLanguage.code($0.language) == code }
            .compactMap(\.title)
        var out = edition
        out.title = EditionTitle.best(title, among: siblings)
        return out
    }

    /// Every edition title these books have in one language, most-read first,
    /// so lists can show a book's best-formed real title without opening it.
    /// Books with no edition in that language map to an empty list.
    func editionTitles(bookIDs: [Int], language code: String) async throws -> [Int: [String]] {
        guard let wanted = BookLanguage.code(code), !bookIDs.isEmpty else { return [:] }
        let rows = try await languageEditionRows(bookIDs: bookIDs, language: wanted)
        return rows.mapValues { editions in
            var seen = Set<String>()
            return editions.compactMap { edition in
                guard let title = edition["title"].string, !title.isEmpty, seen.insert(title).inserted else { return nil }
                return title
            }
        }
    }

    private func languageEditionRows(bookIDs: [Int], language: String) async throws -> [Int: [JSON]] {
        let now = Date()
        let keys = Set(bookIDs).sorted().map { EditionKey(work: $0, language: language) }
        var result: [Int: [JSON]] = [:]
        for key in keys {
            if let cached = editionRows[key], cached.expires > now { result[key.work] = cached.rows }
        }
        let missing = keys.filter { result[$0.work] == nil && editionRequests[$0] == nil }
        if !missing.isEmpty {
            let batch = Task {
                defer { for key in missing { editionRequests[key] = nil } }
                let rows = try await fetchLanguageEditionRows(bookIDs: missing.map(\.work), language: language)
                let fetched = Date()
                editionRows = editionRows.filter { $0.value.expires > fetched }
                for key in missing {
                    let editions = rows[key.work] ?? []
                    editionRows[key] = (editions, fetched.addingTimeInterval(editions.isEmpty ? 300 : 1_800))
                }
                return rows
            }
            for key in missing { editionRequests[key] = batch }
        }
        let pending = keys.compactMap { key in editionRequests[key].map { (key, $0) } }
        for (key, task) in pending {
            result[key.work] = try await task.value[key.work] ?? []
        }
        try Task.checkCancellation()
        return result
    }

    private func fetchLanguageEditionRows(bookIDs: [Int], language: String) async throws -> [Int: [JSON]] {
        let names = try await catalogueLanguageNames()[language] ?? []
        guard !names.isEmpty else { return [:] }
        // Filter before applying the limit, separately for each work.
        let data = try await query("""
        query EditionTitles($ids: [Int!]!, $names: [String!]!) {
            books(where: {id: {_in: $ids}}) {
                id
                editions(where: {language: {language: {_in: $names}}}, order_by: [{users_count: desc}, {id: asc}], limit: 100) {
                    \(Self.editionFields)
                }
            }
        }
        """, ["ids": bookIDs, "names": names])
        var out: [Int: [JSON]] = [:]
        for book in data["books"].array {
            if let id = book["id"].int { out[id] = book["editions"].array }
        }
        return out
    }

    private func catalogueLanguageNames() async throws -> [String: [String]] {
        if let editionLanguageNames { return editionLanguageNames }
        if let editionLanguageLookup { return try await editionLanguageLookup.value }
        let lookup = Task {
            let data = try await query("query EditionCatalogueLanguages { languages { language } }")
            var names: [String: [String]] = [:]
            for row in data["languages"].array {
                if let name = row["language"].string, let code = BookLanguage.code(name) {
                    names[code, default: []].append(name)
                }
            }
            return names
        }
        editionLanguageLookup = lookup
        defer { editionLanguageLookup = nil }
        let names = try await lookup.value
        if !names.isEmpty { editionLanguageNames = names }
        return names
    }

    /// The languages a book has editions in, most-read first, each with the
    /// title its most-read edition in that language carries.
    func editionLanguages(bookID: Int) async throws -> [(code: String, title: String?)] {
        let d = try await query("""
        query EditionLanguages($id: Int!) { editions(where: {book_id: {_eq: $id}}, order_by: {users_count: desc}, limit: 120) { title language { language } } }
        """, ["id": bookID])
        var seen = Set<String>()
        var result: [(code: String, title: String?)] = []
        for e in d["editions"].array {
            guard let code = BookLanguage.code(e["language"]["language"].string), seen.insert(code).inserted else { continue }
            result.append((code, e["title"].string))
        }
        return result
    }

    func edition(id: Int) async throws -> HCEdition? {
        let d = try await query("query EditionByID($id: Int!) { editions(where: {id: {_eq: $id}}, limit: 1) { \(Self.editionFields) } }", ["id": id])
        return d["editions"].array.first.map(Self.edition(from:))
    }

    /// Finds the work behind a translated file ("Amanecer rojo" is "Red Rising"):
    /// Hardcover's search knows every edition title, then the series place, then
    /// an edition with exactly that title. The author must always match.
    func translatedBook(title: String, author: String, series: String?, seriesIndex: Double?) async -> HCBook? {
        func authorMatches(_ names: [String]) -> Bool {
            names.contains { BookAutoMatch.sameAuthor(author, $0) } || BookAutoMatch.sameAuthor(author, names.joined(separator: ", "))
        }
        // 1. Search, accepting the work when the file's title is one of its edition titles.
        if let docs = try? await searchDocuments("\(title) \(author)") {
            for doc in docs {
                let names = doc["author_names"].array.compactMap(\.string)
                guard authorMatches(names) else { continue }
                let titles = [doc["title"].string].compactMap { $0 } + doc["alternative_titles"].array.compactMap(\.string)
                if titles.contains(where: { BookAutoMatch.sameTitle(title, $0) }) { return HCBook.from(searchDocument: doc) }
            }
        }
        // 2. The same place in the same series by the same author.
        if let series, let seriesIndex, let sid = try? await seriesID(named: series),
           let entries = try? await seriesBooks(sid),
           let entry = entries.first(where: { $0.position == seriesIndex && authorMatches([$0.book.authors]) }) {
            return entry.book
        }
        // 3. An edition published under exactly this title.
        if let d = try? await query("""
        query EditionTitle($t: String!) { editions(where: {title: {_eq: $t}}, order_by: {users_count: desc}, limit: 10) { book { \(Self.bookFields) } } }
        """, ["t": title]) {
            for row in d["editions"].array {
                if let book = HCBook.from(book: row["book"]), authorMatches(book.authors.components(separatedBy: ", ")) { return book }
            }
        }
        return nil
    }

    /// The book, your shelf entry, community numbers, main edition and series
    /// in a single request (Hardcover rate-limits per request). Falls back to
    /// separate requests if the combined one is refused.
    func bookPage(id: Int, editionID: Int? = nil, language: String? = nil, editionTitle: String? = nil) async throws -> HCBookPage {
        let uid = user?.id ?? -1
        // A library file in another language shows its own edition's details; other books
        // show the reader's language edition when Hardcover has one, else the most-read.
        let mostRead = "editions(where: {book_id: {_eq: $id}}, order_by: {users_count: desc}, limit: 1)"
        var editions = editionID.map { "editions(where: {id: {_eq: \($0)}}, limit: 1)" } ?? mostRead
        // Hardcover refuses text-pattern filters (HTTP 403), so the language
        // edition is picked here from the book's most-read editions.
        var pickLanguage: String?
        if editionID == nil, let language, language != "en", let code = BookLanguage.code(language) {
            editions = "editions(where: {book_id: {_eq: $id}}, order_by: {users_count: desc}, limit: 60)"
            pickLanguage = code
        }
        // Opened from a search for an edition title: that edition, else the usual one.
        var variables: [String: Any] = ["id": id, "uid": uid]
        var titleVariable = ""
        if editionID == nil, let editionTitle, !editionTitle.isEmpty {
            editions = "editions(where: {book_id: {_eq: $id}, title: {_eq: $etitle}}, order_by: {users_count: desc}, limit: 1) { \(Self.editionFields) } fallbackEdition: \(mostRead)"
            variables["etitle"] = editionTitle
            titleVariable = ", $etitle: String!"
        }
        do {
            let d = try await query("""
            query BookPage($id: Int!, $uid: Int!\(titleVariable)) {
              books(where: {id: {_eq: $id}}, limit: 1) { \(Self.bookFields) reviews_count users_count users_read_count release_date cached_tags }
              \(editions) { \(Self.editionFields) }
              siblingEditions: editions(where: {book_id: {_eq: $id}}, order_by: {users_count: desc}, limit: 60) { id title language { language } }
              book_series(where: {book_id: {_eq: $id}}) { position series { id name } }
              user_books(where: {user_id: {_eq: $uid}, book_id: {_eq: $id}}, limit: 1) { \(Self.userBookFields) }
            }
            """, variables)
            let b = d["books"].array.first ?? .null
            return HCBookPage(
                book: HCBook.from(book: b),
                userBook: d["user_books"].array.first.flatMap(HCUserBook.from),
                stats: HCBookStats(rating: b["rating"].double, ratingsCount: b["ratings_count"].int,
                                   reviewsCount: b["reviews_count"].int, readersCount: b["users_count"].int,
                                   readCount: b["users_read_count"].int, releaseDate: b["release_date"].string),
                edition: (pickLanguage.flatMap { code in
                    d["editions"].array.first { BookLanguage.code($0["language"]["language"].string) == code }
                } ?? d["editions"].array.first ?? d["fallbackEdition"].array.first).map { chosen in
                    Self.bestTitled(Self.edition(from: chosen), among: d["siblingEditions"].array.map(Self.edition(from:)))
                },
                series: Self.dedupeSeries(d["book_series"].array),
                genres: Self.genreNames(b["cached_tags"])
            )
        } catch let error as HCError where error.message.contains("not found in type") || error.message.contains("field") {
            // A field this request relies on is missing from the schema: fetch piece by piece.
            _ = error
            var page = HCBookPage()
            page.book = try await book(id: id)
            page.userBook = try? await userBook(bookID: id)
            page.stats = try? await stats(bookID: id, distribution: false)
            if let editionID { page.edition = try? await edition(id: editionID) } else { page.edition = try? await edition(bookID: id) }
            page.series = ((try? await series(forBook: id)) ?? []).map { HCBookSeries(id: $0.id, name: $0.name, position: $0.position) }
            return page
        }
    }

    /// The book's genres, most-tagged first.
    func genres(bookID: Int) async throws -> [String] {
        let d = try await query("query Tags($id: Int!) { books(where: {id: {_eq: $id}}, limit: 1) { cached_tags } }", ["id": bookID])
        return Self.genreNames(d["books"].array.first?["cached_tags"] ?? .null)
    }

    static func genreNames(_ tags: JSON) -> [String] {
        var out: [String] = []
        for t in tags["Genre"].array {
            if let name = t["tag"].string, !out.contains(name) { out.append(name) }
        }
        return out
    }

    /// Popular books that share this book's main genres: all of the top three
    /// when enough books do, otherwise the top two, then the top one.
    func similarBooks(bookID: Int, genres: [String]) async throws -> [HCBook] {
        guard !genres.isEmpty else { return [] }
        var best: [HCBook] = []
        for count in Set([min(3, genres.count), min(2, genres.count), 1]).sorted(by: >) {
            let tags: [String: Any] = ["Genre": genres.prefix(count).map { ["tag": $0] }]
            let d = try await query("""
            query Similar($id: Int!, $tags: jsonb!) { books(where: {_and: [{cached_tags: {_contains: $tags}}, {id: {_neq: $id}}, {users_count: {_gt: 25}}]}, order_by: {users_count: desc}, limit: 30) { \(Self.bookFields) } }
            """, ["id": bookID, "tags": tags])
            best = d["books"].array.compactMap(HCBook.from(book:))
            if best.count >= 10 { break }
        }
        return best
    }

    static func dedupeSeries(_ rows: [JSON]) -> [HCBookSeries] {
        var out: [HCBookSeries] = []
        for r in rows {
            guard let sid = r["series"]["id"].int, let name = r["series"]["name"].string else { continue }
            let s = HCBookSeries(id: sid, name: name, position: r["position"].double)
            let key = seriesKey(name)
            if let i = out.firstIndex(where: { seriesKey($0.name) == key && ($0.position == nil || s.position == nil || $0.position == s.position) }) {
                if s.name.count > out[i].name.count { out[i] = HCBookSeries(id: s.id, name: s.name, position: s.position ?? out[i].position) }
            } else {
                out.append(s)
            }
        }
        return out
    }

    /// Public reviews, most-liked first.
    func reviews(bookID: Int, limit: Int = 30) async throws -> [HCReview] {
        let attempts = [
            "user_books(where: {book_id: {_eq: $id}, has_review: {_eq: true}}, order_by: {likes_count: desc}, limit: $n) { id rating review_raw review_has_spoilers reviewed_at likes_count user { username image { url } } }",
            "user_books(where: {book_id: {_eq: $id}, has_review: {_eq: true}}, order_by: {reviewed_at: desc}, limit: $n) { id rating review_raw review_has_spoilers reviewed_at likes_count }",
        ]
        var failure: Error?
        for body in attempts {
            do {
                let d = try await query("query Reviews($id: Int!, $n: Int!) { \(body) }", ["id": bookID, "n": limit])
                return d["user_books"].array.compactMap { r in
                    guard let id = r["id"].int,
                          let text = r["review_raw"].string?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty else { return nil }
                    return HCReview(id: id, rating: r["rating"].double, text: text,
                                    spoilers: r["review_has_spoilers"] == .bool(true),
                                    date: r["reviewed_at"].string, likes: r["likes_count"].int ?? 0,
                                    username: r["user"]["username"].string,
                                    userImage: r["user"]["image"]["url"].string.flatMap(URL.init(string:)))
                }
            } catch { failure = error }
        }
        throw failure ?? HCError(message: "Reviews are unavailable.")
    }

    // MARK: Writes

    @discardableResult
    func setStatus(bookID: Int, status: HCStatus, editionID: Int? = nil) async -> HCUserBook? {
        await withCheckedContinuation { completion in
            if var request = pendingStatuses[bookID] {
                request.status = status       // the last user choice wins
                if let editionID { request.editionID = editionID }
                request.completions.append(completion)
                pendingStatuses[bookID] = request
            } else {
                pendingStatuses[bookID] = StatusRequest(status: status, editionID: editionID,
                                                        completions: [completion])
            }
            if statusFlushTask == nil {
                statusFlushTask = Task { await drainStatusRequests() }
            }
        }
    }

    private func drainStatusRequests() async {
        while !pendingStatuses.isEmpty {
            // Debounce rapid taps and accumulate changes to different books.
            try? await Task.sleep(for: .milliseconds(350))
            let ids = pendingStatuses.keys.sorted().prefix(3)
            let batch = ids.compactMap { id -> (Int, StatusRequest)? in
                pendingStatuses.removeValue(forKey: id).map { (id, $0) }
            }
            guard !batch.isEmpty else { continue }
            do {
                let results = try await sendStatusBatch(batch)
                lastError = nil
                for (id, request) in batch {
                    for completion in request.completions { completion.resume(returning: results[id]) }
                }
            } catch {
                lastError = error.localizedDescription
                for (_, request) in batch {
                    for completion in request.completions { completion.resume(returning: nil) }
                }
            }
        }
        statusFlushTask = nil
    }

    /// One account-scoped lookup, one multi-field mutation and one refresh for
    /// up to three books; repeated updates to one book collapse to its latest
    /// requested status before the network request begins.
    private func sendStatusBatch(_ batch: [(Int, StatusRequest)]) async throws -> [Int: HCUserBook] {
        await HCStatusWriteGate.shared.enter()
        defer { Task { await HCStatusWriteGate.shared.leave() } }
        guard let user else { throw HCError(message: "Connect Hardcover in Settings first.") }
        let ids = batch.map(\.0)
        let idsJSON = ids.map(String.init).joined(separator: ",")
        let original = try await query("""
        query StatusBefore { user_books(where: {user_id: {_eq: \(user.id)}, book_id: {_in: [\(idsJSON)]}}, limit: \(ids.count)) { \(Self.userBookFields) } }
        """)
        let before = Dictionary(uniqueKeysWithValues: original["user_books"].array
            .compactMap(HCUserBook.from).map { ($0.book.id, $0) })
        var fields: [String] = []
        var statusAliases = Set<Int>()
        var finishAliases = Set<Int>()
        let day = Date().isoDay
        for (index, item) in batch.enumerated() {
            let (id, request) = item
            if let existing = before[id] {
                let attachEdition = request.editionID != nil && existing.editionID == nil
                let needsStatus = existing.status != request.status || attachEdition
                let finishRead = request.status == .read && existing.readID != nil &&
                    (existing.status != .read || existing.finishedAt == nil)
                if !needsStatus && !finishRead { continue }
                if needsStatus {
                    var object = "status_id: \(request.status.rawValue)"
                    if attachEdition, let editionID = request.editionID { object += ", edition_id: \(editionID)" }
                    fields.append("s\(index): update_user_book(id: \(existing.id), object: {\(object)}) { id error }")
                    statusAliases.insert(index)
                }
                if finishRead, let readID = existing.readID {
                    fields.append("d\(index): update_user_book_read(id: \(readID), object: {finished_at: \"\(day)\"}) { id error }")
                    finishAliases.insert(index)
                }
            } else {
                var object = "book_id: \(id), status_id: \(request.status.rawValue)"
                if let editionID = request.editionID { object += ", edition_id: \(editionID)" }
                fields.append("s\(index): insert_user_book(object: {\(object)}) { id error }")
                statusAliases.insert(index)
            }
        }
        if fields.isEmpty { return before }
        let mutation = try await query("mutation StatusBatch { \(fields.joined(separator: " ")) }")
        for index in statusAliases {
            let result = mutation["s\(index)"]
            if result["id"].int == nil || !result["error"].isNull {
                throw HCError(message: result["error"].string ?? "Hardcover did not confirm status update.")
            }
        }
        for index in finishAliases {
            let result = mutation["d\(index)"]
            if result["id"].int == nil || !result["error"].isNull {
                throw HCError(message: result["error"].string ?? "Hardcover did not confirm the finish date.")
            }
        }
        revision += 1
        let updated = try await query("""
        query StatusAfter { user_books(where: {user_id: {_eq: \(user.id)}, book_id: {_in: [\(idsJSON)]}}, limit: \(ids.count)) { \(Self.userBookFields) } }
        """)
        return Dictionary(uniqueKeysWithValues: updated["user_books"].array
            .compactMap(HCUserBook.from).map { ($0.book.id, $0) })
    }

    /// Puts a book on a shelf (and rates it) in one request, without reloading shelves:
    /// used by bulk copies, which refresh once at the end.
    func writeShelf(bookID: Int, existing userBookID: Int?, status: HCStatus, rating: Double?) async -> Bool {
        await writeShelves([(bookID: bookID, existing: userBookID, status: status, rating: rating)]).first ?? false
    }

    /// Combines up to four different shelf changes into one HTTP connection.
    /// The rate gate still accounts for EACH top-level GraphQL mutation field.
    /// Results correspond to inputs; failed/unconfirmed items remain pending.
    func writeShelves(_ writes: [(bookID: Int, existing: Int?, status: HCStatus, rating: Double?)]) async -> [Bool] {
        guard !writes.isEmpty else { return [] }
        if writes.count > 4 {
            var results: [Bool] = []
            for start in stride(from: 0, to: writes.count, by: 4) {
                results += await writeShelves(Array(writes[start..<min(start + 4, writes.count)]))
            }
            return results
        }
        await HCStatusWriteGate.shared.enter()
        defer { Task { await HCStatusWriteGate.shared.leave() } }
        var fields: [String] = []
        for (i, item) in writes.enumerated() {
            var object = "status_id: \(item.status.rawValue)"
            if let rating = item.rating, rating.isFinite, (0...5).contains(rating) {
                object += ", rating: \(rating)"
            }
            if let existing = item.existing {
                fields.append("w\(i): update_user_book(id: \(existing), object: {\(object)}) { id error }")
            } else {
                fields.append("w\(i): insert_user_book(object: {book_id: \(item.bookID), \(object)}) { id error }")
            }
        }
        do {
            let response = try await query("mutation BulkShelves { \(fields.joined(separator: " ")) }")
            return writes.indices.map { i in
                let result = response["w\(i)"]
                return result["id"].int != nil && result["error"].isNull
            }
        } catch {
            lastError = error.localizedDescription
            return Array(repeating: false, count: writes.count)
        }
    }

    /// Books for many ISBNs in one request.
    func bookIDs(isbns: [String]) async throws -> [String: Int] {
        guard !isbns.isEmpty else { return [:] }
        let d = try await query("""
        query ISBNs($i: [String!]) { editions(where: {_or: [{isbn_13: {_in: $i}}, {isbn_10: {_in: $i}}]}, limit: \(isbns.count * 3)) { book_id isbn_13 isbn_10 } }
        """, ["i": isbns])
        var out: [String: Int] = [:]
        for e in d["editions"].array {
            guard let id = e["book_id"].int else { continue }
            for key in [e["isbn_13"].string, e["isbn_10"].string].compactMap({ $0 }) where out[key] == nil { out[key] = id }
        }
        return out
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
    func setProgress(bookID: Int, pages: Int, editionID: Int? = nil) async -> Bool {
        do {
            var ub = try await userBook(bookID: bookID)
            if ub == nil || ub?.status == .wantToRead || ub?.status == .paused {
                ub = await setStatus(bookID: bookID, status: .reading, editionID: editionID)
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
            progressRevision += 1
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
