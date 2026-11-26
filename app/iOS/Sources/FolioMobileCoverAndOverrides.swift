import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - Full-screen cover

/// A cover filling the screen: pinch or double-tap to zoom, drag down to close.
struct FolioCoverViewer: View {
    let fileURL: URL?
    let remoteURL: URL?
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var dragDown: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.opacity(1 - min(0.6, Double(dragDown) / 500)).ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .offset(x: offset.width, y: offset.height + dragDown)
                    .gesture(magnify.simultaneously(with: drag))
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(duration: 0.3)) {
                            if scale > 1 { reset() } else { scale = 2.5; lastScale = 2.5 }
                        }
                    }
                    .padding(12)
                    .accessibilityLabel("Cover of \(title)")
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 12) {
                if let image {
                    ShareLink(item: Image(uiImage: image), preview: SharePreview(title, image: Image(uiImage: image))) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Close")
            }
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .padding(12)
            .background(.ultraThinMaterial, in: Capsule())
            .padding()
        }
        .statusBarHidden()
        .task { await load() }
    }

    private var magnify: some Gesture {
        MagnifyGesture()
            .onChanged { value in scale = max(1, min(6, lastScale * value.magnification)) }
            .onEnded { _ in
                lastScale = scale
                if scale <= 1.01 { withAnimation(.spring(duration: 0.3)) { reset() } }
            }
    }

    private var drag: some Gesture {
        DragGesture()
            .onChanged { value in
                if scale > 1 {
                    offset = CGSize(width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height)
                } else {
                    dragDown = max(0, value.translation.height)
                }
            }
            .onEnded { value in
                if scale > 1 {
                    lastOffset = offset
                } else if value.translation.height > 140 {
                    dismiss()
                } else {
                    withAnimation(.spring(duration: 0.3)) { dragDown = 0 }
                }
            }
    }

    private func reset() {
        scale = 1; lastScale = 1; offset = .zero; lastOffset = .zero
    }

    @MainActor
    private func load() async {
        if let fileURL, let local = UIImage(contentsOfFile: fileURL.path) {
            image = local
            return
        }
        guard let remoteURL else { return }
        // The cached copy is downsized for lists; show it, then the full-resolution original.
        image = FolioImageCache.shared.cached(remoteURL)
        if let (data, _) = try? await URLSession.shared.data(from: remoteURL), let full = UIImage(data: data) {
            image = full
        }
    }
}

// MARK: - Edits to books outside the library

/// Changes the reader made to a Hardcover book they don't own a file for: kept on
/// this device and shown wherever the book appears, without touching Hardcover.
struct FolioBookOverride: Codable, Hashable {
    var title: String?
    var authors: String?
    var summary: String?
    var coverURL: URL?
    var publisher: String?
    var year: Int?
    var pages: Int?
    var language: String?
    var isbn: String?
    var series: String?
    var seriesIndex: Double?
    var genres: [String]?

    var isEmpty: Bool { self == FolioBookOverride() }
}

/// The edition a book page showed for a work you don't own a file for.
struct FolioShownEdition: Codable, Hashable {
    var editionID: Int?
    var title: String?
    var coverURL: URL?
}

@Observable
@MainActor
final class FolioBookOverrides {
    static let shared = FolioBookOverrides()
    private static let defaultsKey = "folio.bookOverrides"

    private static let shownKey = "folio.book.shownEditions"

