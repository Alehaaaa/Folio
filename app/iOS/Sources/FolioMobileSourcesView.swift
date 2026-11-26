import SwiftUI
import Observation

@Observable
@MainActor
private final class FolioSourceSearchState {
    static let shared = FolioSourceSearchState()
    var selectedSource = ""
    var search = ""
    var submittedQuery = ""
    var results: [SourceResult] = []
    var searching = false
    var page = 0
    var checkingForNew = false
    var lastEvent: String?
}

/// Accesses the bundled JavaScript source extensions through the shared
/// ExtensionStore. A selected result is downloaded into the normal library.
struct FolioMobileSourcesView: View {
    @Environment(ExtensionStore.self) private var extensions
    @Bindable private var sourceState = FolioSourceSearchState.shared
    @State private var message: String?
    @State private var selectedResult: SourceResult?

    private var selectedSource: String {
        get { sourceState.selectedSource }
        nonmutating set { sourceState.selectedSource = newValue }
    }
    private var search: String {
        sourceState.search
    }
    private var results: [SourceResult] {
        get { sourceState.results }
        nonmutating set { sourceState.results = newValue }
    }
    private var searching: Bool {
        get { sourceState.searching }
        nonmutating set { sourceState.searching = newValue }
    }
    private var page: Int {
        get { sourceState.page }
        nonmutating set { sourceState.page = newValue }
    }
    private var checkingForNew: Bool {
        get { sourceState.checkingForNew }
        nonmutating set { sourceState.checkingForNew = newValue }
    }
    private var lastEvent: String? {
        get { sourceState.lastEvent }
        nonmutating set { sourceState.lastEvent = newValue }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if extensions.loaded && extensions.enabled.isEmpty {
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
        .task {
            await extensions.ensureLoaded()
            selectDefaultSource()
        }
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
                FolioSearchField(text: $sourceState.search, prompt: "Title or author") {
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
                    Picker("Source", selection: $sourceState.selectedSource) {
                        ForEach(extensions.enabled) { source in
                            Text(source.manifest.nameWithLanguages).tag(source.id)
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
            LazyVStack(spacing: 0) {
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
            // Cached and downsized once, so scrolling and status updates
            // don't download every cover again.
            FolioCachedImage(url: result.cover) {
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
            Button { download(result) } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(FolioTheme.olive)
            }
            .buttonStyle(.plain)
            .disabled(result.preferred == nil)
            .accessibilityLabel("Download \(result.title)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func selectDefaultSource() {
        // While extensions reload the list is briefly empty: keep the current
        // choice and its results instead of clearing the page.
        let enabled = extensions.enabled
        guard !enabled.isEmpty, !enabled.contains(where: { $0.id == selectedSource }) else { return }
        selectedSource = enabled.first?.id ?? ""
    }

    @MainActor
    private func searchBooks() async {
        guard !searching, !selectedSource.isEmpty else { return }
        searching = true
        defer { searching = false }
        page = 0
        lastEvent = nil
        sourceState.submittedQuery = search
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
            let next = try await extensions.search(selectedSource, query: sourceState.submittedQuery, page: page + 1)
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
    private func download(_ result: SourceResult) {
        let copy = ExtensionStore.Copy(sourceID: selectedSource, sourceName: sourceName, result: result, exact: false)
        FolioMobileDownloadNotice.enqueueSourceCopy(copy, cover: result.cover, fallbackAuthor: result.author,
                                               hardcoverBookID: nil, hardcoverPages: nil, replacing: nil)
    }
}

/// A source listing is first a book detail, so the preferred format, alternative
/// formats and provenance are visible before the user starts a transfer.
struct FolioMobileSourceBookDetail: View {
    let result: SourceResult
    let sourceID: String

    @Environment(ExtensionStore.self) private var extensions
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss

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
                            download(format: preferred.format)
                        } label: {
                            Label("Download \(preferred.format.uppercased())", systemImage: "arrow.down.circle")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .folioGlassPill(prominent: true)
                    }
                    let otherFormats = Set(result.downloads.map(\.format)).subtracting([result.preferred?.format].compactMap { $0 }).sorted()
                    if !otherFormats.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Other Available Formats").font(.headline)
                            ForEach(otherFormats, id: \.self) { format in
                                Button {
                                    download(format: format)
                                } label: {
                                    Label(format.uppercased(), systemImage: "arrow.down.to.line")
                                        .frame(maxWidth: .infinity, minHeight: 40)
                                }
                                .folioGlassPill()
                                    }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(22)
            }
            .navigationTitle("Book Details")
            .folioSourceDownloadNotice()
            .folioScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.folioGlassPill()
                }
            }
        }
    }

    private func download(format: String) {
        var selected = result
        selected.downloads = result.downloads.filter { $0.format == format }
        let sourceName = extensions.enabled.first { $0.id == sourceID }?.manifest.name ?? sourceID
        let copy = ExtensionStore.Copy(sourceID: sourceID, sourceName: sourceName, result: selected, exact: false)
        FolioMobileDownloadNotice.enqueueSourceCopy(copy, cover: result.cover, fallbackAuthor: result.author,
                                               hardcoverBookID: nil, hardcoverPages: nil, replacing: nil)
    }
}

private struct FolioSourceDownloadNotice: ViewModifier {
    @State private var notice: String?
    @State private var noticeID = UUID()

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let notice {
                    Label(notice, systemImage: "arrow.down.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .folioCreamGlass(in: Capsule())
                        .padding(8)
                        .accessibilityIdentifier("folio.downloadToast")
                        .allowsHitTesting(false)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: FolioMobileDownloadNotice.name)) { event in
                let title = event.userInfo?["title"] as? String ?? "Book"
                let already = event.userInfo?["alreadyInProgress"] as? Bool ?? false
                notice = already ? "Already in Downloads · \(title)" : "Added to Downloads · \(title)"
                noticeID = UUID()
            }
            .task(id: noticeID) {
                guard notice != nil else { return }
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
                notice = nil
            }
    }
}

extension View {
    func folioSourceDownloadNotice() -> some View { modifier(FolioSourceDownloadNotice()) }
}
