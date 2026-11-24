import SwiftUI

/// "Because you read …": popular books in the genres of the last book finished in
/// Folio (or the one being read), by other authors. Kept for a day per book, so
/// Home opens with the row in place and asks Hardcover at most twice a day.
@Observable
@MainActor
final class FolioBecauseYouRead {
    static let shared = FolioBecauseYouRead()
    private static let defaultsKey = "folio.becauseYouRead"

    private struct Snapshot: Codable {
        var seedID: Int
        var seedTitle: String
        var books: [HCBook]
        var saved: Date
    }

    private(set) var seedTitle: String?
    private(set) var books: [HCBook] = []
    @ObservationIgnored private var seedID: Int?
    @ObservationIgnored private var saved: Date?
    @ObservationIgnored private var loading = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            seedID = snapshot.seedID
            seedTitle = snapshot.seedTitle
            books = snapshot.books
            saved = snapshot.saved
        }
    }

    /// The last book finished here, else the one opened most recently, linked to Hardcover.
    static func seed(in library: LibraryStore) -> LocalBook? {
        let linked = library.books.filter { ($0.hardcoverBookID ?? 0) > 0 }
        if let finished = linked.filter({ $0.status == .finished })
            .max(by: { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }) {
            return finished
        }
        return linked.filter { $0.lastOpenedAt != nil }
            .max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
    }

    func load(library: LibraryStore, hardcover: HardcoverClient) async {
        guard hardcover.isConnected, let seed = Self.seed(in: library), let id = seed.hardcoverBookID else { return }
        if seedID == id, let saved, Date().timeIntervalSince(saved) < 12 * 60 * 60 { return }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        guard let genres = try? await hardcover.genres(bookID: id), !genres.isEmpty,
              let similar = try? await FolioOpenLibrary.similar(
                to: HCBook(id: id, title: seed.title, authors: seed.author),
                genres: genres.filter { !["fiction", "nonfiction", "adult", "general"].contains($0.lowercased()) }) else { return }
        let byline = Set(FolioAuthorNames.split(seed.author).map(FolioAuthorNames.key))
        var seen = Set<Int>()
        let picked = similar.filter { book in
            book.id != id && seen.insert(book.id).inserted
                && library.localCopy(author: book.authors, title: book.title) == nil
                && FolioAuthorNames.split(book.authors).allSatisfy { !byline.contains(FolioAuthorNames.key($0)) }
        }
        guard !picked.isEmpty else { return }
        seedID = id
        seedTitle = seed.title
        books = Array(picked.prefix(20))
        saved = Date()
        FolioImageCache.shared.prefetch(books.prefix(8).compactMap(\.imageURL))
        let snapshot = Snapshot(seedID: id, seedTitle: seed.title, books: books, saved: Date())
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// The Home row for `FolioBecauseYouRead`.
struct FolioMobileBecauseYouReadRow: View {
    var tileWidth: CGFloat
    @State private var model = FolioBecauseYouRead.shared

    var body: some View {
        let shown = FolioReadBooks.shared.unread(model.books).prefix(15)
        if let title = model.seedTitle, shown.count >= 3 {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Because you read \(title)")
                        .font(.folioDisplay(.title2))
                        .foregroundStyle(FolioTheme.ink)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(Array(shown)) { book in
                                FolioMobileRemoteBookTile(book: book, width: tileWidth)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .contentMargins(.horizontal, 20)
                    .padding(.horizontal, -20)
                }
        }
    }
}
