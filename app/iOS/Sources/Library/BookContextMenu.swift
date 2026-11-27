import SwiftUI

/// Long-press menu for a book in the library: read, change status, file it in
/// collections, edit details, share the file, or remove it.
private struct FolioMobileBookContextMenu<Extra: View>: ViewModifier {
    let bookID: UUID
    /// Extra actions from the screen showing the book, such as the Home nook.
    var extra: Extra
    @Environment(LibraryStore.self) private var library
    @Environment(HardcoverClient.self) private var hardcover
    @Environment(FolioMobileNavigation.self) private var navigation
    @State private var editing = false
    @State private var removing = false
    @State private var resetting = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if let book = library.book(bookID) {
                    menu(book)
                }
            } preview: {
                // The preview is hosted outside this view hierarchy, so it must not read
                // @Environment objects (FolioMobileCover reads LibraryStore and crashed
                // there). Build it only from values resolved here.
                FolioMobileBookMenuPreview(
                    // The tile has already decoded its cover; never read the file here,
                    // since this runs each time a tile redraws.
                    image: library.book(bookID).flatMap { library.coverURL($0) }
                        .flatMap { FolioImageCache.shared.localCoverInMemory($0) },
                    local: library.book(bookID).flatMap { library.coverURL($0) },
                    title: library.book(bookID)?.title ?? "",
                    author: library.book(bookID)?.author ?? ""
                )
            }
            .sheet(isPresented: $editing) {
                FolioMobileEditDetails(bookID: bookID)
            }
            .confirmationDialog("Remove this book and its imported file?",
                                isPresented: $removing, titleVisibility: .visible) {
                Button("Remove Book", role: .destructive) { library.remove(bookID) }
            }
            .confirmationDialog("Reset your reading progress for this book?",
                                isPresented: $resetting, titleVisibility: .visible) {
                Button("Reset Progress", role: .destructive) {
                    library.update(bookID) {
                        $0.progress = 0
                        $0.position = ReadingPosition()
                        $0.lastOpenedAt = nil
                    }
                }
            }
    }

    @ViewBuilder
    private func menu(_ book: LocalBook) -> some View {
        Button {
            navigation.read(book.id)
        } label: {
            Label(book.progress > 0 && book.status != .finished ? "Continue Reading" : "Read",
                  systemImage: "book.fill")
        }

        extra

        Menu {
            ForEach(ReadingStatus.allCases) { status in
                Button {
                    library.setStatus(book.id, status, hardcover: hardcover)
                } label: {
                    Label(status == .none ? "Not Started" : status.label,
                          systemImage: book.status == status ? "checkmark" : status.symbol)
                }
            }
        } label: {
            Label("Status", systemImage: book.status.symbol)
        }

        if !library.data.collections.isEmpty {
            Menu {
                ForEach(library.data.collections) { collection in
                    Button {
                        library.toggle(book.id, in: collection.id)
                    } label: {
                        Label(collection.name,
                              systemImage: book.collections.contains(collection.id) ? "checkmark.circle.fill" : "circle")
                    }
                }
            } label: {
                Label("Collections", systemImage: "folder")
            }
        }

        Divider()

        Button { editing = true } label: {
            Label("Edit Details", systemImage: "square.and.pencil")
        }
        ShareLink(item: library.fileURL(book)) {
            Label("Share File", systemImage: "square.and.arrow.up")
        }
        if book.progress > 0 || book.lastOpenedAt != nil {
            Button { resetting = true } label: {
                Label("Reset Progress", systemImage: "arrow.counterclockwise")
            }
        }

        Divider()

        Button(role: .destructive) { removing = true } label: {
            Label("Remove from Library", systemImage: "trash")
        }
    }
}

/// Environment-free preview for a book's long-press menu: the cover alone,
/// at its own shape, so the system lifts and enlarges it while the screen
/// behind blurs and dims, with no box around it.
struct FolioMobileBookMenuPreview: View {
    let initial: UIImage?
    var local: URL? = nil
    var remote: URL? = nil
    let title: String
    let author: String
    @State private var loaded: UIImage?

