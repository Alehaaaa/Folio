import SwiftUI

// MARK: - Routes

/// One list's books.
struct FolioMobileListRoute: Hashable {
    var list: HCList
}

/// A grid of lists: every list a book is on, or the list browser when `bookID` is nil.
struct FolioMobileListsRoute: Hashable {
    var title: String
    var bookID: Int? = nil
    var initial: [HCList] = []

    static let browse = FolioMobileListsRoute(title: "Lists")
}

// MARK: - Store

/// Featured lists for Discover and the lists each book page found, kept so
/// pages open with their lists in place and Hardcover is asked rarely.
@Observable
@MainActor
final class FolioListsStore {
    static let shared = FolioListsStore()

    private(set) var featured: [HCList] = []
    private(set) var featuredError: String?
    @ObservationIgnored private var featuredSaved: Date?
    @ObservationIgnored private var loadingFeatured = false
    private(set) var byBook: [Int: [HCList]] = [:]
    @ObservationIgnored private var bookLoaded: [Int: Date] = [:]

    private static let defaultsKey = "folio.lists.featured"

    private struct Snapshot: Codable {
        var lists: [HCList]
        var saved: Date
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            featured = snapshot.lists
            featuredSaved = snapshot.saved
        }
    }

    func loadFeatured(_ hardcover: HardcoverClient, force: Bool = false) async {
        guard hardcover.isConnected, !loadingFeatured else { return }
        if !force, let featuredSaved, Date().timeIntervalSince(featuredSaved) < 12 * 60 * 60, !featured.isEmpty { return }
        loadingFeatured = true
        defer { loadingFeatured = false }
        do {
            let lists = try await hardcover.featuredLists(limit: 20)
            guard !lists.isEmpty else { return }
            featured = lists
            featuredError = nil
            featuredSaved = Date()
            FolioImageCache.shared.prefetch(lists.prefix(6).flatMap(\.covers))
            if let data = try? JSONEncoder().encode(Snapshot(lists: lists, saved: Date())) {
                UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            }
        } catch {
            guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            featuredError = error.localizedDescription
            FolioLog.log("Featured lists failed: \(error.localizedDescription)", "lists")
        }
    }

    func loadLists(containing bookID: Int, _ hardcover: HardcoverClient) async {
        guard hardcover.isConnected, bookID > 0 else { return }
        if let loaded = bookLoaded[bookID], Date().timeIntervalSince(loaded) < 30 * 60 { return }
        bookLoaded[bookID] = Date()
        do {
            byBook[bookID] = try await hardcover.lists(containing: bookID)
        } catch {
            bookLoaded[bookID] = nil
            guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            FolioLog.log("Lists with book \(bookID) failed: \(error.localizedDescription)", "lists")
        }
    }
}

// MARK: - Card

/// A list as a card: three covers fanned on a soft panel, and its name.
struct FolioMobileListCard: View {
    let list: HCList
    var width: CGFloat? = nil

    var body: some View {
        NavigationLink(value: FolioMobileListRoute(list: list)) {
            VStack(alignment: .leading, spacing: 8) {
                covers
                Text(list.name)
                    .font(.system(.subheadline, design: .serif).weight(.semibold))
                    .foregroundStyle(FolioTheme.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let count = list.booksCount, count > 0 {
                    Text(count == 1 ? "1 book" : "\(count.formatted()) books")
                        .font(.caption)
                        .foregroundStyle(FolioTheme.muted)
                }
            }
            .frame(width: width, alignment: .topLeading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var covers: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            let coverH = h * 0.78
            let coverW = coverH * 0.67
            ZStack {
                ForEach(Array(Array(list.covers.prefix(3).enumerated()).reversed()), id: \.offset) { pair in
                    let index = pair.offset
                    FolioCachedImage(url: pair.element) {
                        Rectangle().fill(FolioTheme.line.opacity(0.6))
                    }
                    .frame(width: coverW, height: coverH)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 4, x: 1, y: 2)
                    .rotationEffect(.degrees(Double(index - 1) * 7))
                    .offset(x: CGFloat(index - 1) * min(coverW * 0.72, (w - coverW) / 2))
                }
                if list.covers.isEmpty {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.title)
                        .foregroundStyle(FolioTheme.olive)
                }
            }
            .frame(width: w, height: h)
        }
        .aspectRatio(1.45, contentMode: .fit)
        .background(FolioTheme.sage, in: RoundedRectangle(cornerRadius: FolioTheme.tileRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: FolioTheme.tileRadius, style: .continuous))
    }
}

/// A row title that opens a page, as Discover's rows do.
struct FolioMobileRowHeader<Value: Hashable>: View {
    let title: String
    let value: Value

    var body: some View {
        NavigationLink(value: value) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.folioDisplay(.title2))
                    .foregroundStyle(FolioTheme.ink)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FolioTheme.olive)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHint("Show all")
    }
}

