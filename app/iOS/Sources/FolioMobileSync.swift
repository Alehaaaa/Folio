import Foundation

/// Keeps library books and Hardcover in step whenever Hardcover's shelves are read:
/// pages read elsewhere come in first, then any page that couldn't be sent earlier
/// (offline, rate limited) goes out.
@MainActor
enum FolioSync {
    /// Applies Hardcover's shelf entries to the linked library books.
    static func adopt(_ entries: [HCUserBook], into library: LibraryStore = .shared) {
        guard !entries.isEmpty else { return }
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
