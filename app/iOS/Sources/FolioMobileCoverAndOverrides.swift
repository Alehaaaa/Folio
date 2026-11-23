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

    var isEmpty: Bool { title == nil && authors == nil && summary == nil && coverURL == nil }
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
        return out
    }
}

/// Edit the title, author, description and cover of a book that isn't in the
/// library, with suggestions from the metadata sources in the reader's language.
struct FolioMobileRemoteBookEditor: View {
    let book: HCBook
    var editionID: Int?

    @Environment(HardcoverClient.self) private var hardcover
    @Environment(\.dismiss) private var dismiss
    @State private var overrides = FolioBookOverrides.shared
    @State private var candidates: [FolioMetadataCandidate] = []
    @State private var loading = true
    @State private var title = ""
    @State private var authors = ""
    @State private var summary = ""
    @State private var cover: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section("Cover") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(coverOptions, id: \.self) { url in
                                Button { cover = url } label: {
                                    FolioMobileRemoteCover(url: url, title: title)
                                        .frame(width: 78, height: 114)
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 7)
                                                .strokeBorder(cover == url ? FolioTheme.olive : .clear, lineWidth: 3)
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(cover == url ? "Chosen cover" : "Use this cover")
                            }
                            if loading { ProgressView().frame(width: 78, height: 114) }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .folioRow()
                field("Title", text: $title, values: candidates.compactMap { c in c.title.map { (c.source, $0) } })
                field("Author", text: $authors, values: candidates.compactMap { c in c.author.map { (c.source, $0) } })
                Section("Description") {
                    TextField("Description", text: $summary, axis: .vertical).lineLimit(3...10)
                    ForEach(suggestions(candidates.compactMap { c in c.summary.map { (c.source, $0.plainText) } }, current: summary).prefix(3),
                            id: \.1) { source, value in
                        Button { summary = value } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source).font(.caption.weight(.semibold)).foregroundStyle(FolioTheme.olive)
                                Text(value).font(.footnote).foregroundStyle(.primary).lineLimit(4)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .folioRow()
                if overrides.override(for: book.id) != nil {
                    Section {
                        Button("Restore Hardcover's Details", role: .destructive) {
                            overrides.set(nil, for: book.id)
                            dismiss()
                        }
                    } footer: {
                        Text("Your changes stay on this device and don't change Hardcover.")
                    }
                    .folioRow()
                }
            }
            .folioScreen()
            .navigationTitle("Edit Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(title.isEmpty) }
            }
            .task { await start() }
        }
    }

    private var coverOptions: [URL] {
        var seen = Set<URL>()
        let current = overrides.apply(book).imageURL
        return ([current, book.imageURL].compactMap { $0 } + candidates.compactMap(\.coverURL))
            .filter { seen.insert($0).inserted }
    }

    private func field(_ name: String, text: Binding<String>, values: [(String, String)]) -> some View {
        Section(name) {
            TextField(name, text: text)
            let distinct = suggestions(values, current: text.wrappedValue)
            if !distinct.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(distinct, id: \.1) { source, value in
                            Button { text.wrappedValue = value } label: {
                                HStack(spacing: 5) {
                                    Text(value).lineLimit(1)
                                    Text(source).foregroundStyle(.secondary)
                                }
                                .font(.footnote)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(FolioTheme.sage, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .folioRow()
    }

    private func suggestions(_ values: [(String, String)], current: String) -> [(String, String)] {
        var seen: Set<String> = [current.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)]
        return values.filter { _, value in
            let key = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    @MainActor
    private func start() async {
        let shown = overrides.apply(book)
        title = shown.title
        authors = shown.authors
        summary = shown.description?.plainText ?? ""
        cover = shown.imageURL
        // Ask the same sources as Fix Metadata, as if this book were a file in the reader's language.
        var probe = LocalBook(title: book.title, author: book.authors, format: .epub, fileName: "")
        probe.hardcoverBookID = book.id > 0 ? book.id : nil
        probe.hardcoverEditionID = editionID
        probe.language = BookLanguage.reading
        candidates = await FolioMetadataSources.all(for: probe, hardcover: hardcover)
        loading = false
    }

    private func save() {
        func changed(_ value: String, from original: String?) -> String? {
            let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty || t == (original ?? "").trimmingCharacters(in: .whitespacesAndNewlines) ? nil : t
        }
        overrides.set(FolioBookOverride(
            title: changed(title, from: book.title),
            authors: changed(authors, from: book.authors),
            summary: changed(summary, from: book.description?.plainText),
            coverURL: cover == book.imageURL ? nil : cover), for: book.id)
        dismiss()
    }
}
