import SwiftUI
import UIKit

/// The macOS DownloadQueue is the single source of truth on iOS too. It is
/// independent of this view, so downloads continue while another tab or the
/// reader is open and unfinished work resumes after a relaunch.
struct FolioMobileDownloadsView: View {
    @State private var downloads = DownloadQueue.shared
    @Environment(FolioMobileNavigation.self) private var navigation
    @Environment(LibraryStore.self) private var library
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var manualJob: DownloadJob?
    @State private var detailBook: DownloadedBookDetail?
    @State private var selectedJob: SelectedDownloadJob?
    @State private var historyExpanded = false
    @State private var expandedLogs: Set<UUID> = []

    private struct DownloadedBookDetail: Identifiable {
        let id: UUID
    }

    private struct SelectedDownloadJob: Identifiable {
        let id: UUID
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: sizeClass == .compact ? 140 : 175, maximum: 235), spacing: 12, alignment: .top)]
    }

    private var active: [DownloadJob] {
        downloads.jobs.filter { $0.stage.isActive }.sorted { $0.createdAt > $1.createdAt }
    }

    private var failed: [DownloadJob] {
        downloads.jobs.filter { $0.stage == .failed }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var history: [DownloadJob] {
        downloads.jobs.filter {
            $0.stage == .cancelled || $0.stage == .completed
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 10) {
                    Label("Parallel downloads", systemImage: "arrow.down.circle.dotted")
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 8)
                    Stepper(value: $downloads.maxConcurrentDownloads, in: 1...8) {
                        Text("\(downloads.maxConcurrentDownloads) at once")
                            .font(.subheadline.monospacedDigit())
                    }
                    .fixedSize()
                }
                .accessibilityIdentifier("folio.downloads.concurrency")
                if downloads.jobs.isEmpty {
                    ContentUnavailableView {
                        Label("No Downloads Yet", systemImage: "arrow.down.circle")
                    } description: {
                        Text("Choose Find Source from a book's details to add it to your downloads.")
                    }
                    .frame(maxWidth: .infinity, minHeight: 250)
                } else {
                    if !active.isEmpty {
                        downloadSection("In Progress", symbol: "arrow.down.circle", jobs: active)
                    }
                    if !failed.isEmpty {
                        downloadSection("Needs Attention", symbol: "exclamationmark.triangle", jobs: failed)
                    }
                    if active.isEmpty && failed.isEmpty {
                        Label("No active downloads", systemImage: "checkmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !history.isEmpty {
                        historySection
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Downloads")
        .toolbar {
            if !history.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear History", systemImage: "trash") {
                        downloads.clearHistory()
                    }
                    .accessibilityIdentifier("folio.downloads.clearHistory")
                }
            }
        }
        .sheet(item: $manualJob) { job in
            NavigationStack {
                FolioMobileFindSourceView(
                    title: job.title, author: job.author,
                    hardcoverBookID: job.hardcoverBookID,
                    hardcoverPages: job.hardcoverPages, cover: job.cover,
                    failedJobID: job.id
                )
            }
        }
        .sheet(item: $detailBook) { book in
            NavigationStack {
                FolioMobileBookDetail(bookID: book.id)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { detailBook = nil }
                        }
                    }
            }
        }
        .sheet(item: $selectedJob) { selected in
            NavigationStack {
                ScrollView {
                    if let job = downloads.jobs.first(where: { $0.id == selected.id }) {
                        jobDetail(job)
                            .padding(20)
                            .frame(maxWidth: 640)
                            .frame(maxWidth: .infinity)
                    } else {
                        ContentUnavailableView("Download Removed", systemImage: "arrow.down.circle")
                    }
                }
                .navigationTitle("Download Details")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { selectedJob = nil }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func downloadSection(_ title: String, symbol: String, jobs: [DownloadJob]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                Spacer()
                Text("\(jobs.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 12) {
                ForEach(jobs) { job in
                    jobTile(job)
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { historyExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Label("History", systemImage: "clock.arrow.circlepath")
                        .font(.headline)
                    Text("\(history.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: historyExpanded ? "chevron.up" : "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Show or hide completed and cancelled downloads")
            .accessibilityIdentifier("folio.downloads.history")
            if historyExpanded {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 12) {
                    ForEach(history) { job in jobTile(job) }
                }
            }
        }
        .padding(.top, 8)
    }

    /// The grid shows the essentials; the entire cover opens the full job record.
    private func jobTile(_ job: DownloadJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                HStack {
                    Spacer(minLength: 0)
                    Button { selectedJob = SelectedDownloadJob(id: job.id) } label: {
                        FolioMobileRemoteCover(url: job.cover, title: job.title)
                            .frame(width: 94, height: 133)
                            .shadow(color: .black.opacity(0.12), radius: 7, y: 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Details for \(job.title)")
                    Spacer(minLength: 0)
                }

                Menu {
                    Button("Download Details", systemImage: "info.circle") {
                        selectedJob = SelectedDownloadJob(id: job.id)
                    }
                    if job.stage == .completed, let id = job.importedBookID, library.book(id) != nil {
                        Button("Read", systemImage: "book.fill") { navigation.read(id) }
                        Button("Book Details", systemImage: "book.closed") {
                            detailBook = DownloadedBookDetail(id: id)
                        }
                    } else if job.stage.isActive {
                        Button("Cancel Download", systemImage: "xmark.circle", role: .destructive) {
                            downloads.cancel(job.id)
                        }
                    } else {
                        Button("Retry", systemImage: "arrow.clockwise") { downloads.retry(job.id) }
                        if job.stage == .failed {
                            Button("Choose Source", systemImage: "list.bullet") { manualJob = job }
                        }
                        Button("Dismiss", systemImage: "xmark", role: .destructive) {
                            dismissJob(job.id)
                        }
                    }
                    Button("Copy Diagnostics", systemImage: "doc.on.doc") { copyDiagnostics(job) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 30, height: 30)
                        .background(.regularMaterial, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("More options for \(job.title)")
            }

            Text(job.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)

            Text(job.author.isEmpty ? "Unknown Author" : job.author)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 2)

            HStack(spacing: 5) {
                if job.stage.isActive { ProgressView().controlSize(.mini) }
                Group {
                    if job.stage.isActive {
                        Text(stageName(job.stage))
                    } else {
                        Label(stageName(job.stage), systemImage: stageSymbol(job.stage))
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(stageColor(job.stage))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            .accessibilityIdentifier("folio.downloads.status.\(job.id.uuidString)")

            tilePrimaryAction(for: job)
        }
        .frame(maxWidth: .infinity, minHeight: 264, alignment: .topLeading)
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("folio.downloads.job.\(job.id.uuidString)")
    }

    @ViewBuilder
    private func tilePrimaryAction(for job: DownloadJob) -> some View {
        if job.stage == .completed, let id = job.importedBookID, library.book(id) != nil {
            FolioGlassButton(title: "Read", systemImage: "book.fill", prominent: true, fullWidth: true) {
                navigation.read(id)
            }
            .accessibilityIdentifier("folio.downloads.read.\(job.id.uuidString)")
        } else if job.stage == .failed || job.stage == .cancelled || job.stage == .completed {
            FolioGlassButton(title: "Retry", systemImage: "arrow.clockwise", prominent: job.stage == .failed, fullWidth: true) {
                downloads.retry(job.id)
            }
        } else {
            FolioGlassButton(title: "Details", systemImage: "info.circle", fullWidth: true) {
                selectedJob = SelectedDownloadJob(id: job.id)
            }
        }
    }

    /// Full status, diagnostics and advanced actions are available on demand.
    private func jobDetail(_ job: DownloadJob) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 15) {
                FolioMobileRemoteCover(url: job.cover, title: job.title)
                    .frame(width: 76, height: 108)
                VStack(alignment: .leading, spacing: 7) {
                    Text(job.title).font(.title3.weight(.semibold))
                    Text(job.author.isEmpty ? "Unknown Author" : job.author)
                        .font(.subheadline).foregroundStyle(.secondary)
                    Label(stageName(job.stage), systemImage: stageSymbol(job.stage))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(stageColor(job.stage))
                    Text("Language: \(displayLanguage(job.expectedLanguage))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 10) {
                if job.stage.isActive { ProgressView().controlSize(.small) }
                Text(job.statusText.isEmpty ? stageName(job.stage) : job.statusText)
                    .font(.subheadline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            jobActions(for: job)

            if let error = job.error, !error.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Download Failed", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline).foregroundStyle(.red)
                    Text(error)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let lastSourceMessage = job.detailLog.last(where: {
                        $0.localizedCaseInsensitiveContains("source") ||
                        $0.localizedCaseInsensitiveContains("link") ||
                        $0.localizedCaseInsensitiveContains("error")
                    }) {
                        Text(lastSourceMessage)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Button { copyDiagnostics(job) } label: {
                        Label("Copy Error Details", systemImage: "doc.on.doc")
                    }
                    .folioGlassPill()
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.065), in: RoundedRectangle(cornerRadius: 15))
            }

            if !job.detailLog.isEmpty {
                DisclosureGroup("Activity Log (\(job.detailLog.count))", isExpanded: Binding(
                    get: { expandedLogs.contains(job.id) },
                    set: { open in
                        if open { expandedLogs.insert(job.id) }
                        else { expandedLogs.remove(job.id) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(job.detailLog.enumerated()), id: \.offset) { _, entry in
                            Text(entry)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Button { copyDiagnostics(job) } label: {
                            Label("Copy Full Log", systemImage: "doc.on.doc")
                        }
                        .folioGlassPill()
                    }
                    .padding(.top, 8)
                }
                .font(.footnote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func jobActions(for job: DownloadJob) -> some View {
        switch job.stage {
        case .queued, .searching, .choosing, .downloading, .importing:
            Button(role: .destructive) { downloads.cancel(job.id) } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
            .folioGlassPill()

        case .completed:
            if let id = job.importedBookID, library.book(id) != nil {
                VStack(alignment: .leading, spacing: 10) {
                    FolioGlassButton(title: "Read Now", systemImage: "book.fill", prominent: true, fullWidth: true) {
                        selectedJob = nil
                        navigation.read(id)
                    }
                    .accessibilityIdentifier("folio.downloads.read.\(job.id.uuidString)")
                    HStack(spacing: 9) {
                        NavigationLink { FolioMobileBookDetail(bookID: id) } label: {
                            Label("Book Details", systemImage: "info.circle")
                        }
                        .folioGlassPill()
                        Button("Dismiss") { dismissJob(job.id) }
                            .folioGlassPill()
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    Label("The imported book is no longer in your library.", systemImage: "book.closed")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    FolioGlassButton(title: "Find Another Copy", systemImage: "arrow.clockwise", prominent: true, fullWidth: true) {
                        downloads.retry(job.id)
                    }
                    Button("Dismiss") { dismissJob(job.id) }
                        .folioGlassPill()
                }
            }

        case .failed:
            VStack(alignment: .leading, spacing: 10) {
                FolioGlassButton(title: "Retry Download", systemImage: "arrow.clockwise", prominent: true, fullWidth: true) {
                    downloads.retry(job.id)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        retryLanguageMenu(for: job)
                        chooseSourceButton(for: job)
                        Button("Dismiss") { dismissJob(job.id) }.folioGlassPill()
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        retryLanguageMenu(for: job)
                        chooseSourceButton(for: job)
                        Button("Dismiss") { dismissJob(job.id) }.folioGlassPill()
                    }
                }
            }

        case .cancelled:
            VStack(alignment: .leading, spacing: 9) {
                FolioGlassButton(title: "Retry", systemImage: "arrow.clockwise", fullWidth: true) {
                    downloads.retry(job.id)
                }
                retryLanguageMenu(for: job)
                Button("Dismiss") { dismissJob(job.id) }.folioGlassPill()
            }
        }
    }

    private func chooseSourceButton(for job: DownloadJob) -> some View {
        NavigationLink {
            FolioMobileFindSourceView(
                title: job.title, author: job.author,
                hardcoverBookID: job.hardcoverBookID,
                hardcoverPages: job.hardcoverPages, cover: job.cover,
                failedJobID: job.id
            )
        } label: {
            Label("Choose Source", systemImage: "list.bullet")
        }
        .folioGlassPill()
    }

    private func dismissJob(_ id: UUID) {
        selectedJob = nil
        downloads.dismiss(id)
    }

    private func displayLanguage(_ raw: String?) -> String {
        switch BookLanguage.code(raw) ?? BookLanguage.preferred {
        case "en": "English"
        case "es": "Spanish"
        case "de": "German"
        case "fr": "French"
        case "it": "Italian"
        case "pt": "Portuguese"
        default: raw ?? BookLanguage.preferred
        }
    }

    private func retryLanguageMenu(for job: DownloadJob) -> some View {
        Menu {
            ForEach(["en", "es", "fr", "de", "it", "pt"], id: \.self) { code in
                Button {
                    downloads.retry(job.id, expectedLanguage: code)
                } label: {
                    if BookLanguage.code(job.expectedLanguage) == code {
                        Label(displayLanguage(code), systemImage: "checkmark")
                    } else {
                        Text(displayLanguage(code))
                    }
                }
            }
        } label: {
            Label("Retry in Language", systemImage: "globe")
        }
        .folioGlassPill()
    }

    private func stageName(_ stage: DownloadJob.Stage) -> String {
        switch stage {
        case .queued: "Queued"
        case .searching: "Searching"
        case .choosing: "Selecting a Copy"
        case .downloading: "Downloading"
        case .importing: "Adding to Library"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    private func stageSymbol(_ stage: DownloadJob.Stage) -> String {
        switch stage {
        case .queued: "clock"
        case .searching: "magnifyingglass"
        case .choosing: "checkmark.circle"
        case .downloading: "arrow.down.circle"
        case .importing: "books.vertical"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        }
    }

    private func stageColor(_ stage: DownloadJob.Stage) -> Color {
        switch stage {
        case .queued, .searching, .choosing, .downloading, .importing: .blue
        case .completed: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }

    private func copyDiagnostics(_ job: DownloadJob) {
        UIPasteboard.general.string = ([
            "Folio iOS · Download Queue diagnostics",
            "Book: \(job.title) — \(job.author)",
            "Job ID: \(job.id.uuidString)",
            "Stage: \(job.stage.rawValue)",
            "Required EPUB language: \(BookLanguage.code(job.expectedLanguage) ?? "unverified")",
            "Status: \(job.statusText)",
            "Failure: \(job.error ?? "none")",
            "Source activity:"
        ] + job.detailLog).joined(separator: "\n")
    }
}

/// Simple source cover used where there is no local book or cached image yet.
struct FolioMobileRemoteCover: View {
    let url: URL?
    let title: String

    var body: some View {
        GeometryReader { geometry in
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color.indigo.opacity(0.8)
                    VStack(spacing: 6) {
                        Image(systemName: "book.closed.fill")
                        Text(title).font(.caption2.bold()).lineLimit(3).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white)
                    .padding(6)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }
}
