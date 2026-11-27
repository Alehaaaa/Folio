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
                // A fixed cover frame, so a two-line title can never squeeze it in a row.
                .modifier(FolioCoverFrame(width: width, aspect: 0.69))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(.primary.opacity(0.07), lineWidth: 0.7)
                }
                // A long press lifts the cover alone, as it is, over the blurred screen.
                .modifier(FolioCoverMenuShape())
                .modifier(FolioRemoteTileMenu(book: original, entry: entry, changed: changed))

                FolioTileCaption(title: book.title,
                                 caption: book.authors.isEmpty ? "Unknown author" : book.authors,
                                 titleFont: .system(.body, design: .serif),
                                 captionFont: .subheadline,
                                 titleColor: .primary,
                                 captionLines: dynamicTypeSize.isAccessibilitySize ? 2 : 1)
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

/// Gives a tile's cover the same frame in every row: an exact height when the tile
/// width is known, otherwise the aspect ratio with its full height kept.
struct FolioCoverFrame: ViewModifier {
    let width: CGFloat?
    let aspect: CGFloat

    func body(content: Content) -> some View {
        if let width {
            content.frame(width: width, height: (width / aspect).rounded())
        } else {
            content.aspectRatio(aspect, contentMode: .fit)
        }
    }
}

/// A tile's title (up to two lines) with its caption (one line) right under it.
/// The block always takes the room of two title lines and the caption, so every tile
/// in a row or grid is the same height and the covers stay lined up; a one-line
/// title just leaves the caption higher with the spare room below.
struct FolioTileCaption: View {
    let title: String
    let caption: String
    let titleFont: Font
    let captionFont: Font
    var titleColor: Color = FolioTheme.ink
    var captionLines = 1

    var body: some View {
        ZStack(alignment: .topLeading) {
            column(title: " ", caption: " ", reserve: true)
                .hidden()
                .accessibilityHidden(true)
            column(title: title, caption: caption)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func column(title: String, caption: String, reserve: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(titleFont)
                .foregroundStyle(titleColor)
                .lineLimit(2, reservesSpace: reserve)
                .multilineTextAlignment(.leading)
            Text(caption)
                .font(captionFont)
                .foregroundStyle(FolioTheme.muted)
                .lineLimit(captionLines, reservesSpace: reserve)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