/// A horizontal strip of list cards under a title.
struct FolioMobileListsStrip: View {
    let title: String
    let route: FolioMobileListsRoute
    let lists: [HCList]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FolioMobileRowHeader(title: title, value: route)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(lists.prefix(12)) { list in
                        FolioMobileListCard(list: list, width: 210)
                    }
                }
                .padding(.vertical, 4)
            }
            .contentMargins(.horizontal, 20)
            .padding(.horizontal, -20)
        }
    }
}

/// Discover's "Lists" row: Hardcover's featured and most liked lists.
struct FolioMobileFeaturedListsRow: View {
    @Environment(HardcoverClient.self) private var hardcover
    @State private var store = FolioListsStore.shared

    var body: some View {
        Group {
            if !store.featured.isEmpty {
                FolioMobileListsStrip(title: "Lists", route: .browse, lists: store.featured)
            }
        }
        .task(id: hardcover.isConnected) { await store.loadFeatured(hardcover) }
    }
}

/// The book page's "Lists with this book" row.
struct FolioMobileBookListsRow: View {
    let bookID: Int
    @Environment(HardcoverClient.self) private var hardcover
    @State private var store = FolioListsStore.shared

    var body: some View {
        Group {
            if let lists = store.byBook[bookID], !lists.isEmpty {
                FolioMobileListsStrip(
                    title: "Lists with this book",
                    route: FolioMobileListsRoute(title: "Lists with this book", bookID: bookID, initial: lists),
                    lists: lists
                )
            }
        }
        .task(id: "\(bookID)-\(hardcover.isConnected)") {
            await HCPriority.$foreground.withValue(true) { await store.loadLists(containing: bookID, hardcover) }
        }
    }
}

// MARK: - Lists page

/// A grid of lists. Browsing, it searches lists and filters them by genre;
/// for a book, it shows every list the book is on.
struct FolioMobileListsView: View {
    let route: FolioMobileListsRoute