    private(set) var items: [Int: FolioBookOverride] = [:]
    /// The edition each book page last showed, so every list shows that same one.
    private(set) var shown: [Int: FolioShownEdition] = [:]
    @ObservationIgnored private var matchKeys: [String: String] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([Int: FolioBookOverride].self, from: data) {
            items = saved
        }
        if let data = UserDefaults.standard.data(forKey: Self.shownKey),
           let saved = try? JSONDecoder().decode([Int: FolioShownEdition].self, from: data) {
            shown = saved
        }
    }

    func shownEdition(for id: Int) -> FolioShownEdition? { shown[id] }

    /// Remembers the edition a book page showed (title and cover, without edits).
    func recordShown(_ edition: FolioShownEdition, for id: Int) {
        guard id > 0, shown[id] != edition else { return }
        shown[id] = edition
        if let data = try? JSONEncoder().encode(shown) {
            UserDefaults.standard.set(data, forKey: Self.shownKey)
        }
    }

    /// The library copy that stands for a Hardcover book: one linked to it, else an
    /// unlinked file with the same title and author (a download not matched yet).
    func libraryCopy(of book: HCBook) -> LocalBook? {
        let books = LibraryStore.shared.books
        if book.id > 0, let linked = books.first(where: { $0.hardcoverBookID == book.id }) { return linked }
        let wanted = matchKey(author: book.authors, title: book.title)
        return books.first { $0.hardcoverBookID == nil && matchKey(author: $0.author, title: $0.title) == wanted }
    }

    private func matchKey(author: String, title: String) -> String {
        let raw = author + "\u{1F}" + title
        if let hit = matchKeys[raw] { return hit }
        let key = BookMatch.key(author: author, title: title)
        matchKeys[raw] = key
        return key
    }

    func override(for id: Int) -> FolioBookOverride? { items[id] }

    func set(_ override: FolioBookOverride?, for id: Int) {
        items[id] = override?.isEmpty == false ? override : nil
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    /// The book as the reader edited it.
    /// The book as you have it: your library copy's own title and cover when
    /// you own it (often a translated edition, "Nacidos de la bruma"), then
    /// your own edits on top. Ratings and other work-wide numbers stay the
    /// work's. Like a bookstore app, the edition you own is the one you see.
    func apply(_ book: HCBook) -> HCBook {
        var out = book
        let library = LibraryStore.shared
        if let local = libraryCopy(of: book) {
            let title = local.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty, !BookAutoMatch.sameTitle(title, book.title) {
                out.title = title
                out.editionTitle = title
            }
            if let cover = library.coverURL(local), FileManager.default.fileExists(atPath: cover.path) {
                out.imageURL = cover
            }
        } else if let edition = shown[book.id], book.editionID == nil || book.editionID == edition.editionID {
            // Not owned: the edition its book page shows ("El nombre del viento").
            if let title = edition.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
               !BookAutoMatch.sameTitle(title, book.title) {
                out.title = title
                out.editionTitle = title
            }
            if let cover = edition.coverURL { out.imageURL = cover }
        }
        guard let o = items[book.id] else { return out }
        if let title = o.title { out.title = title }
        if let authors = o.authors { out.authors = authors }
        if let summary = o.summary { out.description = summary }
        if let cover = o.coverURL { out.imageURL = cover }
        if let year = o.year { out.year = year }
        if let pages = o.pages { out.pages = pages }
        return out
    }
}


// MARK: - Press-and-hold cover peek

/// The cover being peeked at, shown enlarged over the screen while a finger stays down.
@Observable
@MainActor
final class FolioCoverPeek {
    static let shared = FolioCoverPeek()
    private(set) var fileURL: URL?
    private(set) var remoteURL: URL?
    private(set) var image: UIImage?
    private(set) var active = false
    private var loadID = 0

    func show(fileURL: URL?, remoteURL: URL?) {
        loadID += 1
        let id = loadID
        self.fileURL = fileURL
        self.remoteURL = remoteURL
        image = fileURL.flatMap { UIImage(contentsOfFile: $0.path) } ?? remoteURL.flatMap { FolioImageCache.shared.cached($0) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(duration: 0.28, bounce: 0.18)) { active = true }
        // Swap in the full-resolution image when the list copy is downsized.
        guard fileURL == nil, let remoteURL else { return }
        Task {
            if let (data, _) = try? await URLSession.shared.data(from: remoteURL), let full = UIImage(data: data),
               id == loadID, active {
                image = full
            }
        }
    }

    func hide() {
        withAnimation(.spring(duration: 0.22)) { active = false }
    }
}

/// Shows the peeked cover; put one at the root of each presentation (the app, each sheet).
struct FolioCoverPeekHost: ViewModifier {
    @State private var peek = FolioCoverPeek.shared

    func body(content: Content) -> some View {
        content.overlay {
            if peek.active {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                    Color.black.opacity(0.25).ignoresSafeArea()
                    if let image = peek.image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
                            .padding(28)
                    } else {
                        ProgressView()
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.4)))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

/// Press and hold a cover to see it large; letting go puts it back.
struct FolioCoverPeekGesture: ViewModifier {
    let fileURL: URL?
    let remoteURL: URL?
    @GestureState private var holding = false

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.3)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .updating($holding) { value, state, _ in
                        if case .second(true, _) = value { state = true }
                    }
            )
            .onChange(of: holding) { _, isHolding in
                if isHolding { FolioCoverPeek.shared.show(fileURL: fileURL, remoteURL: remoteURL) }
                else { FolioCoverPeek.shared.hide() }
            }
            .accessibilityAction(named: "Show cover large") {
                FolioCoverPeek.shared.show(fileURL: fileURL, remoteURL: remoteURL)
                Task { try? await Task.sleep(for: .seconds(3)); FolioCoverPeek.shared.hide() }
            }
    }
}

extension View {
    func folioCoverPeekHost() -> some View { modifier(FolioCoverPeekHost()) }
    func folioCoverPeek(fileURL: URL? = nil, remoteURL: URL?) -> some View {
        modifier(FolioCoverPeekGesture(fileURL: fileURL, remoteURL: remoteURL))
    }
}
