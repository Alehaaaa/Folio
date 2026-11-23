import SwiftUI

/// Hardcover and Goodreads reading shelves are merged by the book's
/// normalized title and author, like the macOS My Shelves section.
struct FolioMobileShelfEntry: Identifiable {
    var id: String
    var title: String
    var author: String
    var cover: URL?
    var hardcover: HCUserBook?
    var goodreads: TrackedBook?

    static func merge(hardcover hcItems: [HCUserBook], goodreads tracked: [TrackedBook]) -> [FolioMobileShelfEntry] {
        var books: [FolioMobileShelfEntry] = []
        var index: [String: Int] = [:]
        var byHardcoverID: [Int: Int] = [:]
        for item in hcItems {
            let key = BookMatch.key(author: item.book.authors, title: item.book.title)
            index[key] = books.count
            byHardcoverID[item.book.id] = books.count
            books.append(.init(id: "hc-\(item.id)", title: item.book.title, author: item.book.authors,
                               cover: item.book.imageURL, hardcover: item, goodreads: nil))
        }
        for book in tracked {
            let key = BookMatch.key(author: book.author, title: book.title)
            if let i = book.hardcoverBookID.flatMap({ byHardcoverID[$0] }) ?? index[key] {
                books[i].goodreads = book
                if books[i].cover == nil { books[i].cover = book.coverURL.flatMap(URL.init(string:)) }
            } else {
                index[key] = books.count
                books.append(.init(id: "gr-\(book.id)", title: book.title, author: book.author,
                                   cover: book.coverURL.flatMap(URL.init(string:)),
                                   hardcover: nil, goodreads: book))
            }
        }
        return books
    }
}

extension HCStatus {
    /// The matching Goodreads exclusive shelf; Goodreads has no Paused shelf.
    var goodreadsShelf: GRShelf? {
        switch self {
        case .wantToRead: .wantToRead
        case .reading: .currentlyReading
        case .read: .read
        case .paused: nil
        case .dnf: .dnf
        }
    }
}

/// The reading shelves, shown inside Library rather than as a screen of their own.
/// The surrounding Library view owns the scroll view, title and search field.
struct FolioMobileShelvesView: View {
    let search: String
    @Environment(LibraryStore.self) private var library
    @Environment(HardcoverClient.self) private var hardcover
    @Environment(FolioMobileNavigation.self) private var navigation
    @State private var goodreads = GoodreadsClient.shared
    @State private var source = FolioMobileShelfSource.all
    @State private var hcItems: [HCUserBook] = []
    @State private var loading = false
    @State private var copying = false
    @State private var selectedBook: HCBook?
    @State private var selectedTracked: TrackedBook?
    @State private var notice: String?

    private var selectedStatus: HCStatus { navigation.shelfStatus }
    private var grStatus: GRShelf? { selectedStatus.goodreadsShelf }

    private var merged: [FolioMobileShelfEntry] {
        FolioMobileShelfEntry.merge(hardcover: hcItems, goodreads: grStatus.map { library.tracked($0) } ?? [])
    }

