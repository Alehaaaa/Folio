import SwiftUI
import UniformTypeIdentifiers

struct FolioMobileHomeView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(HardcoverClient.self) private var hardcover
    @Environment(FolioMobileNavigation.self) private var navigation
    let showImporter: () -> Void

    @State private var discovery = FolioMobileHomeRecommendations()
    @State private var shelves = FolioMobileHomeShelves()
    @State private var showingGoals = false
    @ScaledMetric(relativeTo: .body) private var tileWidth: CGFloat = 118

    /// Refresh only when a meaningful preference changes, rather than every
    /// second of a reading session or every increment of page progress.
    private var discoveryKey: String {
        let library = store.books.map { "\($0.id):\($0.author):\($0.status.rawValue):\($0.hardcoverBookID ?? 0):\($0.lastOpenedAt == nil ? 0 : 1)" }
            .sorted().joined(separator: "|")
        let tracked = store.data.tracked.map { "\($0.id):\($0.author):\($0.rating):\($0.shelf)" }
            .sorted().joined(separator: "|")
        return "\(hardcover.user?.id ?? -1)-\(hardcover.revision)-\(library)-\(tracked)"
    }

    /// The books being read (opened or marked reading in the library, or on a
    /// Currently Reading shelf), each in the place it has kept on the shelf.
    private var nookItems: [FolioNookItem] {
        FolioNookShelf.items(library: store, reading: shelves.reading)
    }

    /// Changes when a book joins or leaves the nook, to give new books a place.
    private func nookKey(_ items: [FolioNookItem]) -> String {
        items.map { $0.id + ($0.coverKey ?? "") }.joined(separator: "|")
            + "#\(FolioNookStore.shared.order.isEmpty)"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 34) {
                heading
                let items = nookItems
                if store.books.isEmpty && items.isEmpty {
                    emptyLibrary
                } else {
                    // The page spans the screen like Library, so rows of covers run to its
                    // edge; the nook keeps the width its shelves were designed for.
                    FolioMobileBookshelf(items: FolioNookStore.shared.arranged(items))
                        .frame(maxWidth: 900, alignment: .leading)
                        // The book in the hand floats over the rows below it.
                        .zIndex(FolioNookStore.shared.holding ? 1 : 0)
                        .task(id: nookKey(items)) {
                            FolioNookStore.shared.register(items)
                            FolioSpinePalettes.shared.prepare(items)
                        }
                }
                remoteShelfRow("Want to read", entries: shelfEntries(.wantToRead), status: .wantToRead)
                let forYou = FolioReadBooks.shared.unread(discovery.byYourAuthors)
                if !forYou.isEmpty {
                    section("For you") {
                        ForEach(forYou) { book in
                            FolioMobileRemoteBookTile(book: book, width: min(tileWidth, 180))
                        }
                    }
                }
                FolioMobileHighlightOfTheDay()
                FolioMobileBecauseYouReadRow(tileWidth: min(tileWidth, 180))
                FolioMobileHomeGenreRows(tileWidth: min(tileWidth, 180))
                FolioMobileAuthorRows()
                FolioMobileSavedSeriesRow()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 36)
        }
        // A book in the hand on the shelf holds the page still.
        .scrollDisabled(FolioNookStore.shared.holding)
        // Drop a book from the shelf here to take it off.
        .overlay(alignment: .bottom) { FolioNookBin() }
        // Books in the rows can be dragged onto the shelf.
        .environment(\.folioNookDragSource, true)
        .refreshable {
            await shelves.load(from: hardcover)
            await discovery.load(from: hardcover, books: store.books, tracked: store.data.tracked)
            await FolioHomeGenreRows.shared.load(hardcover, force: true)
        }
        .navigationTitle("Folio")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .folioScreen()
        .sheet(isPresented: $showingGoals, onDismiss: openPendingBook) {
            NavigationStack {
                FolioMobileReadingActivity()
                    .folioDetailDestinations()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showingGoals = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: navigation.pendingRead) { _, id in
            guard id != nil else { return }
            if showingGoals { showingGoals = false } else { openPendingBook() }
        }
        .task(id: "\(hardcover.user?.id ?? -1)-\(FolioBecauseYouRead.seed(in: store)?.hardcoverBookID ?? 0)") {
            await FolioBecauseYouRead.shared.load(library: store, hardcover: hardcover)
        }
        .task(id: "genres-\(hardcover.user?.id ?? -1)-\(hardcover.revision)") {
            await FolioHomeGenreRows.shared.load(hardcover)
        }
        .task(id: discoveryKey) {
            await discovery.load(from: hardcover, books: store.books, tracked: store.data.tracked)
        }
        .task(id: "\(hardcover.user?.id ?? -1)-\(hardcover.revision)-\(hardcover.progressRevision)") {
            await shelves.load(from: hardcover)
            await FolioReadBooks.shared.refresh(from: hardcover)
        }
    }

    private func openPendingBook() {
        guard let id = navigation.pendingRead else { return }
        navigation.pendingRead = nil
        navigation.read(id)
    }

    /// The Folio wordmark and a single serif line, as on a book's title page.
    private var heading: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 6) {
                Text("folio")
                    .font(.system(size: 46, weight: .regular, design: .serif))
                    .tracking(-2)
                    .foregroundStyle(FolioTheme.ink)
                    .accessibilityLabel("Folio")
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                iconButton("plus", label: "Import books", action: showImporter)
                FolioMobileGoalRingsButton { showingGoals = true }
            }
            Text(store.books.isEmpty ? "A little room for every story." : "A little room for your next chapter.")
                .font(.folioDisplay(.title))
                .foregroundStyle(FolioTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2.weight(.light))
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(FolioTheme.ink)
        .accessibilityLabel(label)
    }

    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import an EPUB, PDF, comic or document to start your shelf.")
                .font(.body)
                .foregroundStyle(FolioTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            FolioGlassButton(title: "Import Books", systemImage: "plus", prominent: true, action: showImporter)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .folioCard()
    }

    /// One serif title, an optional "See all", and a horizontal row of covers.
    private func section<Content: View>(_ title: String, seeAll: (() -> Void)? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.folioDisplay(.title2))
                    .foregroundStyle(FolioTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let seeAll {
                    Button("See all", action: seeAll)
                        .font(.subheadline)
                        .foregroundStyle(FolioTheme.olive)
                        .accessibilityLabel("See all \(title)")
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) { content() }
                    .padding(.vertical, 4)
            }
            .contentMargins(.horizontal, 20)
            .padding(.horizontal, -20)
        }
    }

    private func shelfEntries(_ status: HCStatus) -> [FolioMobileShelfEntry] {
        let remote = status == .reading ? shelves.reading : shelves.wantToRead
        let tracked = status.goodreadsShelf.map { store.tracked($0) } ?? []
        let read = FolioReadBooks.shared
        let entries = FolioMobileShelfEntry.merge(hardcover: remote, goodreads: tracked).filter { entry in
            !read.isRead(id: entry.hardcover?.book.id ?? entry.goodreads?.hardcoverBookID,
                         title: entry.title, author: entry.author)
        }
        return Array(entries.prefix(15))
    }

    @ViewBuilder
    private func remoteShelfRow(_ title: String, entries: [FolioMobileShelfEntry], status: HCStatus) -> some View {
        if !entries.isEmpty {
            section(title, seeAll: { navigation.openShelf(status) }) {
                ForEach(entries) { entry in
                    if let item = entry.hardcover {
                        FolioMobileRemoteBookTile(book: item.book, width: min(tileWidth, 180), entry: entry) {
                            Task { await shelves.load(from: hardcover) }
                        }
                    } else if let tracked = entry.goodreads {
                        FolioMobileRemoteBookTile(book: tracked.folioBook, width: min(tileWidth, 180), entry: entry)
                    }
                }
            }
        }
    }
}

