import SwiftUI

/// Search both the on-device library and Hardcover without requiring a search submission.
/// The request identity makes responses from earlier queries harmless even when a network
/// operation completes after SwiftUI cancels its task.
struct FolioSearchView: View {
    let query: String

    @Environment(LibraryStore.self) private var store
    @Environment(HardcoverClient.self) private var hardcover

    @State private var searchText: String
    @State private var remoteBooks: [HCBook] = []
    @State private var remoteResultQuery = ""
    @State private var trendingBooks: [HCBook] = []
    @State private var isSearchingHardcover = false
    @State private var isLoadingTrending = false
    @State private var remoteError: String?
    @State private var selectedBook: HCBook?
    @State private var retryCount = 0
    @FocusState private var searchFocused: Bool

    private struct SearchRequest: Hashable {
        var text: String
        var connected: Bool
        var retryCount: Int
    }

    init(query: String = "") {
        self.query = query
        _searchText = State(initialValue: query)
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var request: SearchRequest {
        SearchRequest(text: trimmedQuery, connected: hardcover.isConnected, retryCount: retryCount)
    }

    private var localResults: [LocalBook] {
        guard !trimmedQuery.isEmpty else { return [] }
        return store.books(.all, search: trimmedQuery)
    }

    private var goodreadsResults: [TrackedBook] {
        guard !trimmedQuery.isEmpty else { return [] }
        let localKeys = Set(store.books.map { BookMatch.key(author: $0.author, title: $0.title) })
        return store.data.tracked.filter { book in
            (book.title.localizedCaseInsensitiveContains(trimmedQuery)
             || book.author.localizedCaseInsensitiveContains(trimmedQuery))
            && !localKeys.contains(BookMatch.key(author: book.author, title: book.title))
        }
    }

    private var inProgressBooks: [LocalBook] {
        Array(store.continueReading.prefix(8))
    }

    private var recentBooks: [LocalBook] {
        let continueIDs = Set(inProgressBooks.map(\.id))
        return Array(store.recentlyAdded.filter { !continueIDs.contains($0.id) }.prefix(8))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Search")
                        .font(.largeTitle.weight(.bold))
                    Text("Discover a book in your library or find something new to read.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                searchField

                if trimmedQuery.isEmpty {
                    discoveryContent
                } else {
                    resultsContent
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onChange(of: query) { _, incoming in
            if searchText != incoming { searchText = incoming }
        }
        .task(id: request) {
            await loadHardcover(for: request)
        }
        .bookPopup(item: $selectedBook) { book in
            HCBookDetail(book: book)
        }
    }

    private var searchField: some View {
        HStack(spacing: 13) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search books or authors", text: $searchText)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .accessibilityIdentifier("folio.search.query")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            } else {
                Text(hardcover.isConnected ? "LIBRARY + HARDCOVER" : "YOUR LIBRARY")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 19)
        .padding(.vertical, 18)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    @ViewBuilder
    private var discoveryContent: some View {
        if !inProgressBooks.isEmpty {
            VStack(alignment: .leading, spacing: 17) {
                SectionHeader(title: "Continue Reading", subtitle: "Pick up where you left off")
                localGrid(inProgressBooks)
            }
        }

        if !recentBooks.isEmpty {
            VStack(alignment: .leading, spacing: 17) {
                SectionHeader(title: "Recently Added", subtitle: "From your library")
                localGrid(recentBooks)
            }
        }

        if store.books.isEmpty {
            GlassCard {
                HStack(spacing: 17) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.secondary)
                        .frame(width: 45)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Your library starts here").font(.headline)
                        Text("Import an EPUB, PDF, or document to find it here anytime.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    Spacer(minLength: 8)
                    Button("Add Books…") {
                        NotificationCenter.default.post(name: .folioImport, object: nil)
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }

        if hardcover.isConnected {
            VStack(alignment: .leading, spacing: 17) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader(title: "Trending on Hardcover", subtitle: "Popular reads this month")
                    Spacer()
                    if isLoadingTrending { ProgressView().controlSize(.small).accessibilityLabel("Loading trending books") }
                }

                if !trendingBooks.isEmpty {
                    remoteGrid(trendingBooks)
                } else if !isLoadingTrending, let remoteError {
                    errorCard(remoteError)
                } else if !isLoadingTrending {
                    Text("Trending books aren't available right now.")
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            accountPrompt
        }
    }

    private var resultsContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 17) {
                SectionHeader(title: "Your Library", subtitle: "\(localResults.count) matching \(localResults.count == 1 ? "book" : "books")")
                if localResults.isEmpty {
                    emptyMessage("No matching books in your library", symbol: "books.vertical",
                                 detail: "Your imported books will appear here when their titles or authors match.")
                } else {
                    localGrid(localResults)
                }
            }

            if !goodreadsResults.isEmpty {
                VStack(alignment: .leading, spacing: 17) {
                    SectionHeader(title: "Goodreads Shelves", subtitle: "\(goodreadsResults.count) tracked \(goodreadsResults.count == 1 ? "book" : "books")")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 188), spacing: 24, alignment: .top)],
                              alignment: .leading, spacing: 28) {
                        ForEach(goodreadsResults) { book in
                            TrackedCell(book: book)
                        }
                    }
                }
            }

