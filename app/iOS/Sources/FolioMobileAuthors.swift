import SwiftUI
import Observation

// MARK: - Routes

/// An author page, opened from a byline. Local books only know the name, so the
/// Hardcover id is optional and resolved on the page.
struct FolioMobileAuthorRoute: Hashable {
    var name: String
    var id: Int?
}

struct FolioMobileSeriesRoute: Hashable {
    var id: Int
    var name: String
    var currentBookID: Int?
}

struct FolioMobileRatingsRoute: Hashable {
    var bookID: Int
    var title: String
}

extension View {
    /// Every page a book can lead to, registered once per navigation stack.
    func folioDetailDestinations() -> some View {
        self
            .navigationDestination(for: UUID.self) { FolioMobileBookDetail(bookID: $0) }
            .navigationDestination(for: HCBook.self) { FolioMobileBookDetail(book: $0) }
            .navigationDestination(for: FolioMobileAuthorRoute.self) { FolioMobileAuthorView(route: $0) }
            .navigationDestination(for: FolioMobileSeriesRoute.self) { FolioMobileSeriesView(route: $0) }
            .navigationDestination(for: FolioMobileRatingsRoute.self) { FolioMobileRatingsView(route: $0) }
    }
}

enum FolioAuthorNames {
    /// "A, B & C" becomes three authors.
    static func split(_ byline: String) -> [String] {
        byline
            .replacingOccurrences(of: " & ", with: ",")
            .replacingOccurrences(of: " and ", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.lowercased() != "unknown author" }
    }

    static func key(_ name: String) -> String {
        BookAutoMatch.words(name).sorted().joined(separator: " ")
    }
}

// MARK: - Followed authors

struct FolioFollowedAuthor: Codable, Hashable, Identifiable {
    var id: String { FolioAuthorNames.key(name) }
    var hardcoverID: Int?
    var name: String
    var imageURL: URL?
}

/// Authors the reader follows, kept on this device.
@Observable
@MainActor
final class FolioFollowedAuthors {
    static let shared = FolioFollowedAuthors()
    private static let defaultsKey = "folio.followedAuthors"

