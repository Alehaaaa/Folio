import SwiftUI
import UniformTypeIdentifiers

// MARK: - Getting a copy of a book from the sources

/// Explicit fallback for someone who wants to choose a particular source or format after a
/// background attempt failed. Only manual clicks download here; the queue owns automatic tries.
struct ManualCopyPicker: View {
    let title: String
    let author: String
    var hardcoverBookID: Int? = nil
    var hardcoverPages: Int? = nil
    var cover: URL? = nil
    var failedJobID: UUID? = nil

    @Environment(ExtensionStore.self) private var exts

    @State private var searching = true
    @State private var asking = ""
    @State private var copies: [ExtensionStore.Copy] = []
    @State private var problems: [String] = []
    @State private var searchingFor: String?

    private var requestKey: String { "\(title)\u{0}\(author)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if searching {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(asking.isEmpty ? "Looking for a copy…" : "Asking \(asking)…").foregroundStyle(.secondary)
                }
            } else if copies.isEmpty {
                Label(exts.enabled.isEmpty ? "No sources are turned on." : "None of your sources has a copy Folio can read.", systemImage: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Button("Extensions…") { NotificationCenter.default.post(name: .folioShowSources, object: nil) }
                    .buttonStyle(.glass).controlSize(.small)
            } else {
                Text("Choose a format or edition to add to your library.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(copies.prefix(8)) { c in
                    HStack(spacing: 12) {
                        CoverArt(title: c.result.title, author: c.result.author, remote: c.result.cover ?? cover, cornerRadius: 3).frame(width: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.result.title).fontWeight(.semibold).lineLimit(1)
                            Text([c.result.author, c.result.language.map { "Language: \($0)" } ?? "Language: unverified",
                                  c.sourceName, c.result.origin].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let d = c.result.preferred {
                            Button { get(c) } label: { Label("Get \(d.format.uppercased())", systemImage: "arrow.down.circle") }
                                .buttonStyle(.glassProminent)
                                .controlSize(.small)
                        }
                    }
                }
            }
            if !problems.isEmpty && !searching {
                Text(problems.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .folioSourceDownloadNotice()
        .task(id: "\(title)|\(author)") { await search() }
    }

    private func search() async {
        let key = requestKey
        guard searchingFor != key else { return }
        searchingFor = key
        defer { if searchingFor == key { searchingFor = nil } }
        searching = true
        asking = ""
        copies = []
        let r = await exts.findCopies(title: title, author: author) { name in asking = name }
        guard !Task.isCancelled, searchingFor == key else { return }
        copies = r.copies
        problems = r.problems
        searching = false
    }

    private func get(_ copy: ExtensionStore.Copy) {
        FolioMobileDownloadNotice.enqueueSourceCopy(copy, cover: copy.result.cover ?? cover, fallbackAuthor: author,
                                               hardcoverBookID: hardcoverBookID, hardcoverPages: hardcoverPages,
                                               replacing: failedJobID)
    }
}

/// A small floating panel for selecting a specific copy when background retrieval fails.
struct FindCopyPanel: View {
    let title: String
    let author: String
    var hardcoverBookID: Int? = nil
    var hardcoverPages: Int? = nil
    var cover: URL? = nil
    var failedJobID: UUID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                CoverArt(title: title, author: author, remote: cover).frame(width: 60)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Find Source").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(title).font(.title3.weight(.bold)).lineLimit(2)
                    Text(author).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.trailing, 44)
            }
            ManualCopyPicker(title: title, author: author, hardcoverBookID: hardcoverBookID,
                             hardcoverPages: hardcoverPages, cover: cover, failedJobID: failedJobID)
        }
        .padding(24)
        .frame(width: 560)
    }
}

/// Enqueue once and send only an in-app status event. The queue returns an
/// existing active job UUID for duplicate requests; failed/cancelled jobs are
/// retried instead, so those correctly receive the "queued" confirmation.
@discardableResult
@MainActor
private func enqueueSourceDownload(title: String, author: String, hardcoverBookID: Int? = nil,
                                   hardcoverPages: Int? = nil, cover: URL? = nil) -> Bool {
    let queue = DownloadQueue.shared
    let activeIDs = Set(queue.jobs.filter { $0.stage.isActive }.map(\.id))
    let jobID = queue.enqueue(title: title, author: author, hardcoverBookID: hardcoverBookID,
                              hardcoverPages: hardcoverPages, cover: cover)
    let alreadyRunning = activeIDs.contains(jobID)
    NotificationCenter.default.post(name: .folioDownloadEnqueued, object: nil,
                                    userInfo: ["title": title, "alreadyInProgress": alreadyRunning])
    return alreadyRunning
}

/// Opens a local book, or queues its source search without changing pages.
@MainActor
func readBook(title: String, author: String, hardcoverBookID: Int? = nil, hardcoverPages: Int? = nil, cover: URL? = nil, openWindow: OpenWindowAction) {
    if let local = LibraryStore.shared.localCopy(author: author, title: title) {
        openWindow(id: "reader", value: local.id)
        return
    }
    enqueueSourceDownload(title: title, author: author, hardcoverBookID: hardcoverBookID,
                          hardcoverPages: hardcoverPages, cover: cover)
}

