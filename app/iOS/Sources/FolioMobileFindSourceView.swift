import SwiftUI
import UIKit

/// Manual fallback for a download that could not find an exact automatic EPUB.
/// The normal Find Source action enqueues DownloadQueue; this sheet searches
/// enabled extensions again and only downloads the copy explicitly selected.
struct FolioMobileFindSourceView: View {
    let title: String
    let author: String
    let hardcoverBookID: Int?
    let hardcoverPages: Int?
    let cover: URL?
    let failedJobID: UUID?

    @Environment(ExtensionStore.self) private var extensions
    @Environment(LibraryStore.self) private var library
    @Environment(FolioMobileNavigation.self) private var navigation
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var queryTitle: String
    @State private var queryAuthor: String
    @State private var selectedLanguage = BookLanguage.preferred
    @State private var searching = false
    @State private var hasSearched = false
    @State private var asking = ""
    @State private var copies: [ExtensionStore.Copy] = []
    @State private var problems: [String] = []
    @State private var messages: [String] = []

    /// The automatic queue requires a specific language. A person choosing an
    /// edition can deliberately broaden that search, but never silently.
    private struct LanguageOption: Identifiable {
        let code: String
        let label: String
        var id: String { code }
    }

    private static let languages: [LanguageOption] = [
        .init(code: "", label: "Any language (manual choice)"),
        .init(code: "en", label: "English"), .init(code: "es", label: "Spanish"),
        .init(code: "de", label: "German"), .init(code: "fr", label: "French"),
        .init(code: "it", label: "Italian"), .init(code: "pt", label: "Portuguese"),
        .init(code: "nl", label: "Dutch"), .init(code: "ja", label: "Japanese"),
        .init(code: "zh", label: "Chinese"), .init(code: "ru", label: "Russian"),
        .init(code: "pl", label: "Polish"), .init(code: "sv", label: "Swedish"),
        .init(code: "no", label: "Norwegian")
    ]

    init(title: String, author: String, hardcoverBookID: Int? = nil,
         hardcoverPages: Int? = nil, cover: URL? = nil, failedJobID: UUID? = nil) {
        self.title = title
        self.author = author
        self.hardcoverBookID = hardcoverBookID
        self.hardcoverPages = hardcoverPages
        self.cover = cover
        self.failedJobID = failedJobID
        _queryTitle = State(initialValue: title)
        _queryAuthor = State(initialValue: author)
    }