/// Currently Reading and Want to Read from Hardcover, loaded for the Home screen.
@Observable
@MainActor
final class FolioMobileHomeShelves {
    var reading: [HCUserBook] = []
    var wantToRead: [HCUserBook] = []
    var loading = false
    var error: String?

    func load(from hardcover: HardcoverClient) async {
        guard hardcover.isConnected else {
            reading = []
            wantToRead = []
            error = nil
            return
        }
        let userID = hardcover.user?.id ?? -1
        // Show the last known shelves at once; the network only refreshes them.
        if reading.isEmpty && wantToRead.isEmpty, let cached = FolioMobileHomeCache.shelves(for: userID) {
            reading = cached.reading
            wantToRead = cached.wantToRead
        }
        loading = true
        defer { loading = false }
        do {
            async let current = hardcover.shelf(.reading)
            async let wanted = hardcover.shelf(.wantToRead)
            let (r, w) = try await (current, wanted)
            reading = r
            wantToRead = w
            error = nil
            FolioMobileHomeCache.saveShelves(userID: userID, reading: r, wantToRead: w)
            FolioSync.adopt(r + w)
            FolioSync.pushPending(hardcover: hardcover)
            FolioImageCache.shared.prefetch((r.prefix(15) + w.prefix(15)).compactMap(\.book.imageURL))
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}
