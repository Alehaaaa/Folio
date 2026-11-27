import Foundation

/// Keeps library books and Hardcover in step whenever Hardcover's shelves are read:
/// pages read elsewhere come in first, then any page that couldn't be sent earlier
/// (offline, rate limited) goes out.
@MainActor
enum FolioSync {
    /// Applies Hardcover's shelf entries to the linked library books.
    static func adopt(_ entries: [HCUserBook], into library: LibraryStore = .shared) {
        guard !entries.isEmpty else { return }
        FolioBookStates.shared.adoptHardcover(entries)
        let byHardcover = Dictionary(entries.map { ($0.book.id, $0) }, uniquingKeysWith: { first, _ in first })
        for book in library.books {
            guard let id = book.hardcoverBookID, let entry = byHardcover[id] else { continue }
            library.adoptHardcoverProgress(book.id, from: entry)
        }
    }

    /// Sends the progress of up to five recently read books whose last page never reached Hardcover.
    static func pushPending(library: LibraryStore = .shared, hardcover: HardcoverClient = .shared) {
        FolioShelfSync.shared.pushPending(library: library)
        guard hardcover.isConnected else { return }
        let pending = library.books.filter { book in
            guard book.status != .finished, book.hardcoverBookID != nil,
                  let total = book.hardcoverPages, total > 0 else { return false }
            let pages = Int((min(1, book.progress) * Double(total)).rounded())
            return pages > 0 && pages != book.syncedProgressPages
        }
        .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
        .prefix(5)
        for book in pending {
            FolioHardcoverProgressSync.push(book.id, store: library, hardcover: hardcover)
        }
    }
}

/// Finds the Hardcover record for a title and author, remembering answers
/// (including misses) for the session.
@MainActor
enum FolioHardcoverMatch {
    private static var answers: [String: HCBook?] = [:]

    /// "Red Rising (Red Rising Saga, #1)" is "Red Rising".
    static func plainTitle(_ title: String) -> String {
        var t = title
        if let open = t.range(of: " (", options: .backwards), t.hasSuffix(")") { t = String(t[..<open.lowerBound]) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func find(title: String, author: String, hardcover: HardcoverClient) async -> HCBook? {
        let key = BookMatch.key(author: author, title: title)
        if let known = answers[key] { return known }
        let wanted = plainTitle(title)
        guard !BookAutoMatch.words(wanted).isEmpty,
              let results = try? await hardcover.search(wanted) else { return nil }
        let firstAuthor = FolioAuthorNames.split(author).first ?? author
        // Search ranks the most-read edition first; take the first exact title and author.
        let match = results.first { candidate in
            BookAutoMatch.sameTitle(wanted, plainTitle(candidate.title)) &&
                FolioAuthorNames.split(candidate.authors).contains { BookAutoMatch.sameAuthor(firstAuthor, $0) }
        }
        answers[key] = .some(match)
        return match
    }
}

extension TrackedBook {
    /// A Goodreads shelf entry opens the same book page as everything else.
    var folioBook: HCBook {
        HCBook(id: hardcoverBookID ?? 0, title: title, authors: author,
               imageURL: coverURL.flatMap(URL.init(string:)), year: year, pages: pages,
               rating: averageRating, ratingsCount: nil, description: nil, slug: nil)
    }
}

/// Sends a library book's reading progress to Hardcover as pages, so the app
/// and Hardcover agree without a separate page field.
@MainActor
enum FolioPendingProgress {
    private static let key = "folio.pendingHardcoverPages"

    private static var all: [String: [Double]] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The page you last chose for a book, for up to a day.
    static func value(for bookID: Int) -> Int? {
        guard let entry = all[String(bookID)], entry.count == 2,
              Date().timeIntervalSince1970 - entry[1] < 24 * 60 * 60 else { return nil }
        return Int(entry[0])
    }

    static func set(_ pages: Int, for bookID: Int) {
        all[String(bookID)] = [Double(pages), Date().timeIntervalSince1970]
    }

    static func clear(_ bookID: Int) {
        guard all[String(bookID)] != nil else { return }
        all[String(bookID)] = nil
    }
}

@MainActor
enum FolioHardcoverProgressSync {
    static func push(_ bookID: UUID, store: LibraryStore, hardcover: HardcoverClient = .shared, pages known: Int? = nil) {
        // The other services (StoryGraph, Goodreads, Fable, Pagebound, LibraryThing) get the same page.
        if FolioShelfSync.shared.anyConnected {
            Task { await FolioShelfSync.shared.sync(bookID: bookID, library: store) }
        }
        guard let book = store.book(bookID), let hcID = book.hardcoverBookID,
              hardcover.isConnected, book.status != .finished,
              let total = book.hardcoverPages ?? known, total > 0 else { return }
        let pages = Int((min(1, book.progress) * Double(total)).rounded())
        guard pages > 0, pages != book.syncedProgressPages else { return }
        Task {
            if await hardcover.setProgress(bookID: hcID, pages: pages, editionID: book.hardcoverEditionID) {
                store.update(bookID) { $0.syncedProgressPages = pages }
            }
        }
    }
}