    init(image: UIImage?, local: URL? = nil, remote: URL? = nil, title: String, author: String) {
        initial = image
        self.local = local
        self.remote = remote
        self.title = title
        self.author = author
    }

    private var image: UIImage? { initial ?? loaded }

    private static let width: CGFloat = 240

    private var aspect: CGFloat {
        guard let image, image.size.width > 0, image.size.height > 0 else { return 0.69 }
        // Keep odd scans within a book-like shape.
        return min(1.0, max(0.5, image.size.width / image.size.height))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(red: 0.25, green: 0.34, blue: 0.25)
                    VStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 20, weight: .semibold, design: .serif))
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                        if !author.isEmpty {
                            Text(author)
                                .font(.system(size: 13, design: .serif))
                                .lineLimit(2)
                                .opacity(0.8)
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(18)
                }
            }
        }
        .frame(width: Self.width, height: Self.width / aspect)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task {
            // Covers not in memory yet are read here, off the main thread.
            guard initial == nil else { return }
            if let local, let image = await FolioImageCache.shared.loadLocalCover(local) {
                loaded = image
            } else if let remote, let image = await FolioImageCache.shared.load(remote) {
                loaded = image
            }
        }
    }
}

/// Long-press menu for a Hardcover or Goodreads shelf entry.
private struct FolioMobileShelfEntryContextMenu<Extra: View>: ViewModifier {
    let entry: FolioMobileShelfEntry
    var changed: () -> Void = {}
    var extra: Extra
    /// Attached to a cover the system can lift as is, with no separate preview.
    var lifted = false
    @Environment(LibraryStore.self) private var library
    @Environment(HardcoverClient.self) private var hardcover
    @Environment(FolioMobileNavigation.self) private var navigation

    private var local: LocalBook? {
        if let book = entry.hardcover?.book, let copy = FolioBookOverrides.shared.libraryCopy(of: book) { return copy }
        if let id = entry.goodreads?.hardcoverBookID,
           let linked = library.books.first(where: { $0.hardcoverBookID == id }) { return linked }
        return library.localCopy(author: entry.author, title: entry.title)
    }

