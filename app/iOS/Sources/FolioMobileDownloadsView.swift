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
    /// The job whose log was just copied, to confirm it on the button.
    @State private var copiedJob: UUID?
    @State private var detailRoute: DetailRoute?

    private enum DetailRoute: Hashable {
        case book(UUID)
        case chooseSource(UUID)
    }

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
        .folioScreen()
        .folioPageHeader("Downloads") {
            if !history.isEmpty {
                FolioHeaderIcon(symbol: "trash", label: "Clear History") {
                    downloads.clearHistory()
                }
                .accessibilityIdentifier("folio.downloads.clearHistory")
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
                    .folioDetailDestinations()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { detailBook = nil }
                        }
                    }
            }
        }
        .sheet(item: $selectedJob, onDismiss: { detailRoute = nil }) { selected in
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
                .folioScreen()
                .navigationDestination(item: $detailRoute) { route in
                    switch route {
                    case .book(let id):
                        FolioMobileBookDetail(bookID: id)
                    case .chooseSource(let id):
                        if let job = downloads.jobs.first(where: { $0.id == id }) {
                            FolioMobileFindSourceView(
                                title: job.title, author: job.author,
                                hardcoverBookID: job.hardcoverBookID,
                                hardcoverPages: job.hardcoverPages, cover: job.cover,
                                failedJobID: job.id
                            )
                        }
                    }
                }
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
                Text(title)
                    .font(.folioDisplay(.title2))
                    .foregroundStyle(FolioTheme.ink)
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
                    Text("History")
                        .font(.folioDisplay(.title2))
                        .foregroundStyle(FolioTheme.ink)
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

            Text(job.editionTitle ?? job.title)
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
                        Text(job.transferLabel.map { "\(stageName(job.stage)) \($0)" } ?? stageName(job.stage))
                            .monospacedDigit()
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
        .folioCard(cornerRadius: 18)
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

    /// One header, one status line, one row of actions, then the log.
    private func jobDetail(_ job: DownloadJob) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 15) {
                FolioMobileRemoteCover(url: job.cover, title: job.title)
                    .frame(width: 68, height: 96)
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 5) {
                    Text(job.editionTitle ?? job.title)
                        .font(.folioDisplay(.title3))
                        .foregroundStyle(FolioTheme.ink)
                        .lineLimit(3)
                    Text(job.author.isEmpty ? "Unknown Author" : job.author)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            jobStatus(job)

            jobActions(for: job)

            if !job.detailLog.isEmpty { activityLog(job) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The stage, what it is doing now, and the error when there is one.
    private func jobStatus(_ job: DownloadJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if job.stage.isActive {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: stageSymbol(job.stage))
                        .foregroundStyle(stageColor(job.stage))
                }
                Text(statusHeadline(job))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(job.stage.isActive ? FolioTheme.ink : stageColor(job.stage))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if let fraction = job.transferFraction {
                ProgressView(value: fraction).tint(FolioTheme.olive)
            }
            if job.stage == .failed, let error = job.error, !error.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(FolioTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .folioCard(cornerRadius: 16)
    }

    /// Live status while working; once finished, the outcome and language.
    private func statusHeadline(_ job: DownloadJob) -> String {
        if job.stage.isActive {
            return job.statusText.isEmpty ? stageName(job.stage) : job.statusLine
        }
        return "\(stageName(job.stage)) · \(displayLanguage(job.expectedLanguage))"
    }

    /// One main action, with everything else in a single menu beside it.
    @ViewBuilder
    private func jobActions(for job: DownloadJob) -> some View {
        HStack(spacing: 10) {
            primaryAction(for: job)
            Menu {
                secondaryActions(for: job)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .frame(width: 26, height: 30)
            }
            .folioGlassPill()
            .accessibilityLabel("More Actions")
        }
    }

    @ViewBuilder
    private func primaryAction(for job: DownloadJob) -> some View {
        if job.stage.isActive {
            FolioGlassButton(title: "Cancel", systemImage: "xmark", fullWidth: true) {
                downloads.cancel(job.id)
            }
        } else if job.stage == .completed, let id = job.importedBookID, library.book(id) != nil {
            FolioGlassButton(title: "Read Now", systemImage: "book.fill", prominent: true, fullWidth: true) {
                selectedJob = nil
                navigation.read(id)
            }
            .accessibilityIdentifier("folio.downloads.read.\(job.id.uuidString)")
        } else {
            FolioGlassButton(title: job.stage == .completed ? "Find Another Copy" : "Retry",
                             systemImage: "arrow.clockwise", prominent: true, fullWidth: true) {
                downloads.retry(job.id)
            }
        }
    }

    @ViewBuilder
    private func secondaryActions(for job: DownloadJob) -> some View {
        if job.stage == .completed, let id = job.importedBookID, library.book(id) != nil {
            Button("Book Details", systemImage: "info.circle") { detailRoute = .book(id) }
        }
        if !job.stage.isActive && !(job.stage == .completed && job.importedBookID.flatMap { library.book($0) } != nil) {
            Menu {
                ForEach(BookLanguage.downloadChoices(current: job.expectedLanguage), id: \.self) { code in
                    Button {
                        downloads.retry(job.id, expectedLanguage: code)
                    } label: {
                        if BookLanguage.code(job.expectedLanguage) == code {
                            Label(BookLanguage.displayName(code), systemImage: "checkmark")
                        } else {
                            Text(BookLanguage.displayName(code))
                        }
                    }
                }
            } label: {
                Label("Retry in Language", systemImage: "globe")
            }
            Button("Choose Source", systemImage: "list.bullet") { detailRoute = .chooseSource(job.id) }
        }
        Button(copiedJob == job.id ? "Copied" : "Copy Log", systemImage: "doc.on.doc") { copyDiagnostics(job) }
        if !job.stage.isActive {
            Divider()
            Button("Dismiss", systemImage: "xmark", role: .destructive) { dismissJob(job.id) }
        }
    }

    /// Newest first, time and message on separate lines, folded by default.
    private func activityLog(_ job: DownloadJob) -> some View {
        let open = expandedLogs.contains(job.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy) {
                    if open { expandedLogs.remove(job.id) } else { expandedLogs.insert(job.id) }
                }
            } label: {
                HStack {
                    Text("Activity")
                        .font(.headline)
                        .foregroundStyle(FolioTheme.ink)
                    Text("\(job.detailLog.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("folio.downloads.activity")

            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(job.detailLog.enumerated().reversed()), id: \.offset) { index, entry in
                        let parts = logParts(entry)
                        VStack(alignment: .leading, spacing: 2) {
                            if let time = parts.time {
                                Text(time)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            Text(parts.message)
                                .font(.footnote)
                                .foregroundStyle(FolioTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 9)
                        if index > 0 { Divider() }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .folioCard(cornerRadius: 16)
                .padding(.top, 12)
                .transition(.opacity)
            }
        }
    }

    /// "14:35:44 · Anna's Archive: …" becomes its time and its message.
    private func logParts(_ entry: String) -> (time: String?, message: String) {
        guard let range = entry.range(of: " · ") else { return (nil, entry) }
        let time = String(entry[..<range.lowerBound])
        guard time.count <= 12, time.first?.isNumber == true else { return (nil, entry) }
        return (time, String(entry[range.upperBound...]))
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
        case .queued, .searching, .choosing, .downloading, .importing: FolioTheme.progress
        case .completed: FolioTheme.success
        case .failed: FolioTheme.danger
        case .cancelled: .secondary
        }
    }

    private func copyDiagnostics(_ job: DownloadJob) {
        UIPasteboard.general.string = DownloadQueue.diagnostics(job, platform: "iOS")
        withAnimation(.snappy) { copiedJob = job.id }
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copiedJob == job.id { withAnimation(.snappy) { copiedJob = nil } }
        }
    }

}

/// Simple source cover used where there is no local book or cached image yet.
struct FolioMobileRemoteCover: View {
    let url: URL?
    let title: String

    var body: some View {
        GeometryReader { geometry in
            FolioCachedImage(url: url) {
                FolioClothCover(title: title, compact: true)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }
}
