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

    /// Entries show your own edition (your library copy's title and cover,
    /// your edits) while matching between services uses the work's title.
    @MainActor
    static func merge(hardcover hcItems: [HCUserBook], goodreads tracked: [TrackedBook]) -> [FolioMobileShelfEntry] {
        var books: [FolioMobileShelfEntry] = []
        var index: [String: Int] = [:]
        var byHardcoverID: [Int: Int] = [:]
        for item in hcItems {
            let key = BookMatch.key(author: item.book.authors, title: item.book.title)
            index[key] = books.count
            byHardcoverID[item.book.id] = books.count
            let shown = FolioBookOverrides.shared.apply(item.book)
            books.append(.init(id: "hc-\(item.id)", title: shown.title, author: shown.authors,
                               cover: shown.imageURL, hardcover: item, goodreads: nil))
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
    @State private var loadedStatus: HCStatus?
    @State private var loading = false
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
            // With nothing connected there is nothing to count or refresh.
            if hardcover.isConnected || goodreads.isLinked || !library.data.tracked.isEmpty {
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
                }
                .padding(.horizontal, 18)
            }
            if !hardcover.isConnected && !goodreads.isLinked && library.data.tracked.isEmpty {
                ContentUnavailableView {
                    Label("Connect Your Reading Shelves", systemImage: "books.vertical")
                } description: {
                    Text("Connect Hardcover or Goodreads in Settings to bring in your reading lists.")
                } actions: {
                    Button("Open Settings") { navigation.openSettings() }
                        .folioGlassPill(prominent: true)
                }
                .frame(maxWidth: .infinity)
            } else if visible.isEmpty && !loading {
                ContentUnavailableView("No Books Yet", systemImage: "book.closed",
                                       description: Text("No books match this shelf and filter."))
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(visible) { entry in
                        NavigationLink(value: entry.hardcover?.book ?? entry.goodreads?.folioBook
                                       ?? HCBook(id: 0, title: entry.title, authors: entry.author, imageURL: entry.cover)) {
                            HStack(alignment: .top, spacing: 12) {
                                FolioCachedImage(url: entry.cover) {
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
        .task(id: "\(selectedStatus.rawValue)-\(hardcover.revision)") { await refresh(includeGoodreads: false) }
    }

    private func refresh(includeGoodreads: Bool) async {
        // Switching shelves while one loads must not show the previous shelf's books.
        let status = selectedStatus
        if loadedStatus != status { hcItems = [] }
        loading = true
        defer { if status == selectedStatus { loading = false } }
        if hardcover.isConnected {
            do {
                let items = try await hardcover.shelf(status)
                guard status == selectedStatus else { return }
                hcItems = items
                loadedStatus = status
                notice = nil
            } catch {
                guard status == selectedStatus, !Task.isCancelled else { return }
                notice = error.localizedDescription
            }
        } else {
            hcItems = []
        }
        if goodreads.isLinked && (includeGoodreads || goodreads.lastSync == nil) {
            await goodreads.syncAll(into: library)
        }
    }

}

private enum FolioMobileShelfSource: String, CaseIterable, Identifiable {
    case all = "All", hardcover = "Hardcover", goodreads = "Goodreads"
    var id: String { rawValue }
}