    private var visible: [FolioMobileShelfEntry] {
        merged.filter { entry in
            switch source {
            case .all: true
            case .hardcover: entry.hardcover != nil
            case .goodreads: entry.goodreads != nil
            }
        }.filter {
            search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)
                || $0.author.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        @Bindable var navigation = navigation
        LazyVStack(alignment: .leading, spacing: 18) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 9) {
                    ForEach(HCStatus.allCases) { status in
                        Button {
                            navigation.shelfStatus = status
                        } label: {
                            Label(status.shortLabel, systemImage: status.symbol)
                        }
                        .folioGlassPill(prominent: selectedStatus == status)
                    }
                }
                .padding(.horizontal, 16)
            }
            if hardcover.isConnected && (goodreads.isLinked || !library.data.tracked.isEmpty) {
                Picker("Source", selection: $source) {
                    ForEach(FolioMobileShelfSource.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
            }
            HStack(spacing: 10) {
                Text("\(visible.count) books")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if loading { ProgressView() }
                Button {
                    Task { await refresh(includeGoodreads: true) }
                } label: {
                    Label("Refresh Shelves", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 30, minHeight: 30)
                }
                .folioGlassPill()
                .disabled(loading || !goodreads.loading.isEmpty)
                if hardcover.isConnected, grStatus != nil, !library.data.tracked.isEmpty {
                    Menu {
                        Button {
                            Task { await copyGoodreads() }
                        } label: {
                            Label("Copy Goodreads to Hardcover", systemImage: "arrow.up.forward.app")
                        }
                        .disabled(copying)
                        NavigationLink {
                            FolioMobileGoodreadsSettings()
                        } label: {
                            Label("Import & Export CSV", systemImage: "square.and.arrow.up.on.square")
                        }
                    } label: {
                        Label("Shelf Options", systemImage: "ellipsis")
                            .labelStyle(.iconOnly)
                            .frame(minWidth: 30, minHeight: 30)
                    }
                    .folioGlassPill()
                }
            }
            .padding(.horizontal, 18)
            if !hardcover.isConnected && !goodreads.isLinked && library.data.tracked.isEmpty {
                ContentUnavailableView {
                    Label("Connect Your Reading Shelves", systemImage: "books.vertical")
                } description: {
                    Text("Connect Hardcover or Goodreads in Settings to bring in your reading lists.")
                }
                .frame(maxWidth: .infinity)
            } else if visible.isEmpty && !loading {
                ContentUnavailableView("No Books Yet", systemImage: "book.closed",
                                       description: Text("No books match this shelf and filter."))
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { entry in
                        Button {
                            if let hardcover = entry.hardcover { selectedBook = hardcover.book }
                            else { selectedTracked = entry.goodreads }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                AsyncImage(url: entry.cover) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    FolioClothCover(title: entry.title, compact: true)
                                }
                                .frame(width: 65, height: 93)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(entry.title).font(.folioDisplay(.headline)).foregroundStyle(FolioTheme.ink)
                                        .lineLimit(2).multilineTextAlignment(.leading)
                                    Text(entry.author).font(.subheadline)
                                        .foregroundStyle(.secondary).lineLimit(2)
                                    HStack(spacing: 8) {
                                        if entry.hardcover != nil {
                                            Label("Hardcover", systemImage: "book")
                                        }
                                        if entry.goodreads != nil {
                                            Label("Goodreads", systemImage: "bookmark")
                                        }
                                    }
                                    .font(.caption2).foregroundStyle(.secondary)
                                    if let ub = entry.hardcover, let pages = ub.book.pages,
                                       let read = ub.progressPages, pages > 0 {
                                        ProgressView(value: Double(read), total: Double(pages))
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 9)
                            .padding(.horizontal, 17)
                        }
                        .buttonStyle(.plain)
                        .folioShelfEntryContextMenu(entry) { Task { await refresh(includeGoodreads: false) } }
                        if entry.id != visible.last?.id {
                            Divider().overlay(FolioTheme.line).padding(.leading, 94)
                        }
                    }
                }
                .padding(.vertical, 6)
                .folioCard(cornerRadius: 22)
                .padding(.horizontal, 16)
            }
            if let notice {
                Text(notice).font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.bottom, 14)
        .task(id: selectedStatus.rawValue) { await refresh(includeGoodreads: false) }
        .sheet(item: $selectedBook) { book in
            NavigationStack { FolioMobileBookDetail(book: book).folioDetailDestinations() }
        }
        .sheet(item: $selectedTracked) { book in
            FolioMobileTrackedBookDetail(book: book)
        }
    }

    private func refresh(includeGoodreads: Bool) async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        if hardcover.isConnected {
            do {
                hcItems = try await hardcover.shelf(selectedStatus)
                notice = nil
            } catch {
                notice = error.localizedDescription
            }
        } else {
            hcItems = []
        }
        if goodreads.isLinked && (includeGoodreads || goodreads.lastSync == nil) {
            await goodreads.syncAll(into: library)
        }
    }

    private func copyGoodreads() async {
        guard !copying else { return }
        copying = true
        let results = await library.sendTrackedToHardcover(hardcover, shelf: grStatus)
        notice = "Copied \(results.sent) books; \(results.missed) could not be matched."
        copying = false
        await refresh(includeGoodreads: false)
    }
}

private enum FolioMobileShelfSource: String, CaseIterable, Identifiable {
    case all = "All", hardcover = "Hardcover", goodreads = "Goodreads"
    var id: String { rawValue }
}

struct FolioMobileTrackedBookDetail: View {
    let book: TrackedBook
    @Environment(LibraryStore.self) private var library
    @Environment(FolioMobileNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @State private var findManually = false
    @State private var downloadNotice: String?

    private var local: LocalBook? {
        library.localCopy(author: book.author, title: book.title)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    AsyncImage(url: book.coverURL.flatMap(URL.init(string:))) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Image(systemName: "book.closed.fill")
                            .font(.system(size: 62)).foregroundStyle(.secondary)
                    }
                    .frame(width: 175, height: 230)
                    Text(book.title).font(.folioDisplay(.title)).multilineTextAlignment(.center)
                    Text(book.author).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Label(book.status?.label ?? book.shelf, systemImage: book.status?.symbol ?? "bookmark")
                        .foregroundStyle(.secondary)
                    if let local {
                        FolioGlassButton(title: "Read", systemImage: "book.fill",
                                         prominent: true, fullWidth: true) {
                            dismiss()
                            navigation.read(local.id)
                        }
                    } else {
                        FolioGlassButton(title: "Find Source", systemImage: "magnifyingglass",
                                         prominent: true, fullWidth: true) {
                            FolioMobileDownloadNotice.enqueue(
                                title: book.title, author: book.author,
                                hardcoverBookID: book.hardcoverBookID,
                                hardcoverPages: book.pages,
                                cover: book.coverURL.flatMap(URL.init(string:))
                            )
                            downloadNotice = "Added to background Downloads"
                        }
                        if let downloadNotice {
                            Label(downloadNotice, systemImage: "checkmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        FolioGlassButton(title: "Choose a Source", systemImage: "list.bullet", fullWidth: true) {
                            findManually = true
                        }
                    }
                    if let average = book.averageRating {
                        LabeledContent("Goodreads Rating", value: String(format: "%.2f", average))
                    }
                    if book.rating > 0 {
                        LabeledContent("Your Rating", value: String(book.rating))
                    }
                    if let year = book.year { LabeledContent("Year", value: String(year)) }
                    if let pages = book.pages { LabeledContent("Pages", value: String(pages)) }
                    if let link = book.link, let url = URL(string: link) {
                        Link(destination: url) {
                            Label("Open on Goodreads", systemImage: "safari")
                                .frame(maxWidth: .infinity, minHeight: 42)
                        }
                        .folioGlassPill()
                    }
                }
                .padding(22)
            }
            .navigationTitle("Book Details")
            .folioScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.folioGlassPill()
                }
            }
            .sheet(isPresented: $findManually) {
                FolioMobileFindSourceView(
                    title: book.title, author: book.author,
                    hardcoverBookID: book.hardcoverBookID,
                    hardcoverPages: book.pages,
                    cover: book.coverURL.flatMap(URL.init(string:))
                )
            }
        }
    }
}
