import SwiftUI

/// Long-press menu for a book in the library: read, change status, file it in
/// collections, edit details, share the file, or remove it.
private struct FolioMobileBookContextMenu: ViewModifier {
    let bookID: UUID
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
                    image: library.book(bookID).flatMap { library.coverURL($0) }
                        .flatMap { UIImage(contentsOfFile: $0.path) },
                    title: library.book(bookID)?.title ?? "",
                    author: library.book(bookID)?.author ?? ""
                )
            }
            .sheet(isPresented: $editing) {
                FolioMobileEditBook(bookID: bookID)
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

/// Environment-free preview for the book context menu.
private struct FolioMobileBookMenuPreview: View {
    let image: UIImage?
    let title: String
    let author: String

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.indigo.opacity(0.78)
                    VStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 18, weight: .bold, design: .serif))
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
        .frame(width: 220, height: 320)
        .clipped()
    }
}

/// Long-press menu for a Hardcover or Goodreads shelf entry.
private struct FolioMobileShelfEntryContextMenu: ViewModifier {
    let entry: FolioMobileShelfEntry
    var changed: () -> Void = {}
    @Environment(LibraryStore.self) private var library
    @Environment(HardcoverClient.self) private var hardcover
    @Environment(FolioMobileNavigation.self) private var navigation

    private var local: LocalBook? {
        if let id = entry.hardcover?.book.id,
           let linked = library.books.first(where: { $0.hardcoverBookID == id }) { return linked }
        return library.localCopy(author: entry.author, title: entry.title)
    }

    func body(content: Content) -> some View {
        content.contextMenu {
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

            if hardcover.isConnected,
               let bookID = entry.hardcover?.book.id ?? entry.goodreads?.hardcoverBookID {
                Menu {
                    ForEach(HCStatus.allCases) { status in
                        Button {
                            Task {
                                _ = await hardcover.setStatus(bookID: bookID, status: status)
                                changed()
                            }
                        } label: {
                            Label(status.label,
                                  systemImage: entry.hardcover?.status == status ? "checkmark" : status.symbol)
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
}

extension View {
    func folioBookContextMenu(_ book: LocalBook) -> some View {
        modifier(FolioMobileBookContextMenu(bookID: book.id))
    }

    func folioShelfEntryContextMenu(_ entry: FolioMobileShelfEntry, changed: @escaping () -> Void = {}) -> some View {
        modifier(FolioMobileShelfEntryContextMenu(entry: entry, changed: changed))
    }
}
