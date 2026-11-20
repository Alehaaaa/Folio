import SwiftUI

struct LibraryToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { NotificationCenter.default.post(name: .folioImport, object: nil) } label: {
                Label("Add to Library", systemImage: "plus")
            }
            .help("Add EPUB, PDF and other files")
        }
    }
}

enum LibrarySource: Hashable {
    case filter(LibraryFilter)
    case collection(UUID)
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case recent, title, author, progress
    var id: String { rawValue }
    var label: String {
        switch self {
        case .recent: "Recent"
        case .title: "Title"
        case .author: "Author"
        case .progress: "Progress"
        }
    }
}

struct LibraryGridView: View {
    var title: String
    var source: LibrarySource
    @Environment(LibraryStore.self) private var store
    @State private var search = ""
    @AppStorage("librarySort") private var sort: LibrarySort = .recent

    private var books: [LocalBook] {
        let base: [LocalBook]
        switch source {
        case .filter(let f): base = store.books(f, search: search)
        case .collection(let id): base = store.books(in: id, search: search)
        }
        switch sort {
        case .recent: return base.sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
        case .title: return base.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author: return base.sorted { $0.author.localizedStandardCompare($1.author) == .orderedAscending }
        case .progress: return base.sorted { $0.progress > $1.progress }
        }
    }

    var body: some View {
        let list = books
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.largeTitle.weight(.bold))
                    Text("\(list.count) item\(list.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                }
                if list.isEmpty {
                    GlassCard(padding: 34) {
                        VStack(spacing: 12) {
                            Image(systemName: "tray").font(.system(size: 40)).foregroundStyle(.secondary)
                            Text(search.isEmpty ? "Nothing here yet" : "No matches").font(.title3.weight(.semibold))
                            Text(emptyHint).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            if case .filter = source, search.isEmpty {
                                Button { NotificationCenter.default.post(name: .folioImport, object: nil) } label: { Label("Add to Library…", systemImage: "plus") }
                                    .buttonStyle(.glassProminent)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 26, alignment: .top)], alignment: .leading, spacing: 30) {
                        ForEach(list) { LocalBookCell(book: $0) }
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .searchable(text: $search, placement: .toolbar, prompt: "Search Library")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Sort", selection: $sort) {
                    ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .help("Sort By")
            }
            LibraryToolbar()
        }
    }

    private var emptyHint: String {
        switch source {
        case .collection: "Add books with a book's ⋯ menu, or drag them onto the collection in the sidebar."
        case .filter(.wantToRead): "Mark books as Want to Read from their ⋯ menu."
        case .filter(.finished): "Books you finish show up here."
        default: "Drag EPUB, PDF, text, Markdown or CBZ files into this window."
        }
    }
}

struct LocalBookCell: View {
    let book: LocalBook
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            book.cover
                .overlay(alignment: .bottomLeading) {
                    if book.format != .epub {
                        Text(book.format.label)
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .glassEffect(.regular, in: .capsule)
                            .padding(6)
                    }
                }
                .scaleEffect(hovering ? 1.03 : 1)
                .animation(.spring(duration: 0.25), value: hovering)
                .onHover { hovering = $0 }
                .onTapGesture { BookDetailsPresenter.showLocal(book.id) }
                .draggable(book.id.uuidString)
            Text(book.title).font(.callout.weight(.semibold)).lineLimit(2)
                .onTapGesture { BookDetailsPresenter.showLocal(book.id) }
            HStack(spacing: 4) {
                AuthorLinks(line: book.author, placeholder: book.format.label)
                Spacer(minLength: 2)
                BookActionsMenu(book: book, compact: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let s = book.series {
                SeriesLink(name: s, index: book.seriesIndex).font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if book.status == .finished {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if book.progress > 0.001 {
                    ProgressView(value: book.progress).controlSize(.mini).frame(maxWidth: 70)
                }
                Text(book.progressLabel).monospacedDigit()
                if book.hardcoverBookID != nil {
                    Image(systemName: "link").help("Linked to Hardcover")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .contextMenu { BookActions(book: book) }
    }
}

struct BookActionsMenu: View {
    let book: LocalBook
    var compact = false
    var body: some View {
        Menu { BookActions(book: book) } label: {
            if compact { Image(systemName: "ellipsis").frame(width: 18, height: 14) } else { Label("More", systemImage: "ellipsis") }
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .buttonStyle(.borderless)
    }
}

struct BookActions: View {
    let book: LocalBook
    @Environment(LibraryStore.self) private var store
    @Environment(HardcoverClient.self) private var hc
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show Details") { BookDetailsPresenter.showLocal(book.id) }
        Button("Read") { openWindow(id: "reader", value: book.id) }
        Divider()
        ForEach(ReadingStatus.allCases) { s in
            Button { store.setStatus(book.id, s, hardcover: hc) } label: {
                if book.status == s { Label(s == .none ? "Clear Status" : s.label, systemImage: "checkmark") } else { Text(s == .none ? "Clear Status" : (s == .finished ? "Mark as Finished" : "Mark as \(s.label)")) }
            }
        }
        Menu("Add to Collection") {
            ForEach(store.data.collections) { c in
                Button { store.toggle(book.id, in: c.id) } label: {
                    if book.collections.contains(c.id) { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                }
            }
            if store.data.collections.isEmpty { Text("Create a collection in the sidebar first") }
        }
        Divider()
        ForEach(Names.split(book.author).prefix(4), id: \.self) { n in
            Button("Go to \(n)") { Router.shared.open(.author(n)) }
        }
        if let s = book.series {
            Button("Go to Series “\(s)”") { Router.shared.open(.series(name: s, hardcoverID: nil)) }
        }
        Divider()
        Button("Reset Progress") { store.update(book.id) { $0.progress = 0; $0.position = ReadingPosition(); $0.lastOpenedAt = nil } }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL(book)]) }
        Divider()
        Button("Remove from Library", role: .destructive) { store.remove(book.id) }
    }
}

/// Library and Hardcover books use the same detail panel. Local entries expose
/// additional editing and EPUB metadata actions inside that shared presentation.
@MainActor
enum BookDetailsPresenter {
    static func showLocal(_ id: UUID) {
        guard LibraryStore.shared.book(id) != nil else { return }
        PopupCenter.shared.show(AnyView(HCBookDetail(localBookID: id))) {}
    }
}