    func body(content: Content) -> some View {
        if lifted {
            // Shown on the cover itself: the system lifts it as it is.
            content.contextMenu { menu }
        } else {
            content.contextMenu {
                menu
            } preview: {
                FolioMobileBookMenuPreview(image: entry.cover.flatMap { FolioImageCache.shared.cached($0) },
                                           remote: entry.cover, title: entry.title, author: entry.author)
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
            if let local {
                Button { navigation.read(local.id) } label: {
                    Label("Read", systemImage: "book.fill")
                }
            } else {
                Button {
                    FolioMobileDownloadNotice.enqueue(
                        title: entry.title, author: entry.author,
                        hardcoverBookID: entry.hardcover?.book.id ?? entry.goodreads?.hardcoverBookID,
                        hardcoverPages: entry.hardcover?.book.pages ?? entry.goodreads?.pages,
                        cover: entry.cover
                    )
                } label: {
                    Label("Find Source", systemImage: "arrow.down.circle")
                }
            }

            extra

            if canMove {
                Menu {
                    ForEach(HCStatus.allCases) { status in
                        Button {
                            move(to: status)
                        } label: {
                            Label(status.label,
                                  systemImage: (entry.hardcover?.status ?? entry.goodreads?.status) == status
                                      ? "checkmark" : status.symbol)
                        }
                    }
                } label: {
                    Label("Move to Shelf", systemImage: "books.vertical")
                }
            }

            if let url = entry.hardcover?.book.webURL {
                Divider()
                Link(destination: url) { Label("Open on Hardcover", systemImage: "arrow.up.right.square") }
            }
            if let link = entry.goodreads?.link, let url = URL(string: link) {
                Link(destination: url) { Label("Open on Goodreads", systemImage: "safari") }
            }
    }
}

extension FolioMobileShelfEntryContextMenu {
    private var hardcoverID: Int? { entry.hardcover?.book.id ?? entry.goodreads?.hardcoverBookID }

    var canMove: Bool {
        (hardcover.isConnected && hardcoverID != nil) || FolioShelfSync.shared.isConnected(.goodreads)
    }

    /// Hardcover and every synced service (Goodreads too) take the new shelf.
    func move(to status: HCStatus) {
        let book = entry.hardcover?.book ?? entry.goodreads?.folioBook
            ?? HCBook(id: 0, title: entry.title, authors: entry.author)
        FolioReadBooks.shared.set(book, status: status)
        Task {
            if hardcover.isConnected, let id = hardcoverID {
                _ = await hardcover.setStatus(bookID: id, status: status)
            }
            await FolioShelfSync.shared.sync(status, for: book)
            changed()
        }
    }
}

/// Long-press menu for a book from Hardcover shown in a row (For you,
/// Because you read, an author's books...).
private struct FolioMobileRemoteBookContextMenu: ViewModifier {
    let book: HCBook
    var lifted = false
    @Environment(LibraryStore.self) private var library
    @Environment(HardcoverClient.self) private var hardcover
    @Environment(FolioMobileNavigation.self) private var navigation
    @State private var nook = FolioNookStore.shared

    private var local: LocalBook? {
        FolioBookOverrides.shared.libraryCopy(of: book)
    }

    func body(content: Content) -> some View {
        if lifted {
            content.contextMenu { menu }
        } else {
            content.contextMenu {
                menu
            } preview: {
                let shown = FolioBookOverrides.shared.apply(book)
                FolioMobileBookMenuPreview(image: shown.imageURL.flatMap { FolioImageCache.shared.cached($0) },
                                           remote: shown.imageURL, title: shown.title, author: shown.authors)
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
            if let local {
                Button { navigation.read(local.id) } label: {
                    Label("Read", systemImage: "book.fill")
                }
            } else {
                Button {
                    FolioMobileDownloadNotice.enqueue(
                        title: book.title, author: book.authors,
                        hardcoverBookID: book.id > 0 ? book.id : nil,
                        hardcoverPages: book.pages, cover: book.imageURL
                    )
                } label: {
                    Label("Find Source", systemImage: "arrow.down.circle")
                }
            }

            if !nook.pinned.contains(where: { $0.id == book.id && $0.title == book.title }) {
                Button {
                    withAnimation(.snappy) {
                        nook.pin(book, keys: FolioNookShelf.keys(for: book), after: nook.order.last ?? "")
                    }
                } label: {
                    Label("Put on Home Shelf", systemImage: "books.vertical")
                }
            }

            if hardcover.isConnected, book.id > 0 {
                Menu {
                    ForEach(HCStatus.allCases) { status in
                        Button {
                            FolioReadBooks.shared.set(book, status: status)
                            Task {
                                _ = await hardcover.setStatus(bookID: book.id, status: status)
                                await FolioShelfSync.shared.sync(status, for: book)
                            }
                        } label: {
                            Label(status.label, systemImage: status.symbol)
                        }
                    }
                } label: {
                    Label("Add to Shelf", systemImage: "bookmark")
                }
            }

            if let url = book.webURL {
                Divider()
                Link(destination: url) { Label("Open on Hardcover", systemImage: "arrow.up.right.square") }
            }
    }
}

extension View {
    /// The long-press menu for a Hardcover book in a row.
    func folioRemoteBookContextMenu(_ book: HCBook, lifted: Bool = false) -> some View {
        modifier(FolioMobileRemoteBookContextMenu(book: book, lifted: lifted))
    }

    /// A shelf entry's menu on a cover the system lifts as it is.
    func folioShelfEntryCoverMenu(_ entry: FolioMobileShelfEntry, changed: @escaping () -> Void = {}) -> some View {
        modifier(FolioMobileShelfEntryContextMenu(entry: entry, changed: changed, extra: EmptyView(), lifted: true))
    }

    func folioBookContextMenu(_ book: LocalBook) -> some View {
        modifier(FolioMobileBookContextMenu(bookID: book.id, extra: EmptyView()))
    }

    func folioShelfEntryContextMenu(_ entry: FolioMobileShelfEntry, changed: @escaping () -> Void = {}) -> some View {
        modifier(FolioMobileShelfEntryContextMenu(entry: entry, changed: changed, extra: EmptyView()))
    }

    /// The long-press menu for a book in the Home nook: the book's own actions
    /// plus progress, finishing, moving and hiding it from the nook.
    func folioNookMenu(_ item: FolioNookItem) -> some View {
        modifier(FolioNookMenu(item: item))
    }
}

/// Long-press menu for a book standing in the Home nook.
private struct FolioNookMenu: ViewModifier {
    let item: FolioNookItem
    @Environment(LibraryStore.self) private var library
    @Environment(HardcoverClient.self) private var hardcover
    @State private var updating = false
    @State private var pageText = ""

    func body(content: Content) -> some View {
        Group {
            if let id = item.localID, library.book(id) != nil {
                content.modifier(FolioMobileBookContextMenu(bookID: id, extra: section))
            } else if let entry = item.entry {
                content.modifier(FolioMobileShelfEntryContextMenu(entry: entry, extra: section))
            } else {
                content.contextMenu { section } preview: {
                    FolioMobileBookMenuPreview(
                        image: item.remoteCover.flatMap { FolioImageCache.shared.cached($0) },
                        local: item.localCover, remote: item.remoteCover,
                        title: item.title, author: item.author)
                }
            }
        }
        .alert("Update Progress", isPresented: $updating) {
            TextField("Page", text: $pageText)
                .keyboardType(.numberPad)
            Button("Save") { saveProgress() }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let pages = item.pages {
                Text("Which page are you on? This edition has \(pages) pages.")
            } else {
                Text("Which page are you on?")
            }
        }
    }

    /// Hardcover keeps the progress of books read outside Folio.
    private var canUpdateProgress: Bool {
        item.localID == nil && hardcover.isConnected && (item.hardcoverBookID ?? 0) > 0
    }

    private var canFinish: Bool {
        item.localID != nil || (hardcover.isConnected && (item.hardcoverBookID ?? 0) > 0)
    }

    @ViewBuilder
    private var section: some View {
        Section(item.progressDetail ?? "On your shelf") {
            if canUpdateProgress {
                Button {
                    pageText = item.pagesRead.map(String.init) ?? ""
                    updating = true
                } label: {
                    Label("Update Progress…", systemImage: "bookmark")
                }
            }
            if item.reading && canFinish {
                Button(action: finish) {
                    Label("Mark as Finished", systemImage: "checkmark.circle")
                }
            }
            Menu {
                Button {
                    withAnimation(.snappy) { FolioNookStore.shared.moveToStart(item.id) }
                } label: {
                    Label("Move to Start", systemImage: "arrow.left.to.line")
                }
                Button {
                    withAnimation(.snappy) { FolioNookStore.shared.moveToEnd(item.id) }
                } label: {
                    Label("Move to End", systemImage: "arrow.right.to.line")
                }
            } label: {
                Label("Move on Shelf", systemImage: "arrow.left.arrow.right")
            }
            Button {
                withAnimation(.snappy) { FolioNookStore.shared.hide(item) }
            } label: {
                // A book put here by hand just comes off again; others are hidden.
                if item.pinned && !item.reading {
                    Label("Remove from Nook", systemImage: "minus.circle")
                } else {
                    Label("Hide from Nook", systemImage: "eye.slash")
                }
            }
        }
    }

    private func saveProgress() {
        guard let page = Int(pageText.trimmingCharacters(in: .whitespaces)), page >= 0,
              let bookID = item.hardcoverBookID else { return }
        Task { await hardcover.setProgress(bookID: bookID, pages: page) }
    }

    private func finish() {
        if let id = item.localID {
            library.setStatus(id, .finished, hardcover: hardcover)
        } else if let bookID = item.hardcoverBookID, let book = item.remoteBook {
            FolioReadBooks.shared.set(book, read: true)
            Task {
                _ = await hardcover.setStatus(bookID: bookID, status: .read)
                await FolioShelfSync.shared.sync(.read, for: book)
            }
        }
    }
}
