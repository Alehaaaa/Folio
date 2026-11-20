import SwiftUI
import UniformTypeIdentifiers
import PDFKit

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

struct HCBookCell: View {
    let book: HCBook
    var progress: Double? = nil
    var open: (() -> Void)? = nil
    @Environment(HardcoverClient.self) private var hc
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            CoverArt(title: book.title, author: book.authors, remote: book.imageURL)
                .scaleEffect(hovering ? 1.03 : 1)
                .animation(.spring(duration: 0.25), value: hovering)
                .onHover { hovering = $0 }
                .onTapGesture { open?() }
            Text(book.title).font(.callout.weight(.semibold)).lineLimit(2)
                .onTapGesture { open?() }
            AuthorLinks(line: book.authors).font(.caption).foregroundStyle(.secondary)
            if let progress {
                HStack(spacing: 6) {
                    ProgressView(value: progress).controlSize(.mini).frame(maxWidth: 70)
                    Text("\(Int(progress * 100))%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            } else if let r = book.rating, r > 0 {
                HStack(spacing: 4) {
                    StarRating(rating: r, size: 9)
                    Text(String(format: "%.1f", r)).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .contextMenu { HCBookActions(book: book, open: open) }
    }
}

/// Right-click menu for a Hardcover book tile.
struct HCBookActions: View {
    let book: HCBook
    var open: (() -> Void)?
    @Environment(HardcoverClient.self) private var hc
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Read") {
            readBook(title: book.title, author: book.authors, hardcoverBookID: book.id, hardcoverPages: book.pages, cover: book.imageURL, openWindow: openWindow)
        }
        if let open { Button("Show Details") { open() } }
        Divider()
        Menu("Add to Shelf") {
            ForEach(HCStatus.allCases) { s in
                Button { Task { await hc.setStatus(bookID: book.id, status: s) } } label: { Label(s.label, systemImage: s.symbol) }
            }
        }
        .disabled(!hc.isConnected)
        Divider()
        ForEach(Names.split(book.authors).prefix(4), id: \.self) { n in
            Button("Go to \(n)") { Router.shared.open(.author(n)) }
        }
        Button("Go to Series") {
            Task {
                if let s = try? await hc.series(forBook: book.id).first {
                    Router.shared.open(.series(name: s.name, hardcoverID: s.id))
                }
            }
        }
        .disabled(!hc.isConnected)
        Divider()
        if let url = book.webURL { Button("Open on Hardcover") { NSWorkspace.shared.open(url) } }
        Button("Copy Title") { copy(book.title) }
    }
}

func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

struct ConnectPrompt: View {
    var message = "Connect your Hardcover account to see your shelves, track what you read, and browse books."
    var body: some View {
        GlassCard(padding: 34) {
            VStack(spacing: 14) {
                Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 46)).foregroundStyle(.indigo)
                Text("Connect Hardcover").font(.title2.weight(.bold))
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
                SettingsLink { Text("Connect Account…") }.buttonStyle(.glassProminent).controlSize(.large)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Browse (search + trending)

struct BrowseView: View {
    @Environment(HardcoverClient.self) private var hc
    @State private var query = ""
    @State private var submitted = ""
    @State private var results: [HCBook] = []
    @State private var trending: [HCBook] = []
    @State private var loading = false
    @State private var error: String?
    @State private var detail: HCBook?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Browse").font(.largeTitle.weight(.bold))
                if !hc.isConnected {
                    ConnectPrompt(message: "Hardcover's book catalogue needs your free Hardcover account. Connect it to search millions of books and see what's trending.")
                } else {
                    if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
                    if loading { ProgressView().frame(maxWidth: .infinity) }
                    if !submitted.isEmpty {
                        SectionHeader(title: "Results for “\(submitted)”", subtitle: "\(results.count) books")
                        grid(results)
                    } else {
                        SectionHeader(title: "Trending This Month", subtitle: "What Hardcover readers are picking up")
                        grid(trending)
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .searchable(text: $query, placement: .toolbar, prompt: "Search books & authors")
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: query) { _, v in if v.isEmpty { submitted = ""; results = [] } }
        .task(id: hc.isConnected) {
            guard hc.isConnected, trending.isEmpty else { return }
            loading = true
            do { trending = try await hc.trending(); error = nil } catch { self.error = error.localizedDescription }
            loading = false
        }
        .bookPopup(item: $detail) { HCBookDetail(book: $0) }
    }

    private func grid(_ books: [HCBook]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 26, alignment: .top)], alignment: .leading, spacing: 30) {
            ForEach(books) { b in HCBookCell(book: b) { detail = b } }
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        loading = true
        submitted = q
        do { results = try await hc.search(q); error = nil } catch { self.error = error.localizedDescription; results = [] }
        loading = false
    }
}

