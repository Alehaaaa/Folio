import SwiftUI

/// Downloads continue in the queue while the person uses any other part of Folio.
struct DownloadingView: View {
    @State private var downloads = DownloadQueue.shared
    @Environment(LibraryStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var filter: DownloadFilter = .all
    @State private var inspectedJob: DownloadJob?
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
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Downloads").font(.largeTitle.weight(.bold))
                        Text("Manage active downloads and retry those that need attention.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(activeJobs.count) active · \(attentionJobs.count) need attention")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Label("Parallel downloads", systemImage: "arrow.down.circle.dotted")
                        .font(.callout.weight(.medium))
                    Stepper(value: $downloads.maxConcurrentDownloads, in: 1...8) {
                        Text("\(downloads.maxConcurrentDownloads) at once")
                            .font(.callout.monospacedDigit())
                    }
                    .fixedSize()
                    Spacer(minLength: 8)
                    Text("Source limits still apply")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .accessibilityIdentifier("folio.downloads.concurrency")

                if downloads.jobs.isEmpty {
                    ContentUnavailableView {
                        Label("No Downloads Yet", systemImage: "arrow.down.circle")
                    } description: {
                        Text("Choose Find Source in a book's details to start a download.")
                    }
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    downloadFilters

                    if filter == .all || filter == .active { gridSection("In Progress", jobs: activeJobs) }
                    if filter == .all || filter == .attention { gridSection("Needs Attention", jobs: attentionJobs) }

                    if filter == .all && activeJobs.isEmpty && attentionJobs.isEmpty {
                        Label("All caught up — no downloads need attention.", systemImage: "checkmark.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 10)
                    }

                    if filter == .all || filter == .history { historySection }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
            .frame(maxWidth: 1160, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .sheet(item: $inspectedJob) { selection in
            downloadDetailSheet(for: selection.id)
        }
    }

    /// Native macOS 26 glass buttons share a container so the active glass pill
    /// transitions fluidly when a different download category is selected.
    private var downloadFilters: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(DownloadFilter.allCases) { option in
                    filterButton(option)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show downloads")
    }

    @ViewBuilder
    private func filterButton(_ option: DownloadFilter) -> some View {
        let selected = filter == option
        let button = Button {
            withAnimation(.smooth(duration: 0.32)) { filter = option }
        } label: {
            filterLabel(option, selected: selected)
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .accessibilityAddTraits(selected ? [.isSelected] : [])

        if selected {
            button
                .buttonStyle(.glassProminent)
                .tint(.indigo)
                .glassEffectID("download-filter-selection", in: filterGlass)
        } else {
            button.buttonStyle(.glass)
        }
    }

    private func filterLabel(_ option: DownloadFilter, selected: Bool) -> some View {
        Label(option.rawValue, systemImage: option.symbol)
            .font(.callout.weight(selected ? .semibold : .medium))
            .foregroundStyle(selected ? Color.white : Color(nsColor: .labelColor))
            .padding(.horizontal, 6)
            .frame(minHeight: 35)
            .contentShape(Capsule())
    }

    @ViewBuilder
    private var historySection: some View {
        if !historyJobs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("Download History").font(.title2.weight(.bold))
                    Text("\(historyJobs.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    if filter == .all && historyJobs.count > 4 {
                        Button("View All History") { filter = .history }
                            .buttonStyle(.glass)
                    }
                }
                Text("Finished and cancelled jobs. Downloaded books are also in your Library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 238), spacing: 16, alignment: .top)],
                          alignment: .leading, spacing: 16) {
                    ForEach(filter == .history ? historyJobs : Array(historyJobs.prefix(4))) { job in
                        compactTile(job)
                    }
                }
            }
            .padding(.top, 6)
        } else if filter == .history {
            ContentUnavailableView("No Download History", systemImage: "clock.arrow.circlepath")
                .frame(maxWidth: .infinity, minHeight: 220)
        }
    }

    @ViewBuilder
    private func gridSection(_ title: String, jobs: [DownloadJob]) -> some View {
        if !jobs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Text(title).font(.title2.weight(.bold))
                    Text("\(jobs.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 238), spacing: 16, alignment: .top)],
                          alignment: .leading, spacing: 16) {
                    ForEach(jobs) { job in compactTile(job) }
                }
            }
        }
    }

    private func compactTile(_ job: DownloadJob) -> some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Spacer(minLength: 0)
                    CoverArt(title: job.title, author: job.author, remote: job.cover, cornerRadius: 6)
                        .frame(width: 86)
                    Spacer(minLength: 0)
                }
                .frame(height: 133)

                Text(job.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .frame(height: 40, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    if job.stage.isActive { ProgressView().controlSize(.mini) }
                    Image(systemName: stageSymbol(job.stage))
                    Text(stageName(job.stage)).lineLimit(1)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(stageColor(job.stage))

                HStack(spacing: 8) {
                    quickAction(job)
                    Button { inspectedJob = job } label: {
                        Image(systemName: "ellipsis")
                            .font(.callout.weight(.semibold))
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(BookSecondaryActionStyle())
                    .accessibilityLabel("More options for \(job.title)")
                    .help("Download details and options")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func quickAction(_ job: DownloadJob) -> some View {
        if job.stage == .completed, let id = job.importedBookID, store.book(id) != nil {
            Button { openWindow(id: "reader", value: id) } label: {
                Label("Read", systemImage: "book.fill")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(BookPrimaryActionStyle())
        } else if job.stage == .failed || job.stage == .cancelled {
            Button { downloads.retry(job.id) } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(BookPrimaryActionStyle())
        } else {
            Button { inspectedJob = job } label: {
                Label(job.stage.isActive ? "Details" : "Find Copy", systemImage: "info.circle")
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(BookSecondaryActionStyle())
        }
    }

    private func downloadDetailSheet(for id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Download Details").font(.title2.weight(.bold))
                Spacer()
                Button("Done") { inspectedJob = nil }
                    .buttonStyle(.glass)
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
    }

    private func detailedJob(_ job: DownloadJob) -> some View {
        GlassCard(padding: 18) {
            HStack(alignment: .top, spacing: 16) {
                CoverArt(title: job.title, author: job.author, remote: job.cover, cornerRadius: 5)
                    .frame(width: 70)

                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(job.title).font(.headline).textSelection(.enabled)
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
                            .font(.callout).foregroundStyle(.red)
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
                        DisclosureGroup("Activity log (\(job.detailLog.count))") {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(job.detailLog.enumerated()), id: \.offset) { _, entry in
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
                Button("Book Details") { BookDetailsPresenter.showLocal(bookID) }
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
        case .queued, .searching, .choosing, .downloading, .importing: .blue
        case .completed: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }
}
