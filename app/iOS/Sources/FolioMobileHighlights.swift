import SwiftUI

/// Highlights, quotes and notes worth showing again: everything but bookmarks
/// and empty selections, newest first.
@MainActor
enum FolioHighlights {
    static func all(_ store: ReadingAnnotationsStore = .shared) -> [ReadingAnnotation] {
        store.entries
            .filter { $0.kind != .bookmark && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// One passage a day, the same all day, from books still in the library.
    static func ofTheDay(_ store: ReadingAnnotationsStore = .shared, library: LibraryStore) -> ReadingAnnotation? {
        let pool = all(store).filter { library.book($0.bookID) != nil && $0.text.count >= 40 && $0.text.count <= 420 }
        guard !pool.isEmpty else { return nil }
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        return pool[day % pool.count]
    }
}

// MARK: - Home card

/// A passage from the reader's own highlights, changing daily, as in Kindle's Daily Review.
struct FolioMobileHighlightOfTheDay: View {
    @Environment(LibraryStore.self) private var store
    @State private var annotations = ReadingAnnotationsStore.shared

    var body: some View {
        if let passage = FolioHighlights.ofTheDay(annotations, library: store),
           let book = store.book(passage.bookID) {
            NavigationLink {
                FolioMobileHighlightsView()
            } label: {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "quote.opening")
                        .font(.title3)
                        .foregroundStyle(FolioTheme.olive)
                        .accessibilityHidden(true)
                    Text(passage.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(.body, design: .serif))
                        .foregroundStyle(FolioTheme.ink)
                        .lineLimit(7)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(book.author.isEmpty ? book.title : "\(book.title) · \(book.author)")
                        .font(.footnote)
                        .foregroundStyle(FolioTheme.muted)
                        .lineLimit(1)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .folioCard()
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows all your highlights")
        }
    }
}

// MARK: - All highlights

/// Every highlight, quote and note, by book, searchable and shareable.
struct FolioMobileHighlightsView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(FolioMobileNavigation.self) private var navigation
    @State private var annotations = ReadingAnnotationsStore.shared
    @State private var search = ""

    private struct BookGroup: Identifiable {
        let book: LocalBook
        let items: [ReadingAnnotation]
        var id: UUID { book.id }
    }

    private var groups: [BookGroup] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let matching = FolioHighlights.all(annotations).filter { item in
            query.isEmpty || item.text.localizedCaseInsensitiveContains(query)
                || item.note.localizedCaseInsensitiveContains(query)
                || (store.book(item.bookID)?.title.localizedCaseInsensitiveContains(query) ?? false)
        }
        var order: [UUID] = []
        var byBook: [UUID: [ReadingAnnotation]] = [:]
        for item in matching {
            if byBook[item.bookID] == nil { order.append(item.bookID) }
            byBook[item.bookID, default: []].append(item)
        }
        return order.compactMap { id in store.book(id).map { BookGroup(book: $0, items: byBook[id] ?? []) } }
    }

    var body: some View {
        let groups = groups
        List {
            FolioSearchField(text: $search, prompt: "Search highlights")
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 20))
            if groups.isEmpty {
                ContentUnavailableView {
                    Label(search.isEmpty ? "No Highlights Yet" : "No Matches", systemImage: "highlighter")
                } description: {
                    Text(search.isEmpty ? "Select text while reading to highlight it or save a quote."
                                        : "Try other words.")
                }
                .listRowBackground(Color.clear)
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in
                        row(item, book: group.book)
                    }
                } header: {
                    Button {
                        navigation.pendingRead = group.book.id
                    } label: {
                        HStack(spacing: 6) {
                            Text(group.book.title)
                                .font(.system(.subheadline, design: .serif).weight(.semibold))
                                .foregroundStyle(FolioTheme.ink)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(FolioTheme.muted)
                        }
                    }
                    .buttonStyle(.plain)
                    .textCase(nil)
                    .accessibilityHint("Opens the book")
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("Highlights")
        .folioScreen()
        .folioPageHeader("Highlights")
    }

    private func row(_ item: ReadingAnnotation, book: LocalBook) -> some View {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.system(.body, design: .serif))
                .foregroundStyle(FolioTheme.ink)
            if !item.note.isEmpty {
                Text(item.note)
                    .font(.subheadline)
                    .foregroundStyle(FolioTheme.muted)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(FolioTheme.surface)
        .contextMenu {
            ShareLink(item: "“\(text)”\n- \(book.title)\(book.author.isEmpty ? "" : ", \(book.author)")") {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Button {
                UIPasteboard.general.string = text
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button {
                navigation.pendingRead = book.id
            } label: {
                Label("Open Book", systemImage: "book")
            }
        }
        .swipeActions {
            ShareLink(item: "“\(text)”\n- \(book.title)") {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .tint(FolioTheme.olive)
        }
    }
}