    private(set) var authors: [FolioFollowedAuthor] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([FolioFollowedAuthor].self, from: data) {
            authors = saved
        }
    }

    func isFollowing(_ name: String) -> Bool {
        let key = FolioAuthorNames.key(name)
        return authors.contains { $0.id == key }
    }

    func toggle(name: String, hardcoverID: Int?, imageURL: URL?) {
        let key = FolioAuthorNames.key(name)
        if let index = authors.firstIndex(where: { $0.id == key }) {
            authors.remove(at: index)
        } else {
            authors.insert(FolioFollowedAuthor(hardcoverID: hardcoverID, name: name, imageURL: imageURL), at: 0)
        }
        save()
    }

    /// Fill in an id or portrait learned later.
    func refresh(name: String, hardcoverID: Int?, imageURL: URL?) {
        let key = FolioAuthorNames.key(name)
        guard let index = authors.firstIndex(where: { $0.id == key }) else { return }
        if authors[index].hardcoverID == hardcoverID && authors[index].imageURL == imageURL { return }
        authors[index].hardcoverID = hardcoverID ?? authors[index].hardcoverID
        authors[index].imageURL = imageURL ?? authors[index].imageURL
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(authors) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

// MARK: - On-disk cache

/// Author portraits and the "From authors you follow" row, saved so Home and
/// author bylines show at once and only refresh from the network.
@MainActor
enum FolioAuthorCache {
    struct Author: Codable {
        var id: Int?
        var name: String
        var imageURL: URL?
        var checked: Date
    }

    struct Book: Codable {
        var id: Int
        var title: String
        var authors: String
        var imageURL: URL?
        var year: Int?
        var rating: Double?
        var slug: String?

        init(_ b: HCBook) {
            id = b.id; title = b.title; authors = b.authors; imageURL = b.imageURL
            year = b.year; rating = b.rating; slug = b.slug
        }

        var value: HCBook {
            HCBook(id: id, title: title, authors: authors, imageURL: imageURL, year: year, pages: nil,
                   rating: rating, ratingsCount: nil, description: nil, slug: slug)
        }
    }

    private struct Snapshot: Codable {
        var authors: [String: Author] = [:]
        var followedKey = ""
        var followedBooks: [Book] = []
        var followedSaved: Date?
    }

    private static var loaded: Snapshot?

    private static var url: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("folio-authors.json")
    }

    private static var snapshot: Snapshot {
        get {
            if let loaded { return loaded }
            let value = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } ?? Snapshot()
            loaded = value
            return value
        }
        set {
            loaded = newValue
            if let data = try? JSONEncoder().encode(newValue) { try? data.write(to: url, options: .atomic) }
        }
    }

    static func author(_ name: String) -> Author? { snapshot.authors[FolioAuthorNames.key(name)] }

    static func save(author: HCAuthor?, for name: String) {
        var s = snapshot
        s.authors[FolioAuthorNames.key(name)] = Author(id: author?.id, name: author?.name ?? name,
                                                        imageURL: author?.imageURL, checked: Date())
        snapshot = s
    }

    static func followedBooks(key: String) -> (books: [HCBook], saved: Date?)? {
        let s = snapshot
        guard s.followedKey == key, !s.followedBooks.isEmpty else { return nil }
        return (s.followedBooks.map(\.value), s.followedSaved)
    }

    static func saveFollowedBooks(_ books: [HCBook], key: String) {
        var s = snapshot
        s.followedKey = key
        s.followedBooks = books.map(Book.init)
        s.followedSaved = Date()
        snapshot = s
    }

    /// Resolve an author by name once, then reuse the answer.
    static func resolve(_ name: String, hardcover: HardcoverClient) async -> Author? {
        if let cached = author(name), Date().timeIntervalSince(cached.checked) < 60 * 60 * 24 * 14 { return cached }
        guard hardcover.isConnected else { return author(name) }
        do {
            // Remember misses too, so unknown names are not looked up every launch.
            let found = try await hardcover.author(named: name)
            save(author: found, for: name)
        } catch {
            return author(name)
        }
        return author(name)
    }
}

// MARK: - Shared pieces

/// A round author portrait, or initials on cloth when there is no photo.
struct FolioAuthorPortrait: View {
    let name: String
    let url: URL?
    var size: CGFloat = 76

    private var initials: String {
        FolioAuthorNames.split(name).first.map { full in
            full.split(separator: " ").compactMap(\.first).prefix(2).map { String($0) }.joined()
        } ?? "?"
    }

    var body: some View {
        FolioCachedImage(url: url) {
            ZStack {
                FolioTheme.spine(for: name)
                Text(initials)
                    .font(.system(size: size * 0.34, weight: .regular, design: .serif))
                    .foregroundStyle(Color(hex: "#F3EBD8"))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(FolioTheme.line, lineWidth: 0.8) }
        .accessibilityHidden(true)
    }
}

/// Five stars filled to a rating, with halves.
struct FolioStars: View {
    let rating: Double
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: size * 0.15) {
            ForEach(1...5, id: \.self) { n in
                let value = rating - Double(n - 1)
                Image(systemName: value >= 0.75 ? "star.fill" : value >= 0.25 ? "star.leadinghalf.filled" : "star")
                    .font(.system(size: size))
            }
        }
        .foregroundStyle(FolioTheme.caution)
        .accessibilityElement()
        .accessibilityLabel("\(rating.formatted(.number.precision(.fractionLength(1)))) out of 5 stars")
    }
}

/// One serif title over a horizontal row, as on Home.
struct FolioMobileRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.folioDisplay(.title2))
                .foregroundStyle(FolioTheme.ink)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) { content() }
                    .padding(.vertical, 4)
            }
            .contentMargins(.horizontal, 20)
            .padding(.horizontal, -20)
        }
    }
}

