import Foundation

/// A small on-disk snapshot of the Hardcover rows on Home. Home shows the
/// snapshot immediately on launch, then refreshes from the network quietly.
enum FolioMobileHomeCache {
    private struct Book: Codable {
        var id: Int
        var title: String
        var authors: String
        var imageURL: URL?
        var year: Int?
        var pages: Int?
        var rating: Double?
        var ratingsCount: Int?
        var slug: String?
        var alternateTitles: [String]?

        init(_ b: HCBook) {
            id = b.id; title = b.title; authors = b.authors; imageURL = b.imageURL; year = b.year
            pages = b.pages; rating = b.rating; ratingsCount = b.ratingsCount; slug = b.slug
            alternateTitles = b.alternateTitles
        }

        var value: HCBook {
            HCBook(id: id, title: title, authors: authors, imageURL: imageURL, year: year, pages: pages,
                   rating: rating, ratingsCount: ratingsCount, description: nil, slug: slug,
                   alternateTitles: alternateTitles)
        }
    }

    private struct UserBook: Codable {
        var id: Int
        var status: Int?
        var rating: Double?
        var book: Book
        var readID: Int?
        var progressPages: Int?
        var startedAt: String?
        var finishedAt: String?
        var dateAdded: String?

        init(_ u: HCUserBook) {
            id = u.id; status = u.status?.rawValue; rating = u.rating; book = Book(u.book)
            readID = u.readID; progressPages = u.progressPages
            startedAt = u.startedAt; finishedAt = u.finishedAt; dateAdded = u.dateAdded
        }

        var value: HCUserBook {
            HCUserBook(id: id, status: status.flatMap(HCStatus.init(rawValue:)), rating: rating, book: book.value,
                       readID: readID, progressPages: progressPages,
                       startedAt: startedAt, finishedAt: finishedAt, dateAdded: dateAdded)
        }
    }

    private struct Snapshot: Codable {
        var userID: Int
        var reading: [UserBook] = []
        var wantToRead: [UserBook] = []
        var forYou: [Book] = []
    }

    private static var url: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("folio-home-rows.json")
    }

    /// Kept in memory after the first read, so tab switches never touch the disk.
    @MainActor private static var memory: Snapshot?

    @MainActor
    private static func snapshot(for userID: Int) -> Snapshot? {
        if memory == nil, let data = try? Data(contentsOf: url) {
            memory = try? JSONDecoder().decode(Snapshot.self, from: data)
        }
        return memory?.userID == userID ? memory : nil
    }

    @MainActor
    private static func update(userID: Int, _ change: (inout Snapshot) -> Void) {
        var current = snapshot(for: userID) ?? Snapshot(userID: userID)
        change(&current)
        memory = current
        let copy = current
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(copy) { try? data.write(to: url, options: .atomic) }
        }
    }

    @MainActor
    static func shelves(for userID: Int) -> (reading: [HCUserBook], wantToRead: [HCUserBook])? {
        guard let s = snapshot(for: userID) else { return nil }
        return (s.reading.map(\.value), s.wantToRead.map(\.value))
    }

    @MainActor
    static func saveShelves(userID: Int, reading: [HCUserBook], wantToRead: [HCUserBook]) {
        update(userID: userID) {
            $0.reading = reading.prefix(15).map(UserBook.init)
            $0.wantToRead = wantToRead.prefix(15).map(UserBook.init)
        }
    }

    @MainActor
    static func forYou(for userID: Int) -> [HCBook]? {
        snapshot(for: userID).map { $0.forYou.map(\.value) }
    }

    @MainActor
    static func saveForYou(userID: Int, books: [HCBook]) {
        update(userID: userID) { $0.forYou = books.map(Book.init) }
    }
}
