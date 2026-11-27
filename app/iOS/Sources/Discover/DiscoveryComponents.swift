import SwiftUI

/// A reusable, cover-first Hardcover tile for Discover and Home.
/// Navigation uses the existing HCBook destination provided by the parent NavigationStack.
struct FolioMobileRemoteBookTile: View {
    private let original: HCBook
    var width: CGFloat? = nil
    /// The reading-shelf entry the tile stands for, whose menu it shows.
    var entry: FolioMobileShelfEntry? = nil
    var changed: () -> Void = {}
    @State private var overrides = FolioBookOverrides.shared

    init(book: HCBook, width: CGFloat? = nil, entry: FolioMobileShelfEntry? = nil, changed: @escaping () -> Void = {}) {
        original = book
        self.width = width
        self.entry = entry
        self.changed = changed
    }

    /// The book with the reader's own edits; navigation keeps the Hardcover record.
    private var book: HCBook { overrides.apply(original) }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationLink(value: original) {
            VStack(alignment: .leading, spacing: 7) {
                GeometryReader { geometry in
                    FolioCachedImage(url: book.imageURL) {
                        FolioClothCover(title: book.title, compact: true)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                }
                .aspectRatio(0.69, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(.primary.opacity(0.07), lineWidth: 0.7)
                }
                // A long press lifts the cover alone, as it is, over the blurred screen.
                .modifier(FolioCoverMenuShape())
                .modifier(FolioRemoteTileMenu(book: original, entry: entry, changed: changed))

                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(.system(.body, design: .serif))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(book.authors.isEmpty ? "Unknown author" : book.authors)
                        .font(.subheadline)
                        .foregroundStyle(FolioTheme.muted)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(width: width, alignment: .topLeading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // On Home, it can be dragged onto the shelf.
        .modifier(FolioNookDragSource(book: original))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.title), \(book.authors.isEmpty ? "unknown author" : book.authors)")
        .accessibilityHint("Open book details")
    }
}

/// Adaptive columns on phones and tablets, with wider tiles for accessibility text sizes.
struct FolioMobileRemoteBookGridSection: View {
    let title: String
    let books: [HCBook]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: [GridItem] {
        let minWidth: CGFloat = dynamicTypeSize.isAccessibilitySize ? 215 : 158
        let maxWidth: CGFloat = dynamicTypeSize.isAccessibilitySize ? 350 : 240
        return [GridItem(.adaptive(minimum: minWidth, maximum: maxWidth), spacing: 16, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.folioDisplay(.title2))
                .foregroundStyle(.primary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(books) { book in
                    FolioMobileRemoteBookTile(book: book)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

enum FolioMobileDiscoverySections {
    static func unique(_ books: [HCBook]) -> [HCBook] {
        var ids = Set<Int>()
        return books.filter { ids.insert($0.id).inserted }
    }
}

/// The tile's own long-press menu, unless the row gives it another one.
private struct FolioRemoteTileMenu: ViewModifier {
    let book: HCBook
    let entry: FolioMobileShelfEntry?
    let changed: () -> Void

    func body(content: Content) -> some View {
        if let entry {
            content.folioShelfEntryCoverMenu(entry, changed: changed)
        } else {
            content.folioRemoteBookContextMenu(book, lifted: true)
        }
    }
}

/// The shape a long press lifts: the cover's own rounded corners (iOS only).
private struct FolioCoverMenuShape: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 11, style: .continuous))
        #else
        content
        #endif
    }
}
