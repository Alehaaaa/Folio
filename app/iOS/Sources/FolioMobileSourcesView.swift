import SwiftUI

/// Accesses the bundled JavaScript source extensions through the shared
/// ExtensionStore. A selected result is downloaded into the normal library.
struct FolioMobileSourcesView: View {
    @Environment(ExtensionStore.self) private var extensions
    @Environment(LibraryStore.self) private var store
    @State private var selectedSource = ""
    @State private var search = ""
    @State private var results: [SourceResult] = []
    @State private var searching = false
    @State private var downloading: Set<String> = []
    @State private var message: String?
    @State private var page = 0
    @State private var selectedResult: SourceResult?
    @State private var checkingForNew = false
    @State private var lastEvent: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if extensions.enabled.isEmpty {
                    ContentUnavailableView {
                        Label("No Enabled Sources", systemImage: "square.stack.3d.up.slash")
                    } description: {
                        Text("Source extensions let you discover and import compatible books.")
                    } actions: {
                        NavigationLink {
                            FolioMobileExtensionSettings()
                        } label: { Label("Manage Sources", systemImage: "puzzlepiece.extension") }
                        .folioGlassPill(prominent: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    searchBar
                    if results.isEmpty {
                        Text(searching ? "Looking through \(sourceName)…" : "Search \(sourceName) by title or author, or browse what it has.")
                            .font(.callout)
                            .foregroundStyle(FolioTheme.muted)
                            .padding(.top, 6)
                    } else {
                        resultsList
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 30)
            // Lined up with the page title, not centered under it.
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("Sources")
        .folioScreen()
        .folioPageHeader("Sources") {
                Menu {
                    Button {
                        Task { await checkForNew() }
                    } label: { Label("Check for New Books", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(checkingForNew || selectedSource.isEmpty)
                    NavigationLink {
                        FolioMobileExtensionSettings()
                    } label: { Label("Manage Sources", systemImage: "puzzlepiece.extension") }
                } label: {
                    FolioHeaderIconLabel(symbol: "ellipsis")
                }
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .foregroundStyle(FolioTheme.ink)
                .accessibilityLabel("More")
        }
        .task { selectDefaultSource() }
        .onChange(of: extensions.enabled.map(\.id)) { _, _ in selectDefaultSource() }
        .onChange(of: selectedSource) { _, _ in results = []; page = 0; lastEvent = nil }
        .sheet(item: $selectedResult) { result in
            FolioMobileSourceBookDetail(result: result, sourceID: selectedSource)
        }
        .alert("Sources", isPresented: Binding(
            get: { message != nil },
            set: { if !$0 { message = nil } }
        )) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private var sourceName: String {
        extensions.enabled.first { $0.id == selectedSource }?.manifest.name ?? "this source"
    }

    /// The source to search, the field, and one button, on a single row.
    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                FolioSearchField(text: $search, prompt: "Title or author") {
                    Task { await searchBooks() }
                }
                Button {
                    Task { await searchBooks() }
                } label: {
                    if searching {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(search.isEmpty ? "Browse" : "Search")
                    }
                }
                .folioGlassPill(prominent: true)
                .disabled(searching || selectedSource.isEmpty)
            }
            HStack(spacing: 8) {
                Menu {
                    Picker("Source", selection: $selectedSource) {
                        ForEach(extensions.enabled) { source in
                            Text(source.manifest.name).tag(source.id)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(sourceName, systemImage: "square.stack.3d.up")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(FolioTheme.ink)
                }
                .menuIndicator(.visible)
                .fixedSize()
                .accessibilityLabel("Source")
                if let lastEvent, !lastEvent.isEmpty {
                    Text(lastEvent)
                        .font(.caption)
                        .foregroundStyle(FolioTheme.muted)
                        .lineLimit(1)
                }
            }
        }
    }

    private var resultsList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text("Results")
                    .font(.folioDisplay(.title2, weight: .semibold))
                    .foregroundStyle(FolioTheme.ink)
                Text("\(results.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(FolioTheme.muted)
            }
            VStack(spacing: 0) {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                    if index > 0 {
                        Rectangle().fill(FolioTheme.line.opacity(0.7)).frame(height: 0.5)
                            .padding(.leading, 76)
                    }
                    resultRow(result)
                }
            }
            .folioCard()
            HStack {
                Spacer()
                Button {
                    Task { await loadMore() }
                } label: {
                    if searching { ProgressView().controlSize(.small) }
                    else { Label("More Results", systemImage: "arrow.down") }
                }
                .folioGlassPill()
                .disabled(searching || selectedSource.isEmpty)
                Spacer()
            }
            .padding(.top, 4)
        }
    }

    private func resultRow(_ result: SourceResult) -> some View {
        HStack(spacing: 14) {
            AsyncImage(url: result.cover) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "book.closed.fill")
                    .foregroundStyle(FolioTheme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(FolioTheme.line.opacity(0.4))
            }
            .frame(width: 44, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Button {
                selectedResult = result
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(FolioTheme.ink)
                        .lineLimit(2)
                    Text(result.author.isEmpty ? "Unknown Author" : result.author)
                        .font(.callout)
                        .foregroundStyle(FolioTheme.muted)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        if let format = result.preferred?.format {
                            Text(format.uppercased()).font(.caption2.weight(.semibold))
                        }
                        if let count = result.downloadCount {
                            Text("\(count.formatted()) downloads").font(.caption2)
                        }
                    }
                    .foregroundStyle(FolioTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if downloading.contains(result.id) {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await download(result) }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .foregroundStyle(FolioTheme.olive)
                }
                .buttonStyle(.plain)
                .disabled(result.preferred == nil)
                .accessibilityLabel("Add \(result.title) to Library")
                .help("Add to Library")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func selectDefaultSource() {
        if !extensions.enabled.contains(where: { $0.id == selectedSource }) {
            selectedSource = extensions.enabled.first?.id ?? ""
        }
    }

    @MainActor
    private func searchBooks() async {
        guard !searching, !selectedSource.isEmpty else { return }
        searching = true
        defer { searching = false }
        page = 0
        lastEvent = nil
        do {
            results = try await extensions.search(selectedSource, query: search, page: page) { event in
                Task { @MainActor in
                    if case .status(let status) = event { lastEvent = status }
                }
            }
            if results.isEmpty { message = "No matching books were found." }
        } catch {
            results = []
            message = error.localizedDescription
        }
    }

    @MainActor
    private func loadMore() async {
        guard !searching, !selectedSource.isEmpty else { return }
        searching = true
        defer { searching = false }
        do {
            let next = try await extensions.search(selectedSource, query: search, page: page + 1)
            if next.isEmpty {
                message = "This source has no more results."
            } else {
                page += 1
                let known = Set(results.map(\.id))
                results.append(contentsOf: next.filter { !known.contains($0.id) })
            }
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor
    private func checkForNew() async {
        guard !checkingForNew, !selectedSource.isEmpty else { return }
        checkingForNew = true
        defer { checkingForNew = false }
        do {
            let incoming = try await extensions.checkForNew(selectedSource)
            results = incoming
            page = 0
            message = incoming.isEmpty ? "This source has no new books." : "Found \(incoming.count) new books."
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor
    private func download(_ result: SourceResult) async {
        guard downloading.insert(result.id).inserted else { return }
        defer { downloading.remove(result.id) }
        do {
            _ = try await extensions.download(result, from: selectedSource, into: store)
            message = "Added “\(result.title)” to the library."
        } catch {
            message = error.localizedDescription
        }
    }
}

/// A source listing is first a book detail, so the preferred format, alternative
/// formats and provenance are visible before the user starts a transfer.
struct FolioMobileSourceBookDetail: View {
    let result: SourceResult
    let sourceID: String

    @Environment(ExtensionStore.self) private var extensions
    @Environment(LibraryStore.self) private var library
    @Environment(FolioMobileNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .center, spacing: 18) {
                    AsyncImage(url: result.cover) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Image(systemName: "book.closed.fill")
                            .font(.system(size: 70)).foregroundStyle(.secondary)
                    }
                    .frame(width: 170, height: 240)
                    Text(result.title).font(.folioDisplay(.title)).multilineTextAlignment(.center)
                    Text(result.author).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if let year = result.year { Text(String(year)).foregroundStyle(.secondary) }
                    if let count = result.downloadCount {
                        LabeledContent("Source Downloads", value: count.formatted())
                    }
                    if !result.origin.isEmpty {
                        LabeledContent("Source Record", value: result.origin)
                    }
                    if library.localCopy(author: result.author, title: result.title) != nil {
                        Label("Already in your Library", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(FolioTheme.success)
                    }
                    if let preferred = result.preferred {
                        Button {
                            Task { await download(format: preferred.format) }
                        } label: {
                            if busy { ProgressView() }
                            else { Label("Download \(preferred.format.uppercased())", systemImage: "arrow.down.circle") }
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .folioGlassPill(prominent: true)
                        .disabled(busy)
                    }
                    if result.downloads.count > 1 {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Other Available Formats").font(.headline)
                            ForEach(Array(Set(result.downloads.map(\.format))).sorted(), id: \.self) { format in
                                Button {
                                    Task { await download(format: format) }
                                } label: {
                                    Label(format.uppercased(), systemImage: "arrow.down.to.line")
                                        .frame(maxWidth: .infinity, minHeight: 40)
                                }
                                .folioGlassPill()
                                .disabled(busy)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(22)
            }
            .navigationTitle("Book Details")
            .folioScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.folioGlassPill()
                }
            }
        }
    }

    private func download(format: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        var selected = result
        selected.downloads = result.downloads.filter { $0.format == format }
        do {
            let id = try await extensions.download(selected, from: sourceID, into: library)
            dismiss()
            navigation.read(id)
        } catch {
            message = error.localizedDescription
        }
    }
}