    @Environment(HardcoverClient.self) private var hardcover
    @State private var store = FolioListsStore.shared
    @State private var query = ""
    @State private var genre: String?
    @State private var results: [HCList] = []
    @State private var page = 1
    @State private var reachedEnd = false
    @State private var loading = false
    @State private var error: String?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 16, alignment: .top)]

    private var browsing: Bool { route.bookID == nil }
    private var searchText: String {
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? (genre ?? "") : typed
    }

    /// Your genres first, then Discover's.
    private var genres: [String] {
        var out: [String] = []
        let catalog = FolioDiscoverCatalog.groups.filter { $0.showsRows && $0.title != "Highlights" }
            .flatMap(\.topics).map(\.title)
        for name in FolioMobileDiscoverFeed.shared.yourGenres + catalog
        where !out.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            out.append(name)
        }
        return out
    }

    private var shown: [HCList] {
        if !browsing { return results.isEmpty ? (store.byBook[route.bookID ?? 0] ?? route.initial) : results }
        return searchText.isEmpty ? store.featured : results
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if browsing {
                    FolioSearchField(text: $query, prompt: "Search lists")
                    genreChips
                }
                if !hardcover.isConnected {
                    Text("Connect Hardcover in Settings to browse lists.")
                        .font(.subheadline)
                        .foregroundStyle(FolioTheme.muted)
                } else if let error, shown.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .font(.subheadline)
                            .foregroundStyle(FolioTheme.muted)
                        Button("Retry") { Task { await reload() } }
                            .folioGlassPill(prominent: true)
                    }
                } else if shown.isEmpty && !loading {
                    ContentUnavailableView("No Lists Found", systemImage: "list.bullet.rectangle",
                                           description: Text(browsing ? "Try another genre or word." : "This book isn't on any lists yet."))
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                        ForEach(shown) { list in
                            FolioMobileListCard(list: list)
                                .onAppear {
                                    if list.id == shown.last?.id, browsing, !searchText.isEmpty { Task { await loadMore() } }
                                }
                        }
                        if loading {
                            ForEach(0..<(shown.isEmpty ? 6 : 2), id: \.self) { _ in
                                RoundedRectangle(cornerRadius: FolioTheme.tileRadius, style: .continuous)
                                    .fill(FolioTheme.line.opacity(0.5))
                                    .aspectRatio(1.45, contentMode: .fit)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 30)
            .frame(maxWidth: 1120)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle(route.title)
        .folioPageHeader(route.title)
        .folioScreen()
        .refreshable { await reload(force: true) }
        .task(id: "\(searchText)-\(hardcover.isConnected)") {
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Wait for the typing to settle.
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
            }
            await reload()
        }
    }

    private var genreChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(genres, id: \.self) { name in
                    let selected = genre == name && query.isEmpty
                    Button {
                        query = ""
                        genre = selected ? nil : name
                    } label: {
                        Text(name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(selected ? FolioTheme.surface : FolioTheme.ink)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(selected ? FolioTheme.ink : FolioTheme.surface, in: Capsule())
                            .overlay { Capsule().strokeBorder(FolioTheme.line, lineWidth: selected ? 0 : 0.8) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
        .contentMargins(.horizontal, 20)
        .padding(.horizontal, -20)
    }

    private func reload(force: Bool = false) async {
        guard hardcover.isConnected else { return }
        error = nil
        page = 1
        reachedEnd = false
        if let bookID = route.bookID {
            await store.loadLists(containing: bookID, hardcover)
            return
        }
        let text = searchText
        guard !text.isEmpty else {
            results = []
            await store.loadFeatured(hardcover, force: force)
            if store.featured.isEmpty { error = store.featuredError }
            return
        }
        loading = true
        defer { loading = false }
        do {
            let found = try await HCPriority.$foreground.withValue(true) { try await hardcover.searchLists(text) }
            guard text == searchText else { return }
            results = found
            reachedEnd = found.isEmpty
        } catch {
            guard text == searchText, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            results = []
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard !loading, !reachedEnd, error == nil else { return }
        let text = searchText
        loading = true
        defer { loading = false }
        let next = page + 1
        guard let found = try? await hardcover.searchLists(text, page: next), text == searchText else {
            reachedEnd = true
            return
        }
        page = next
        let known = Set(results.map(\.id))
        let fresh = found.filter { !known.contains($0.id) }
        results += fresh
        reachedEnd = fresh.isEmpty
    }
}

// MARK: - One list

/// A list's books in its own order, with its description above them.
struct FolioMobileListView: View {
    let route: FolioMobileListRoute

    @Environment(HardcoverClient.self) private var hardcover
    @State private var list: HCList?
    @State private var books: [HCBook] = []
    @State private var fetched = 0
    @State private var loading = false
    @State private var reachedEnd = false
    @State private var error: String?
    @State private var started = false
    @State private var expanded = false

    private let pageSize = 30
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 170), spacing: 14, alignment: .top)]
    private var shownList: HCList { list ?? route.list }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let text = shownList.description {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(text)
                            .font(.body)
                            .foregroundStyle(FolioTheme.ink)
                            .lineLimit(expanded ? nil : 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if text.count > 220 {
                            Button(expanded ? "Less" : "More") {
                                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                            }
                            .font(.subheadline)
                            .foregroundStyle(FolioTheme.olive)
                        }
                    }
                }
                if let error, books.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .font(.subheadline)
                            .foregroundStyle(FolioTheme.muted)
                        Button("Retry") { Task { await reload() } }
                            .folioGlassPill(prominent: true)
                    }
                } else if books.isEmpty && !loading && started {
                    ContentUnavailableView("No Books", systemImage: "books.vertical")
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                        // A list is someone's whole selection: books already read stay in it.
                        ForEach(books) { book in
                            FolioMobileRemoteBookTile(book: book)
                                .onAppear {
                                    if book.id == books.last?.id { Task { await loadMore() } }
                                }
                        }
                        if loading {
                            ForEach(0..<(books.isEmpty ? 9 : 3), id: \.self) { _ in
                                FolioMobileBookSkeleton()
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 30)
            .frame(maxWidth: 1120)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(shownList.name)
        .folioPageHeader(shownList.name) {
            if let url = shownList.webURL {
                ShareLink(item: url, subject: Text(shownList.name)) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body.weight(.medium))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .foregroundStyle(FolioTheme.ink)
                .accessibilityLabel("Share list")
            }
        }
        .folioScreen()
        .refreshable { await reload() }
        .task {
            guard !started else { return }
            started = true
            await reload()
        }
    }

    private func reload() async {
        guard hardcover.isConnected else {
            error = "Connect Hardcover in Settings to see this list."
            return
        }
        error = nil
        reachedEnd = false
        loading = true
        defer { loading = false }
        do {
            let answer = try await HCPriority.$foreground.withValue(true) {
                try await hardcover.listBooks(route.list.id, offset: 0, limit: pageSize)
            }
            if let found = answer.list { list = found }
            books = answer.books
            fetched = answer.books.count
            reachedEnd = answer.books.count < pageSize
        } catch {
            guard !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard !loading, !reachedEnd, error == nil, started else { return }
        loading = true
        defer { loading = false }
        guard let answer = try? await hardcover.listBooks(route.list.id, offset: fetched, limit: pageSize) else {
            reachedEnd = true
            return
        }
        fetched += pageSize
        let known = Set(books.map(\.id))
        books += answer.books.filter { !known.contains($0.id) }
        reachedEnd = answer.books.count < pageSize
    }
}
