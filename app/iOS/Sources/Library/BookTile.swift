import SwiftUI
import UniformTypeIdentifiers

struct FolioMobileBookTile: View {
    @Environment(LibraryStore.self) private var store
    let book: LocalBook
    /// When the library is sorted by series, the caption names the saga and volume.
    var showsSeries = false

    private var caption: String {
        if showsSeries, let series = book.series?.trimmingCharacters(in: .whitespacesAndNewlines), !series.isEmpty {
            return book.seriesIndex.map { "\(series) #\($0.formatted())" } ?? series
        }
        return book.author.isEmpty ? "Unknown Author" : book.author
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            FolioMobileCover(book: book)
                .aspectRatio(0.7, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.14), radius: 6, x: 1, y: 4)
                .overlay(alignment: .topTrailing) {
                    if finished {
                        Image(systemName: "checkmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Color(red: 0.16, green: 0.23, blue: 0.17), in: Circle())
                            .overlay { Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1) }
                            .padding(8)
                            .transition(.scale.combined(with: .opacity))
                            .accessibilityHidden(true)
                    }
                }
            FolioTileCaption(title: FolioBookOverrides.shared.downloadedTitle(book),
                             caption: caption,
                             titleFont: .system(.subheadline, design: .serif),
                             captionFont: .caption)
            // Marking a book read collapses its bar toward the start and hides it; the
            // empty row stays so the grid keeps its alignment.
            ZStack(alignment: .leading) {
                if !finished, book.progress > 0 {
                    ProgressView(value: min(1, book.progress))
                        .tint(FolioTheme.olive)
                        .transition(.scale(scale: 0.01, anchor: .leading).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 4)
        }
        .animation(.spring(duration: 0.45, bounce: 0.15), value: finished)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(finished ? "Finished" : "")
    }

    private var finished: Bool { FolioReadBooks.shared.isRead(book) }
}

struct FolioMobileCover: View {
    @Environment(LibraryStore.self) private var store
    let book: LocalBook
    /// The cover read in the background, with the file it came from.
    @State private var loaded: (file: URL, image: UIImage)?

    var body: some View {
        let file = store.coverURL(book)
        // Only memory here: reading and decoding the file while building the view
        // stalled every scroll that brought new covers on screen.
        let image = file.flatMap { file in
            FolioImageCache.shared.localCoverInMemory(file) ?? (loaded?.file == file ? loaded?.image : nil)
        }
        GeometryReader { geometry in
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            } else {
                FolioClothCover(title: FolioBookOverrides.shared.downloadedTitle(book),
                                subtitle: book.author.isEmpty ? nil : book.author,
                                systemImage: book.format.symbol,
                                compact: geometry.size.width < 90)
            }
        }
        .background(FolioTheme.sage)
        .task(id: file) {
            guard let file else { return }
            if let image = await FolioImageCache.shared.loadLocalCover(file) { loaded = (file, image) }
        }
    }
}