    var body: some View {
        ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 15) {
                        FolioMobileRemoteCover(url: cover, title: title)
                            .frame(width: 68, height: 97)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title).font(.headline)
                            Text(author.isEmpty ? "Unknown Author" : author)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("Choose a specific book edition or format to import and read.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    VStack(alignment: .leading, spacing: 11) {
                        Text("Search metadata").font(.headline)
                        TextField("Title", text: $queryTitle)
                            .textInputAutocapitalization(.words)
                            .textFieldStyle(.roundedBorder)
                            .disabled(searching)
                        TextField("Author", text: $queryAuthor)
                            .textInputAutocapitalization(.words)
                            .textFieldStyle(.roundedBorder)
                            .disabled(searching)
                        Picker("Edition language", selection: $selectedLanguage) {
                            ForEach(Self.languages) { language in
                                Text(language.label).tag(language.code)
                            }
                        }
                        .disabled(searching)
                        Text(selectedLanguage.isEmpty
                             ? "Showing editions in any language. Check the edition before importing."
                             : "Prioritizing \(languageName(selectedLanguage)) editions; unverified editions are labeled below.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if !extensions.enabled.isEmpty {
                            Text("Enabled sources: \(extensions.enabled.map { $0.manifest.nameWithLanguages }.joined(separator: ", "))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if let anna = extensions.installed.first(where: { $0.id == "annas-archive-free" }),
                           !anna.saved.enabled {
                            Label("Anna's Archive is disabled. Enable it under Sources before searching.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                        FolioGlassButton(title: "Search Sources", systemImage: "magnifyingglass", prominent: true, fullWidth: true) {
                            Task { await search() }
                        }
                        .disabled(searching || queryTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(15)
                    .folioCard(cornerRadius: 20)

                    if searching {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(asking.isEmpty ? "Searching enabled sources…" : "Asking \(asking)…")
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                        .accessibilityIdentifier("folio.findSource.searching")
                    }

                    if let id = library.localCopy(author: queryAuthor, title: queryTitle)?.id {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("This book is already in your library.", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            FolioGlassButton(title: "Read", systemImage: "book.fill", prominent: true, fullWidth: true) {
                                openReader(id)
                            }
                        }
                    } else if hasSearched && !searching && copies.isEmpty {
                        ContentUnavailableView {
                            Label("No Copies Found", systemImage: "magnifyingglass")
                        } description: {
                            Text(extensions.enabled.isEmpty
                                 ? "Enable a source in Sources and search again."
                                 : "Try a different title or author, or enable additional sources.")
                        } actions: {
                            FolioGlassButton(title: "Manage Sources", systemImage: "square.stack.3d.up") {
                                dismiss()
                                navigation.openSources()
                            }
                        }
                    } else if !copies.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Available Copies (\(copies.count))")
                                .font(.folioDisplay(.title2))
                            Text("Exact title and author matches appear first. Review the edition before downloading.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            ForEach(copies) { copy in
                                copyRow(copy)
                            }
                        }
                    }


                    if !problems.isEmpty && !searching {
                        if copies.isEmpty {
                            Label("\(problems.count) source\(problems.count == 1 ? "" : "s") could not complete the search. See the source errors below.",
                                  systemImage: "network.slash")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                        }
                        DisclosureGroup("Source Errors (\(problems.count))") {
                            ForEach(problems, id: \.self) { problem in
                                Text(problem)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    if !messages.isEmpty {
                        if let latest = messages.last, searching {
                            Text(latest)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                                .accessibilityLabel("Latest source activity: \(latest)")
                        }
                        DisclosureGroup("Source Activity (\(messages.count))") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(messages.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                Button { copyDiagnostics() } label: {
                                    Label("Copy Diagnostics", systemImage: "doc.on.doc")
                                }
                                .folioGlassPill()
                            }
                        }
                        .font(.footnote)
                    }
                }
                .padding(18)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Choose Source")
            .folioScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .folioGlassPill()
                }
            }
            .task {
                if let failedJobID,
                   let job = DownloadQueue.shared.jobs.first(where: { $0.id == failedJobID }),
                   let language = BookLanguage.code(job.expectedLanguage) {
                    selectedLanguage = language
                }
                await search()
            }
    }

    private func copyRow(_ copy: ExtensionStore.Copy) -> some View {
        HStack(alignment: .top, spacing: 12) {
            FolioMobileRemoteCover(url: copy.result.cover ?? cover, title: copy.result.title)
                .frame(width: 47, height: 67)
            VStack(alignment: .leading, spacing: 5) {
                Text(copy.result.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(copy.result.author.isEmpty ? "Unknown Author" : copy.result.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Label(extensions.installed.first { $0.id == copy.sourceID }?.manifest.nameWithLanguages
                          ?? copy.sourceName, systemImage: "square.stack.3d.up")
                    if let preferred = copy.result.preferred {
                        Text(preferred.format.uppercased())
                            .fontWeight(.semibold)
                    }
                    if copy.exact {
                        Label("Exact", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let count = copy.result.downloadCount {
                    Text("\(count.formatted()) provider-reported downloads")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    Image(systemName: "globe")
                    Text(copy.result.language.flatMap(BookLanguage.code).map { languageName($0) } ?? "Language unverified")
                    if !selectedLanguage.isEmpty,
                       BookLanguage.matches(copy.result.language, expected: selectedLanguage) == false {
                        Text("· different from \(languageName(selectedLanguage))")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                FolioGlassButton(
                    title: "Get \((copy.result.preferred?.format ?? "book").uppercased())",
                    systemImage: "arrow.down.circle", prominent: copy.exact
                ) {
                    download(copy)
                }
                .disabled(searching || copy.result.preferred == nil)
                .padding(.top, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(13)
        .folioCard(cornerRadius: 18)
        .accessibilityIdentifier("folio.findSource.copy.\(copy.id)")
    }

    @MainActor
    private func search() async {
        guard !searching else { return }
        let wantedTitle = queryTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let wantedAuthor = queryAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wantedTitle.isEmpty else { return }
        searching = true
        asking = ""
        hasSearched = false
        copies = []
        problems = []
        messages = []
        defer {
            searching = false
            hasSearched = true
        }
        await extensions.ensureLoaded()
        let result = await extensions.findCopies(
            title: wantedTitle, author: wantedAuthor,
            expectedLanguage: selectedLanguage.isEmpty ? nil : selectedLanguage,
            progress: { source in asking = source },
            onEvent: { source, event in
                Task { @MainActor in
                    switch event {
                    case .status(let line):
                        asking = "\(source) · \(line)"
                    case .log(let line):
                        appendMessage("\(source): \(line)")
                    case .transfer:
                        break
                    }
                }
            }
        )
        guard !Task.isCancelled else { return }
        copies = result.copies
        problems = result.problems
        for problem in result.problems { appendMessage("SOURCE ERROR: \(problem)") }
        if copies.isEmpty && result.problems.isEmpty {
            appendMessage("No matching downloadable editions returned for \(wantedTitle) - \(wantedAuthor) (language: \(selectedLanguage.isEmpty ? "any" : selectedLanguage))")
        }
    }

    @MainActor
    private func download(_ copy: ExtensionStore.Copy) {
        DownloadQueue.shared.enqueueSourceCopy(copy, cover: copy.result.cover ?? cover, fallbackAuthor: queryAuthor,
                                               hardcoverBookID: hardcoverBookID, hardcoverPages: hardcoverPages,
                                               replacing: failedJobID)
        dismiss()
        navigation.openDownloads()
    }

    @MainActor
    private func openReader(_ id: UUID) {
        dismiss()
        navigation.read(id)
    }

    private func appendMessage(_ message: String) {
        let cleaned = String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(850))
        guard !cleaned.isEmpty else { return }
        messages.append("\(Date().formatted(date: .omitted, time: .standard)) · \(cleaned)")
        if messages.count > 100 { messages.removeFirst(messages.count - 100) }
    }

    private func languageName(_ code: String) -> String {
        Self.languages.first(where: { $0.code == code })?.label
            ?? Locale.current.localizedString(forLanguageCode: code)?.capitalized
            ?? code.uppercased()
    }

    private func copyDiagnostics() {
        let report = ([
            "Folio iOS · Find Source diagnostics",
            "Book: \(queryTitle) - \(queryAuthor)",
            "Edition language filter: \(selectedLanguage.isEmpty ? "any" : selectedLanguage)",
            "Enabled sources: \(extensions.enabled.map(\.id).joined(separator: ", "))",
            "Search results: \(copies.count)",
            "Source problems: \(problems.joined(separator: " | "))",
            "Activity:"
        ] + messages).joined(separator: "\n")
        UIPasteboard.general.string = report
    }
}

/// Use NSError's stable domain/code and underlying network cause rather than
/// only a generic localizedDescription. Never copy full URLs (which may contain
/// private query parameters) or credentials into diagnostic strings.
enum FolioMobileSourceDiagnostics {
    static func describe(_ error: Error, source: String? = nil) -> String {
        let ns = error as NSError
        var lines: [String] = []
        if let source { lines.append("Source: \(source)") }
        lines.append("\(error.localizedDescription) [\(ns.domain) \(ns.code)]")
        if let reason = ns.localizedFailureReason, !reason.isEmpty,
           reason != error.localizedDescription { lines.append("Reason: \(reason)") }
        if let url = (ns.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:)),
           let host = url.host { lines.append("Network host: \(host)") }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            lines.append("Underlying: \(underlying.localizedDescription) [\(underlying.domain) \(underlying.code)]")
        }
        return lines.joined(separator: " · ")
    }
}
