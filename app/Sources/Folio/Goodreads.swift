import Foundation
import Observation

/// Goodreads closed its public API in December 2020, so Folio exchanges libraries with it
/// through the CSV file Goodreads exports and imports (My Books → Import and export).
enum GoodreadsCSV {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n"))
        if chars.first == "\u{feff}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n", "\r": row.append(field); field = ""; rows.append(row); row = []
                default: field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }

    /// Goodreads writes ISBNs as ="0451526341" so spreadsheets keep the leading zero.
    static func cleanISBN(_ s: String?) -> String? {
        guard let s else { return nil }
        let v = s.replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    static func read(_ url: URL) throws -> [TrackedBook] {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw NSError(domain: "Folio", code: 10, userInfo: [NSLocalizedDescriptionKey: "The file isn't text."])
        }
        let rows = parse(text)
        guard let header = rows.first else { return [] }
        let cols = Dictionary(header.enumerated().map { ($0.element.trimmingCharacters(in: .whitespaces).lowercased(), $0.offset) }, uniquingKeysWith: { a, _ in a })
        guard cols["title"] != nil else {
            throw NSError(domain: "Folio", code: 11, userInfo: [NSLocalizedDescriptionKey: "This doesn't look like a Goodreads export (no Title column)."])
        }
        func get(_ r: [String], _ name: String) -> String? {
            guard let i = cols[name], i < r.count else { return nil }
            let v = r[i].trimmingCharacters(in: .whitespacesAndNewlines)
            return v.isEmpty ? nil : v
        }
        return rows.dropFirst().compactMap { r in
            guard let title = get(r, "title") else { return nil }
            var shelf = get(r, "exclusive shelf") ?? "to-read"
            if get(r, "exclusive shelf") == nil, let shelves = get(r, "bookshelves") ?? get(r, "shelves") {
                shelf = shelves.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.first ?? "to-read"
            }
            return TrackedBook(
                title: title,
                author: get(r, "author") ?? "",
                isbn: cleanISBN(get(r, "isbn")),
                isbn13: cleanISBN(get(r, "isbn13")),
                shelf: shelf,
                rating: Int(get(r, "my rating") ?? "0") ?? 0,
                dateRead: get(r, "date read")?.replacingOccurrences(of: "/", with: "-"),
                dateAdded: get(r, "date added")?.replacingOccurrences(of: "/", with: "-"),
                pages: Int(get(r, "number of pages") ?? ""),
                year: Int(get(r, "original publication year") ?? get(r, "year published") ?? ""),
                goodreadsID: get(r, "book id")
            )
        }
    }

    struct ExportRow {
        var title: String
        var author: String
        var isbn13: String?
        var rating: Int
        var pages: Int?
        var year: Int?
        var dateRead: String?
        var dateAdded: String?
        var shelf: String
    }

    static func shelf(for status: HCStatus) -> String {
        switch status {
        case .wantToRead: "to-read"
        case .reading: "currently-reading"
        case .read: "read"
        case .paused: "paused"
        case .dnf: "did-not-finish"
        }
    }

    static func write(_ rows: [ExportRow]) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let header = "Title,Author,ISBN,ISBN13,My Rating,Number of Pages,Year Published,Date Read,Date Added,Bookshelves,Exclusive Shelf"
        let lines = rows.map { r -> String in
            [
                q(r.title), q(r.author), q(""), q(r.isbn13.map { "=\"\($0)\"" } ?? ""),
                String(r.rating), r.pages.map(String.init) ?? "", r.year.map(String.init) ?? "",
                (r.dateRead ?? "").replacingOccurrences(of: "-", with: "/"),
                (r.dateAdded ?? "").replacingOccurrences(of: "-", with: "/"),
                q(r.shelf), q(r.shelf),
            ].joined(separator: ",")
        }
        return ([header] + lines).joined(separator: "\n") + "\n"
    }
}

// MARK: - Live Goodreads shelves through PirateReads (read-only Goodreads API)

enum GRShelf: String, CaseIterable, Identifiable {
    case currentlyReading = "currently-reading"
    case read = "read"
    case wantToRead = "want-to-read"
    case dnf = "dnf"
    var id: String { rawValue }

