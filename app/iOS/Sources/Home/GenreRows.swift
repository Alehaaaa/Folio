import SwiftUI

/// Home rows built from the genres you read (the same "Your genres" Discover shows):
/// popular picks across them, and the new releases in each. Kept for half a day,
/// so Home opens with the rows in place.
@Observable
@MainActor
final class FolioHomeGenreRows {
    static let shared = FolioHomeGenreRows()
    private static let defaultsKey = "folio.home.genreRows"

    struct Release: Codable, Hashable, Identifiable {
        var genre: String
        var books: [HCBook]
        var id: String { genre }
    }

    private struct Snapshot: Codable {
        var genres: [String]
        var picks: [HCBook]
        var releases: [Release]
        var saved: Date
    }

    private(set) var picks: [HCBook] = []
    private(set) var releases: [Release] = []
    @ObservationIgnored private var genres: [String] = []
    @ObservationIgnored private var saved: Date?
    @ObservationIgnored private var loading = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            genres = snapshot.genres
            picks = snapshot.picks
            releases = snapshot.releases
            saved = snapshot.saved
        }
    }

    func load(_ hardcover: HardcoverClient, force: Bool = false) async {
        guard hardcover.isConnected, !loading else { return }
        let feed = FolioMobileDiscoverFeed.shared
        await feed.loadYourGenres(from: hardcover)
        let wanted = Array(feed.yourGenres.prefix(4))
        guard !wanted.isEmpty else { return }
        if !force, wanted == genres, let saved, Date().timeIntervalSince(saved) < 12 * 60 * 60 { return }
        loading = true
        defer { loading = false }

        let foundPicks = (try? await hardcover.picks(genres: wanted, limit: 40)) ?? []
        var foundReleases: [Release] = []
        let today = Date()
        let since = Calendar.current.date(byAdding: .day, value: -90, to: today) ?? today
        for genre in wanted.prefix(3) {
            guard !Task.isCancelled else { return }
            if let books = try? await hardcover.releases(from: since, to: today, genre: genre, limit: 20), books.count >= 3 {
                foundReleases.append(Release(genre: genre, books: books))
            }
        }
        guard !Task.isCancelled, !foundPicks.isEmpty || !foundReleases.isEmpty else { return }
        genres = wanted
        picks = foundPicks
        releases = foundReleases
        saved = Date()
        FolioImageCache.shared.prefetch((foundPicks.prefix(8) + foundReleases.flatMap { $0.books.prefix(6) }).compactMap(\.imageURL))
        let snapshot = Snapshot(genres: wanted, picks: foundPicks, releases: foundReleases, saved: Date())
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// "From your shelves" and "New in <genre>" on Home.
struct FolioMobileHomeGenreRows: View {
    var tileWidth: CGFloat
    @Environment(LibraryStore.self) private var store
    @State private var model = FolioHomeGenreRows.shared

    private func fresh(_ books: [HCBook]) -> [HCBook] {
        FolioReadBooks.shared.unread(books).filter { FolioBookOverrides.shared.libraryCopy(of: $0) == nil }
    }

    var body: some View {
        // A group, so each row is its own item in Home's stack and spaced like the others.
        Group {
            let picks = fresh(model.picks).prefix(15)
            if picks.count >= 3 {
                FolioMobileRow(title: "From your shelves") {
                    ForEach(Array(picks)) { book in
                        FolioMobileRemoteBookTile(book: book, width: tileWidth)
                    }
                }
            }
            ForEach(model.releases) { release in
                let books = fresh(release.books).prefix(15)
                if books.count >= 3 {
                    FolioMobileRow(title: "New in \(release.genre)",
                                   seeAll: FolioMobileTopicRoute(topic: FolioDiscoverTopic(kind: .genre(release.genre), title: release.genre),
                                                                 sort: .newest, initial: release.books)) {
                        ForEach(Array(books)) { book in
                            FolioMobileRemoteBookTile(book: book, width: tileWidth)
                        }
                    }
                }
            }
        }
    }
}