extension String {
    /// "2014-07-15" as a readable date; other strings pass through.
    var folioReadableDate: String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: String(prefix(10))) else { return self }
        return date.formatted(date: .long, time: .omitted)
    }
}

// MARK: - Author page

struct FolioMobileAuthorView: View {
    let route: FolioMobileAuthorRoute

    @Environment(LibraryStore.self) private var library
    @Environment(HardcoverClient.self) private var hardcover
    @Environment(FolioMobileNavigation.self) private var navigation
    @State private var follows = FolioFollowedAuthors.shared
    @State private var author: HCAuthor?
    @State private var books: [HCBook] = []
    @State private var series: [HCSeriesRef] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var bioExpanded = false

    private var name: String { author?.name ?? route.name }

    private var localBooks: [LocalBook] {
        library.books.filter { book in
            FolioAuthorNames.split(book.author).contains { BookAutoMatch.sameAuthor($0, name) }
        }
    }

    private var portraitURL: URL? {
        author?.imageURL ?? FolioAuthorCache.author(route.name)?.imageURL
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let bio = author?.bio {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(bio)
                            .font(.body)
                            .foregroundStyle(FolioTheme.ink)
                            .lineLimit(bioExpanded ? nil : 5)
                            .textSelection(.enabled)
                        if bio.count > 280 {
                            Button(bioExpanded ? "Less" : "More") {
                                withAnimation(.easeInOut(duration: 0.2)) { bioExpanded.toggle() }
                            }
                            .font(.subheadline)
                            .foregroundStyle(FolioTheme.olive)
                        }
                    }
                }
                if !localBooks.isEmpty {
                    FolioMobileRow(title: "In your library") {
                        ForEach(localBooks) { book in
                            NavigationLink(value: book.id) {
                                FolioMobileBookTile(book: book).frame(width: 118)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !series.isEmpty { seriesSection }
                if !books.isEmpty {
                    FolioMobileRemoteBookGridSection(title: "Books", books: books)
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                } else if let failure {
                    Text(failure).font(.subheadline).foregroundStyle(.secondary)
                } else if !hardcover.isConnected {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Connect Hardcover to see every book and series by \(name).")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("Account Settings") { navigation.openSettings() }
                            .folioGlassPill()
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .folioScreen()
        .toolbar {
            if let url = author?.webURL {
                ToolbarItem(placement: .topBarTrailing) {
                    Link(destination: url) { Label("Open on Hardcover", systemImage: "arrow.up.right.square") }
                }
            }
        }
        .task(id: "\(route.name)-\(route.id ?? 0)-\(hardcover.isConnected)") { await load() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            FolioAuthorPortrait(name: name, url: portraitURL, size: 92)
            VStack(alignment: .leading, spacing: 8) {
                Text(name)
                    .font(.system(size: 28, weight: .regular, design: .serif))
                    .foregroundStyle(FolioTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let facts = facts {
                    Text(facts).font(.footnote).foregroundStyle(FolioTheme.muted)
                }
                let following = follows.isFollowing(name)
                Button {
                    follows.toggle(name: name, hardcoverID: author?.id ?? route.id, imageURL: portraitURL)
                } label: {
                    Label(following ? "Following" : "Follow", systemImage: following ? "checkmark" : "plus")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 6)
                }
                .folioGlassPill(prominent: !following)
                .accessibilityIdentifier("folio.followAuthor")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Lifespan, book count and followers on one quiet line.
    private var facts: String? {
        var parts: [String] = []
        if let born = author?.bornYear {
            parts.append(author?.deathYear.map { "\(born)–\($0)" } ?? "Born \(born)")
        }
        if let count = author?.booksCount, count > 0 { parts.append("\(count) books") }
        if let followers = author?.followers, followers > 0 {
            parts.append("\(followers.formatted(.number.notation(.compactName))) readers")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var seriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Series")
                .font(.folioDisplay(.title2))
                .foregroundStyle(FolioTheme.ink)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(series.prefix(8).enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, 86) }
                    NavigationLink(value: FolioMobileSeriesRoute(id: item.id, name: item.name, currentBookID: nil)) {
                        HStack(spacing: 14) {
                            coverStack(item)
                            Text(item.name)
                                .font(.system(.body, design: .serif))
                                .foregroundStyle(FolioTheme.ink)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 6)
                            if let count = item.booksCount, count > 0 {
                                Text("\(count)").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .folioCard(cornerRadius: 18)
        }
    }

    /// Up to three of the author's covers in the series, fanned like a stack.
    private func coverStack(_ item: HCSeriesRef) -> some View {
        let covers = item.bookIDs.compactMap { id in books.first { $0.id == id } }.prefix(3)
        return ZStack(alignment: .leading) {
            if covers.isEmpty {
                FolioClothCover(title: item.name, compact: true)
                    .frame(width: 40, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            ForEach(Array(covers.enumerated().reversed()), id: \.element.id) { index, book in
                FolioMobileRemoteCover(url: book.imageURL, title: book.title)
                    .frame(width: 40, height: 58)
                    .shadow(color: .black.opacity(0.15), radius: 2, x: 1, y: 1)
                    .offset(x: CGFloat(index) * 9)
            }
        }
        .frame(width: 58, height: 58, alignment: .leading)
    }

    @MainActor
    private func load() async {
        guard hardcover.isConnected else { return }
        loading = true
        failure = nil
        defer { loading = false }
        do {
            var found: HCAuthor?
            if let id = route.id { found = try await hardcover.author(id: id) }
            if found == nil { found = try await hardcover.author(named: route.name) }
            guard let found else {
                failure = "Hardcover has no author page for \(route.name)."
                return
            }
            author = found
            FolioAuthorCache.save(author: found, for: route.name)
            follows.refresh(name: found.name, hardcoverID: found.id, imageURL: found.imageURL)
            books = try await hardcover.authorBooks(id: found.id)
            series = (try? await hardcover.series(forBooks: books.prefix(80).map(\.id))) ?? []
        } catch is CancellationError {
            return
        } catch {
            failure = error.localizedDescription
        }
    }
}

// MARK: - Series page

struct FolioMobileSeriesView: View {
    let route: FolioMobileSeriesRoute

    @Environment(LibraryStore.self) private var library
    @Environment(HardcoverClient.self) private var hardcover
    private struct Entry: Identifiable {
        var position: Double?
        var book: HCBook
        var id: Int { book.id }
    }

    @State private var entries: [Entry] = []
    @State private var loading = true
    @State private var failure: String?

    var body: some View {
        List {
            if loading && entries.isEmpty {
                ProgressView().frame(maxWidth: .infinity).folioRow()
            } else if let failure, entries.isEmpty {
                Text(failure).foregroundStyle(.secondary).folioRow()
            }
            ForEach(entries) { entry in
                NavigationLink(value: entry.book) {
                    row(entry)
                }
                .listRowBackground(entry.book.id == route.currentBookID ? FolioTheme.sage : FolioTheme.surface)
            }
        }
        .navigationTitle(route.name)
        .navigationBarTitleDisplayMode(.inline)
        .folioScreen()
        .task(id: route.id) {
            loading = true
            do {
                entries = try await hardcover.seriesBooks(route.id).map { Entry(position: $0.position, book: $0.book) }
                failure = entries.isEmpty ? "No books found in this series." : nil
            } catch {
                failure = error.localizedDescription
            }
            loading = false
        }
    }

    private func row(_ entry: Entry) -> some View {
        let owned = library.books.contains { $0.hardcoverBookID == entry.book.id }
            || library.localCopy(author: entry.book.authors, title: entry.book.title) != nil
        return HStack(spacing: 14) {
            Text(entry.position.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "–")
                .font(.system(.title3, design: .serif))
                .foregroundStyle(FolioTheme.olive)
                .frame(minWidth: 26)
                .monospacedDigit()
            FolioMobileRemoteCover(url: entry.book.imageURL, title: entry.book.title)
                .frame(width: 46, height: 68)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.book.title)
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(FolioTheme.ink)
                    .lineLimit(3)
                HStack(spacing: 8) {
                    if let year = entry.book.year { Text(String(year)) }
                    if let rating = entry.book.rating, rating > 0 {
                        Label(rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                    }
                    if owned { Label("In library", systemImage: "checkmark.circle.fill").foregroundStyle(FolioTheme.success) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Ratings and reviews

/// Average, count and the five-bar distribution, as on Goodreads.
struct FolioMobileRatingsSummary: View {
    let stats: HCBookStats

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                Text((stats.rating ?? 0).formatted(.number.precision(.fractionLength(2))))
                    .font(.system(size: 44, weight: .regular, design: .serif))
                    .foregroundStyle(FolioTheme.ink)
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 5) {
                    FolioStars(rating: stats.rating ?? 0, size: 16)
                    Text(countsLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if stats.distribution.count == 5 {
                let total = max(1, stats.distribution.reduce(0, +))
                VStack(spacing: 6) {
                    ForEach(0..<5, id: \.self) { index in
                        let share = Double(stats.distribution[index]) / Double(total)
                        HStack(spacing: 10) {
                            Text("\(5 - index)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(FolioTheme.line.opacity(0.6))
                                    Capsule().fill(FolioTheme.caution)
                                        .frame(width: max(share > 0 ? 4 : 0, geo.size.width * share))
                                }
                            }
                            .frame(height: 8)
                            Text("\(Int((share * 100).rounded()))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 38, alignment: .trailing)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(5 - index) stars, \(Int((share * 100).rounded())) percent")
                    }
                }
            }
        }
    }

    private var countsLine: String {
        var parts: [String] = []
        if let n = stats.ratingsCount { parts.append("\(n.formatted()) ratings") }
        if let n = stats.reviewsCount, n > 0 { parts.append("\(n.formatted()) reviews") }
        return parts.isEmpty ? "No ratings yet" : parts.joined(separator: " · ")
    }
}

struct FolioMobileReviewRow: View {
    let review: HCReview
    var lineLimit: Int? = 6
    @State private var revealed = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                FolioAuthorPortrait(name: review.username ?? "Reader", url: review.userImage, size: 28)
                Text(review.username.map { "@\($0)" } ?? "A reader")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(FolioTheme.ink)
                Spacer(minLength: 6)
                if let rating = review.rating, rating > 0 { FolioStars(rating: rating, size: 11) }
            }
            ZStack {
                Text(review.text)
                    .font(.system(.callout, design: .serif))
                    .foregroundStyle(FolioTheme.ink)
                    .lineLimit(expanded ? nil : lineLimit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .blur(radius: review.spoilers && !revealed ? 6 : 0)
                if review.spoilers && !revealed {
                    Button("Show spoilers") { revealed = true }
                        .font(.subheadline)
                        .folioGlassPill()
                }
            }
            .onTapGesture { if !review.spoilers || revealed { expanded.toggle() } }
            HStack(spacing: 12) {
                if let date = review.date { Text(date.folioReadableDate) }
                if review.likes > 0 { Label("\(review.likes)", systemImage: "heart") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct FolioMobileRatingsView: View {
    let route: FolioMobileRatingsRoute

    @Environment(HardcoverClient.self) private var hardcover
    @State private var stats: HCBookStats?
    @State private var reviews: [HCReview] = []
    @State private var reviewsFailed = false
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let stats {
                    FolioMobileRatingsSummary(stats: stats)
                        .padding(18)
                        .folioCard(cornerRadius: 18)
                    if let readers = stats.readersCount, readers > 0 {
                        HStack(spacing: 0) {
                            stat(readers, "readers")
                            if let read = stats.readCount, read > 0 { stat(read, "finished") }
                            if let n = stats.reviewsCount, n > 0 { stat(n, "reviews") }
                        }
                    }
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                }
                if !reviews.isEmpty {
                    Text("Reviews")
                        .font(.folioDisplay(.title2))
                        .foregroundStyle(FolioTheme.ink)
                        .accessibilityAddTraits(.isHeader)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(reviews.enumerated()), id: \.element.id) { index, review in
                            if index > 0 { Divider().padding(.vertical, 14) }
                            FolioMobileReviewRow(review: review, lineLimit: 10)
                        }
                    }
                    .padding(18)
                    .folioCard(cornerRadius: 18)
                } else if reviewsFailed {
                    Text("Reviews could not be loaded from Hardcover.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else if !loading {
                    Text("No written reviews yet.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .folioScreen()
        .task(id: route.bookID) {
            loading = true
            stats = try? await hardcover.stats(bookID: route.bookID)
            do {
                reviews = try await hardcover.reviews(bookID: route.bookID, limit: 40)
            } catch {
                reviewsFailed = true
            }
            loading = false
        }
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value.formatted(.number.notation(.compactName)))
                .font(.system(.title3, design: .serif))
                .foregroundStyle(FolioTheme.ink)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Home rows

/// "Authors for you" and "From authors you follow" on Home. Both draw from the
/// on-disk cache first, then refresh quietly.
struct FolioMobileAuthorRows: View {
    @Environment(LibraryStore.self) private var store
    @Environment(HardcoverClient.self) private var hardcover
    @State private var follows = FolioFollowedAuthors.shared
    @State private var portraits: [String: URL] = [:]
    @State private var followedBooks: [HCBook] = []
    @ScaledMetric(relativeTo: .body) private var tileWidth: CGFloat = 118

    /// Followed authors first, then the authors the reader spends the most time with.
    private var recommended: [FolioAuthorRef] {
        var scores: [String: (name: String, score: Double)] = [:]
        func add(_ byline: String, _ score: Double) {
            for name in FolioAuthorNames.split(byline) {
                let key = FolioAuthorNames.key(name)
                guard key.count > 2 else { continue }
                scores[key] = (scores[key]?.name ?? name, (scores[key]?.score ?? 0) + score)
            }
        }
        for book in store.books {
            switch book.status {
            case .finished: add(book.author, 5)
            case .reading: add(book.author, 4)
            case .wantToRead: add(book.author, 1)
            case .none: add(book.author, book.lastOpenedAt == nil ? 0.5 : 2)
            }
        }
        for item in store.data.tracked {
            add(item.author, item.rating >= 4 ? 5 : item.rating >= 3 ? 2 : 1)
        }
        let followed = follows.authors.map { FolioAuthorRef(name: $0.name, id: $0.hardcoverID, following: true) }
        let followedKeys = Set(follows.authors.map(\.id))
        let others = scores.filter { !followedKeys.contains($0.key) }.values
            .sorted { $0.score == $1.score ? $0.name < $1.name : $0.score > $1.score }
            .map { FolioAuthorRef(name: $0.name, id: nil, following: false) }
        return Array((followed + others).prefix(14))
    }

    private var followKey: String {
        follows.authors.map(\.id).sorted().joined(separator: "|")
    }

    var body: some View {
        let authors = recommended
        if !authors.isEmpty {
            FolioMobileRow(title: "Authors for you") {
                ForEach(authors, id: \.key) { author in
                    NavigationLink(value: FolioMobileAuthorRoute(name: author.name, id: author.id)) {
                        VStack(spacing: 8) {
                            FolioAuthorPortrait(name: author.name,
                                                url: portraits[author.key] ?? FolioAuthorCache.author(author.name)?.imageURL,
                                                size: 78)
                                .overlay(alignment: .bottomTrailing) {
                                    if author.following {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 18))
                                            .foregroundStyle(FolioTheme.olive, FolioTheme.surface)
                                    }
                                }
                            Text(author.name)
                                .font(.system(.caption, design: .serif))
                                .foregroundStyle(FolioTheme.ink)
                                .multilineTextAlignment(.center)
                                .lineLimit(2, reservesSpace: true)
                        }
                        .frame(width: 88)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(author.following ? "\(author.name), following" : author.name)
                }
            }
            .task(id: authors.map(\.name).joined(separator: "|") + "\(hardcover.isConnected)") {
                await loadPortraits(authors)
            }
            .task(id: "\(followKey)-\(hardcover.isConnected)") { await loadFollowedBooks() }
        }
        // The saved row shows on the first frame; the task only refreshes it.
        let shownBooks = followedBooks.isEmpty && !follows.authors.isEmpty
            ? (FolioAuthorCache.followedBooks(key: followKey)?.books ?? []) : followedBooks
        if !shownBooks.isEmpty {
            FolioMobileRow(title: "From authors you follow") {
                ForEach(shownBooks) { book in
                    FolioMobileRemoteBookTile(book: book, width: min(tileWidth, 180))
                }
            }
        }
    }

    @MainActor
    private func loadPortraits(_ authors: [FolioAuthorRef]) async {
        // Cached portraits first, all at once.
        for author in authors {
            if let url = FolioAuthorCache.author(author.name)?.imageURL {
                portraits[FolioAuthorNames.key(author.name)] = url
            }
        }
        for author in authors where portraits[FolioAuthorNames.key(author.name)] == nil {
            guard !Task.isCancelled else { return }
            if let found = await FolioAuthorCache.resolve(author.name, hardcover: hardcover), let url = found.imageURL {
                portraits[FolioAuthorNames.key(author.name)] = url
                follows.refresh(name: author.name, hardcoverID: found.id, imageURL: url)
            }
        }
    }

    @MainActor
    private func loadFollowedBooks() async {
        let key = followKey
        guard !follows.authors.isEmpty else {
            followedBooks = []
            return
        }
        let cached = FolioAuthorCache.followedBooks(key: key)
        if let cached { followedBooks = cached.books }
        // Refresh at most every few hours; the cached row shows instantly meanwhile.
        if let saved = cached?.saved, Date().timeIntervalSince(saved) < 60 * 60 * 6 { return }
        guard hardcover.isConnected else { return }

        let knownIDs = Set(store.books.compactMap(\.hardcoverBookID))
        var groups: [[HCBook]] = []
        for followed in follows.authors.prefix(6) {
            guard !Task.isCancelled else { return }
            var id = followed.hardcoverID
            if id == nil { id = await FolioAuthorCache.resolve(followed.name, hardcover: hardcover)?.id }
            guard let id, let books = try? await hardcover.authorBooks(id: id) else { continue }
            let fresh = books.filter {
                !knownIDs.contains($0.id) && store.localCopy(author: $0.authors, title: $0.title) == nil
            }
            groups.append(Array(fresh.prefix(8)))
        }
        guard !Task.isCancelled else { return }
        var ids = Set<Int>()
        var chosen: [HCBook] = []
        for index in 0..<(groups.map(\.count).max() ?? 0) {
            for group in groups where group.indices.contains(index) {
                if ids.insert(group[index].id).inserted { chosen.append(group[index]) }
            }
        }
        followedBooks = Array(chosen.prefix(18))
        FolioAuthorCache.saveFollowedBooks(followedBooks, key: key)
    }
}

struct FolioAuthorRef: Hashable {
    var key: String { FolioAuthorNames.key(name) }
    var name: String
    var id: Int?
    var following: Bool
}