    var label: String {
        switch self {
        case .currentlyReading: "Currently Reading"
        case .read: "Read"
        case .wantToRead: "Want to Read"
        case .dnf: "Did Not Finish"
        }
    }

    var symbol: String {
        switch self {
        case .currentlyReading: "book"
        case .read: "checkmark.circle"
        case .wantToRead: "bookmark"
        case .dnf: "xmark.circle"
        }
    }

    /// The exclusive-shelf name Goodreads uses in its CSV files.
    var csvShelf: String {
        switch self {
        case .currentlyReading: "currently-reading"
        case .read: "read"
        case .wantToRead: "to-read"
        case .dnf: "did-not-finish"
        }
    }

    static func from(csvShelf s: String) -> GRShelf? {
        switch s {
        case "currently-reading": .currentlyReading
        case "read": .read
        case "to-read": .wantToRead
        case "did-not-finish", "dnf", "abandoned": .dnf
        default: nil
        }
    }
}

@Observable
@MainActor
final class GoodreadsClient {
    static let shared = GoodreadsClient()

    /// Authoritative Goodreads identity comes from the authenticated Sync
    /// account, never from a manually entered or legacy saved profile number.
    var userID: String
    var loading: Set<GRShelf> = []
    var lastError: String?
    var lastSync: Date?

    private init() {
        userID = FolioShelfSync.shared.accounts[.goodreads]?.userID ?? ""
        UserDefaults.standard.removeObject(forKey: "goodreadsUserID")
    }

    var isLinked: Bool { !userID.isEmpty }

    func fetch(_ shelf: GRShelf) async throws -> [TrackedBook] {
        guard isLinked, let uid = userID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return [] }
        var out: [TrackedBook] = []
        var page = 1
        while page <= 40 {
            var comps = URLComponents(string: "https://api.piratereads.com/\(uid)/\(shelf.rawValue)")!
            comps.queryItems = [URLQueryItem(name: "per_page", value: "30"), URLQueryItem(name: "page", value: String(page))]
            var req = URLRequest(url: comps.url!)
            req.timeoutInterval = 40
            req.setValue("Folio/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let json = try JSONDecoder().decode(JSON.self, from: data)
            if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                let msg = json["error"].string ?? json["message"].string ?? "error \(http.statusCode)"
                throw HCError(message: "Goodreads (via PirateReads): \(msg)")
            }
            let books = json["books"].array
            for b in books {
                guard let title = b["book_title"].string else { continue }
                let link = b["book_link"].string
                var gid: String?
                if let link, let r = link.range(of: "/book/show/([0-9]+)", options: .regularExpression) {
                    gid = String(link[r].filter(\.isNumber))
                }
                let isbn = GoodreadsCSV.cleanISBN(b["isbn"].string)
                out.append(TrackedBook(
                    title: title, author: b["book_author"].string ?? "",
                    isbn: isbn?.count == 10 ? isbn : nil, isbn13: isbn?.count == 13 ? isbn : nil,
                    shelf: shelf.csvShelf, rating: b["rating"].int ?? 0,
                    dateRead: nil, dateAdded: b["review_published_on"].string, pages: nil, year: nil,
                    goodreadsID: gid, hardcoverBookID: nil,
                    coverURL: b["book_cover_large"].string ?? b["book_cover_medium"].string,
                    averageRating: b["avg_rating"].double, link: link
                ))
            }
            if books.count < 30 { break }
            page += 1
        }
        return out
    }

    /// Pulls every shelf and merges it into the library's tracked books.
    func syncAll(into store: LibraryStore) async {
        guard loading.isEmpty else { return }   // one sync at a time
        lastError = nil
        var succeeded = 0
        for shelf in GRShelf.allCases {
            loading.insert(shelf)
            do {
                let books = try await fetch(shelf)
                store.mergeTracked(books)
                succeeded += 1
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                lastError = error.localizedDescription
            }
            loading.remove(shelf)
        }
        if succeeded > 0 { lastSync = Date() }
    }
}
