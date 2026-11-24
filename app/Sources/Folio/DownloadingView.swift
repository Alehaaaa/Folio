import SwiftUI

/// Downloads continue in the queue while the person uses any other part of Folio.
struct DownloadingView: View {
    @State private var downloads = DownloadQueue.shared
    @Environment(LibraryStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var filter: DownloadFilter = .all
    @State private var inspectedJob: DownloadJob?
    @State private var copiedJob: UUID?
    @Namespace private var filterGlass

    private enum DownloadFilter: String, CaseIterable, Identifiable {
        case all = "All", active = "In Progress", attention = "Needs Attention", history = "History"
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .all: "square.grid.2x2"
            case .active: "arrow.down.circle"
            case .attention: "exclamationmark.triangle"
            case .history: "clock.arrow.circlepath"
            }
        }
    }

    private var activeJobs: [DownloadJob] {
        downloads.jobs.filter { $0.stage.isActive }.sorted { $0.createdAt > $1.createdAt }
    }

    private var attentionJobs: [DownloadJob] {
        downloads.jobs.filter { $0.stage == .failed }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var historyJobs: [DownloadJob] {
        downloads.jobs.filter { $0.stage == .completed || $0.stage == .cancelled }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 12) {
                    Text("\(activeJobs.count) active · \(attentionJobs.count) need attention")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(FolioTheme.muted)
                    Spacer(minLength: 8)
                    Label("Parallel downloads", systemImage: "arrow.down.circle.dotted")
                        .font(.callout)
                        .foregroundStyle(FolioTheme.muted)
                    Stepper(value: $downloads.maxConcurrentDownloads, in: 1...8) {
                        Text("\(downloads.maxConcurrentDownloads) at once")
                            .font(.callout.weight(.medium).monospacedDigit())
                            .foregroundStyle(FolioTheme.ink)
                    }
                    .fixedSize()
                    .help("Source limits still apply")
                }
                .accessibilityIdentifier("folio.downloads.concurrency")

                if downloads.jobs.isEmpty {
                    ContentUnavailableView {
                        Label("No Downloads Yet", systemImage: "arrow.down.circle")
                    } description: {
                        Text("Choose Find Source in a book's details to start a download.")
                    }
                    .foregroundStyle(FolioTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    downloadFilters

                    if filter == .all || filter == .active { section("In Progress", jobs: activeJobs) }
                    if filter == .all || filter == .attention { section("Needs Attention", jobs: attentionJobs) }

                    if filter == .all && activeJobs.isEmpty && attentionJobs.isEmpty {
                        Label("All caught up. No downloads need attention.", systemImage: "checkmark.circle")
                            .font(.callout)
                            .foregroundStyle(FolioTheme.muted)
                    }

                    if filter == .all || filter == .history { historySection }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 32)
            // Lined up with the page title, not centered under it.
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .folioScreen()
        .folioPageHeader("Downloads") {
            if !historyJobs.isEmpty {
                FolioHeaderIcon(symbol: "trash", label: "Clear History") {
                    downloads.clearHistory()
                }
                .help("Clear finished and cancelled downloads")
                .accessibilityIdentifier("folio.downloads.clearHistory")
            }
        }
        .sheet(item: $inspectedJob) { selection in
            downloadDetailSheet(for: selection.id)
        }
    }

    /// Quiet olive chips, like the sidebar, instead of system-blue buttons.
    private var downloadFilters: some View {
        HStack(spacing: 6) {
            ForEach(DownloadFilter.allCases) { option in
                let selected = filter == option
                Button {
                    withAnimation(.smooth(duration: 0.25)) { filter = option }
                } label: {
                    Label(option.rawValue, systemImage: option.symbol)
                        .font(.callout.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? FolioTheme.ink : FolioTheme.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background {
                            if selected {
                                Capsule().fill(FolioTheme.olive.opacity(0.22))
                                    .matchedGeometryEffect(id: "filter", in: filterGlass)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show downloads")
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(title)
                .font(.folioDisplay(.title2, weight: .semibold))
                .foregroundStyle(FolioTheme.ink)
            Text("\(count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(FolioTheme.muted)
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if !historyJobs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    sectionTitle("History", count: historyJobs.count)
                    Spacer()
                    if filter == .all && historyJobs.count > 4 {
                        Button("See all") { withAnimation(.smooth(duration: 0.25)) { filter = .history } }
                            .folioGlassPill()
                    }
                }
                rows(filter == .history ? historyJobs : Array(historyJobs.prefix(4)))
                Text("Downloaded books are also in your Library.")
                    .font(.caption)
                    .foregroundStyle(FolioTheme.muted)
            }
        } else if filter == .history {
            ContentUnavailableView("No Download History", systemImage: "clock.arrow.circlepath")
                .foregroundStyle(FolioTheme.muted)
                .frame(maxWidth: .infinity, minHeight: 220)
        }
    }

    @ViewBuilder
    private func section(_ title: String, jobs: [DownloadJob]) -> some View {
        if !jobs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(title, count: jobs.count)
                rows(jobs)
            }
        }
    }

    /// One cream card holding a row per download, with hairlines between.
    private func rows(_ jobs: [DownloadJob]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                if index > 0 {
                    Rectangle().fill(FolioTheme.line.opacity(0.7)).frame(height: 0.5)
                        .padding(.leading, 76)
                }
                row(job)
            }
        }
        .folioCard()
    }

    private func row(_ job: DownloadJob) -> some View {
        HStack(spacing: 14) {
            CoverArt(title: job.title, author: job.author, remote: job.cover, cornerRadius: 4)
                .frame(width: 44, height: 66)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.editionTitle ?? job.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(FolioTheme.ink)
                    .lineLimit(1)
                if !job.author.isEmpty {
                    Text(job.author)
                        .font(.callout)
                        .foregroundStyle(FolioTheme.muted)
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    if job.stage.isActive {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: stageSymbol(job.stage))
                    }
                    Text(job.stage.isActive && !job.statusText.isEmpty ? job.statusText : stageName(job.stage))
                        .lineLimit(1)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(stageColor(job.stage))
            }
            Spacer(minLength: 12)
            quickAction(job)
            Button { inspectedJob = job } label: {
                Image(systemName: "ellipsis")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(FolioTheme.muted)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More options for \(job.title)")
            .help("Download details and options")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func quickAction(_ job: DownloadJob) -> some View {
        if job.stage == .completed, let id = job.importedBookID, store.book(id) != nil {
            Button("Read", systemImage: "book.fill") { openWindow(id: "reader", value: id) }
                .folioGlassPill(prominent: true)
        } else if job.stage == .failed || job.stage == .cancelled {
            Button("Retry", systemImage: "arrow.clockwise") { downloads.retry(job.id) }
                .folioGlassPill(prominent: job.stage == .failed)
        } else if !job.stage.isActive {
            Button("Find Copy", systemImage: "magnifyingglass") { inspectedJob = job }
                .folioGlassPill()
        }
    }

    private func downloadDetailSheet(for id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Download Details")
                    .font(.folioDisplay(.title2, weight: .semibold))
                    .foregroundStyle(FolioTheme.ink)
                Spacer()
                Button("Done") { inspectedJob = nil }
                    .folioGlassPill()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)
            Divider()
            ScrollView {
                if let job = downloads.jobs.first(where: { $0.id == id }) {
                    detailedJob(job).padding(22)
                } else {
                    ContentUnavailableView("Download Removed", systemImage: "tray")
                        .frame(maxWidth: .infinity, minHeight: 220)
                }
            }
        }
        .frame(width: 590, height: 560)
        .background(FolioTheme.paper)
    }

    private func detailedJob(_ job: DownloadJob) -> some View {
        FolioDownloadCard {
            HStack(alignment: .top, spacing: 16) {
                CoverArt(title: job.title, author: job.author, remote: job.cover, cornerRadius: 5)
                    .frame(width: 70)

                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(job.editionTitle ?? job.title).font(.headline).textSelection(.enabled)
                            Text(job.author).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer(minLength: 12)
                        Label(stageName(job.stage), systemImage: stageSymbol(job.stage))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(stageColor(job.stage))
                    }

                    HStack(alignment: .center, spacing: 9) {
                        if job.stage.isActive { ProgressView().controlSize(.small) }
                        Text(job.statusText.isEmpty ? stageName(job.stage) : job.statusText)
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(displayLanguage(job.expectedLanguage)) edition")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    if let error = job.error, !error.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(FolioTheme.caution)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if job.stage == .completed, let id = job.importedBookID, let book = store.book(id) {
                        HStack(spacing: 12) {
                            Label(book.status == .finished ? "Finished" : book.lastOpenedAt == nil ? "Not started" : "Reading progress", systemImage: "book.pages")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ProgressView(value: min(1, max(0, book.progress)))
                                .frame(maxWidth: 170)
                            Text(book.progressLabel)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 8) {
                        actions(for: job)
                    }

                    if !job.detailLog.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(DownloadQueue.diagnostics(job, platform: "macOS"), forType: .string)
                            withAnimation(.snappy) { copiedJob = job.id }
                            Task {
                                try? await Task.sleep(for: .seconds(2))
                                if copiedJob == job.id { withAnimation(.snappy) { copiedJob = nil } }
                            }
                        } label: {
                            Label(copiedJob == job.id ? "Copied" : "Copy Log",
                                  systemImage: copiedJob == job.id ? "checkmark" : "doc.on.doc")
                        }
                        .folioGlassPill()
                        DisclosureGroup("Activity log (\(job.detailLog.count))") {
                            VStack(alignment: .leading, spacing: 5) {
                                // Newest first, like a message feed.
                                ForEach(Array(job.detailLog.enumerated().reversed()), id: \.offset) { _, entry in
                                    Text(entry)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(.top, 6)
                        }
                        .font(.caption)
                        .tint(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actions(for job: DownloadJob) -> some View {
        switch job.stage {
        case .queued, .searching, .choosing, .downloading, .importing:
            Button("Cancel", role: .destructive) { downloads.cancel(job.id) }
                .buttonStyle(.glass)

        case .completed:
            if let bookID = job.importedBookID, let book = store.book(bookID) {
                Button { openWindow(id: "reader", value: bookID) } label: {
                    Label(book.lastOpenedAt == nil ? "Start Reading" : "Continue Reading", systemImage: "book.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                }
                .buttonStyle(BookPrimaryActionStyle())
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                Button("Book Details") { inspectedJob = nil; BookDetailsPresenter.showLocal(bookID) }
                    .buttonStyle(BookSecondaryActionStyle())
                    .controlSize(.regular)
            }
            Button("Dismiss") { downloads.dismiss(job.id) }
                .buttonStyle(.glass)
                .controlSize(.regular)

        case .failed:
            Button { downloads.retry(job.id) } label: {
                Text("Retry").foregroundStyle(.white)
            }
                .buttonStyle(BookPrimaryActionStyle())
            retryLanguageMenu(for: job)
            Button("Choose Source…") { showManualPicker(for: job) }
                .buttonStyle(.glass)
            Button("Dismiss") { downloads.dismiss(job.id) }
                .buttonStyle(.glass)

        case .cancelled:
            Button("Retry") { downloads.retry(job.id) }
                .buttonStyle(.glass)
            retryLanguageMenu(for: job)
            Button("Dismiss") { downloads.dismiss(job.id) }
                .buttonStyle(.glass)
        }
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
            Label("Retry in Language…", systemImage: "globe")
        }
        .buttonStyle(.glass)
    }

    private func showManualPicker(for job: DownloadJob) {
        PopupCenter.shared.show(AnyView(
            FindCopyPanel(title: job.title, author: job.author, hardcoverBookID: job.hardcoverBookID,
                          hardcoverPages: job.hardcoverPages, cover: job.cover, failedJobID: job.id)
        )) {}
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
        case .queued, .searching, .choosing, .downloading, .importing: FolioTheme.olive
        case .completed: FolioTheme.success
        case .failed: FolioTheme.caution
        case .cancelled: FolioTheme.muted
        }
    }
}

/// The detail sheet's card in the nook's cream.
private struct FolioDownloadCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .folioCard()
    }
}
