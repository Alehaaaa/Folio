import SwiftUI
import UIKit

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

@Observable
@MainActor
final class FolioBookOverrides {
    static let shared = FolioBookOverrides()
    private static let defaultsKey = "folio.bookOverrides"

    private(set) var items: [Int: FolioBookOverride] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([Int: FolioBookOverride].self, from: data) {
            items = saved
        }
    }

    func override(for id: Int) -> FolioBookOverride? { items[id] }

    func set(_ override: FolioBookOverride?, for id: Int) {
        items[id] = override?.isEmpty == false ? override : nil
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    /// The book as the reader edited it.
    func apply(_ book: HCBook) -> HCBook {
        guard let o = items[book.id] else { return book }
        var out = book
        if let title = o.title { out.title = title }
        if let authors = o.authors { out.authors = authors }
        if let summary = o.summary { out.description = summary }
        if let cover = o.coverURL { out.imageURL = cover }
        if let year = o.year { out.year = year }
        if let pages = o.pages { out.pages = pages }
        return out
    }
}