            if hardcover.isConnected {
                VStack(alignment: .leading, spacing: 17) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionHeader(title: "Explore Hardcover", subtitle: "Books and authors across the catalogue")
                        Spacer()
                        if isSearchingHardcover || remoteResultQuery != trimmedQuery {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Searching Hardcover")
                        }
                    }

                    if let remoteError, !isSearchingHardcover, remoteResultQuery == trimmedQuery {
                        errorCard(remoteError)
                    } else if remoteResultQuery == trimmedQuery, !remoteBooks.isEmpty {
                        remoteGrid(remoteBooks)
                    } else if remoteResultQuery == trimmedQuery, !isSearchingHardcover {
                        emptyMessage("No Hardcover results", symbol: "magnifyingglass",
                                     detail: "Try another title, author, or spelling.")
                    }
                }
            } else {
                accountPrompt
            }
        }
    }

    private var accountPrompt: some View {
        GlassCard {
            HStack(alignment: .center, spacing: 16) {
                Image(systemName: "globe.americas")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 42)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Explore more books with Hardcover")
                        .font(.headline)
                    Text("Connect your account to search beyond your library and see what's trending.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                SettingsLink {
                    Text("Connect…")
                }
                .buttonStyle(.glassProminent)
            }
        }
    }

    private func emptyMessage(_ title: String, symbol: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 16))
    }

    private func errorCard(_ message: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn't load Hardcover books").font(.callout.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Try Again") { retryCount += 1 }
                .buttonStyle(.glass)
        }
        .padding(17)
        .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 16))
    }

    private func localGrid(_ books: [LocalBook]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 188), spacing: 24, alignment: .top)],
                  alignment: .leading, spacing: 28) {
            ForEach(books) { book in
                LocalBookCell(book: book)
            }
        }
    }

    private func remoteGrid(_ books: [HCBook]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 188), spacing: 24, alignment: .top)],
                  alignment: .leading, spacing: 28) {
            ForEach(books) { book in
                HCBookCell(book: book) { selectedBook = book }
            }
        }
    }

    @MainActor
    private func loadHardcover(for requested: SearchRequest) async {
        guard requested.connected else {
            isSearchingHardcover = false
            isLoadingTrending = false
            remoteBooks = []
            remoteResultQuery = ""
            remoteError = nil
            return
        }

        remoteError = nil
        if requested.text.isEmpty {
            isSearchingHardcover = false
            remoteBooks = []
            remoteResultQuery = ""
            guard trendingBooks.isEmpty || requested.retryCount > 0 else {
                isLoadingTrending = false
                return
            }

            isLoadingTrending = true
            do {
                let books = try await hardcover.trending()
                guard !Task.isCancelled, request == requested else { return }
                trendingBooks = Array(books.prefix(16))
            } catch {
                guard !Task.isCancelled, request == requested else { return }
                remoteError = error.localizedDescription
            }
            if request == requested { isLoadingTrending = false }
        } else {
            isLoadingTrending = false
            isSearchingHardcover = true
            remoteResultQuery = ""
            remoteBooks = []

            do {
                try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
                let books = try await hardcover.search(requested.text)
                guard !Task.isCancelled, request == requested else { return }
                remoteBooks = books
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, request == requested else { return }
                remoteError = error.localizedDescription
            }

            if !Task.isCancelled, request == requested {
                remoteResultQuery = requested.text
                isSearchingHardcover = false
            }
        }
    }
}
