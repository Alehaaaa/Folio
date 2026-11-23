import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// A single native detail experience for a library file, a Hardcover result,
/// or a Hardcover result that is already represented in the local library.
struct FolioMobileBookDetail: View {
    private let localBookID: UUID?
    private let initialRemote: HCBook?

    @Environment(LibraryStore.self) private var library
    @Environment(HardcoverClient.self) private var hardcover
    @Environment(FolioMobileNavigation.self) private var navigation
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @State private var downloads = DownloadQueue.shared
    @State private var remoteDetails: HCBook?
    @State private var myHardcoverBook: HCUserBook?
    @State private var bookSeries: [(id: Int, name: String, position: Double?)] = []
    @State private var pagesRead = ""
    @State private var editingMetadata = false
    @State private var choosingHardcover = false
    @State private var choosingSource = false
    @State private var deletingLocal = false
    @State private var removingHardcoverShelf = false
    @State private var resettingProgress = false
    @State private var busy = false
    @State private var notice: String?
    @State private var noticeIsError = false

    init(bookID: UUID) {
        localBookID = bookID
        initialRemote = nil
    }

    init(book: HCBook) {
        localBookID = nil
        initialRemote = book
        _remoteDetails = State(initialValue: book)
    }

    private var local: LocalBook? {
        if let localBookID { return library.book(localBookID) }
        guard let remote = initialRemote else { return nil }
        // Prefer an explicit Hardcover association, then an exact local copy.
        return library.books.first(where: { $0.hardcoverBookID == remote.id })
            ?? library.localCopy(author: remote.authors, title: remote.title)
    }

    private var linkedID: Int? {
        local?.hardcoverBookID ?? initialRemote.flatMap { $0.id > 0 ? $0.id : nil }
    }

    private var remote: HCBook? {
        guard let linkedID else { return nil }
        if remoteDetails?.id == linkedID { return remoteDetails }
        return initialRemote?.id == linkedID ? initialRemote : nil
    }

    private var title: String { local?.title ?? remote?.title ?? initialRemote?.title ?? "Book" }
    private var author: String { local?.author ?? remote?.authors ?? initialRemote?.authors ?? "" }
    private var pages: Int? { local?.hardcoverPages ?? remote?.pages }
    private var overview: String? {
        let value = local?.summary ?? remote?.description?.plainText
        return value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : value
    }

    private var matchingDownload: DownloadJob? {
        let key = BookMatch.key(author: author, title: title)
        return downloads.jobs.first(where: {
            (linkedID != nil && $0.hardcoverBookID == linkedID) ||
            BookMatch.key(author: $0.author, title: $0.title) == key
        })
    }

    var body: some View {
        ScrollView {
            if localBookID != nil && local == nil {
                ContentUnavailableView("Book Unavailable", systemImage: "book.closed")
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    hero
                    primaryActions
                    readingSection
                    informationSection
                    if let overview, !overview.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("About This Book").font(.folioDisplay(.title3)).foregroundStyle(FolioTheme.ink)
                            Text(overview).font(.body).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if let local {
                        collectionsSection(local)
                        hardcoverSection(local)
                        libraryActions(local)
                    } else {
                        accountConnections
                    }
                    if let remote, let url = remote.webURL {
                        Link(destination: url) {
                            Label("Open on Hardcover", systemImage: "arrow.up.right.square")
                        }
                        .folioGlassPill()
                    }
                    if let notice {
                        Label(notice, systemImage: noticeIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(noticeIsError ? FolioTheme.danger : FolioTheme.success)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Book Details")
        .folioScreen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { detailToolbar }
        .sheet(isPresented: $editingMetadata) {
            if let local {
                FolioMobileEditBook(bookID: local.id)
            }
        }
        .sheet(isPresented: $choosingHardcover) {
            if let local {
                FolioMobileHardcoverLinkSheet(bookID: local.id)
            }
        }
        .sheet(isPresented: $choosingSource) {
            FolioMobileFindSourceView(
                title: title,
                author: author,
                hardcoverBookID: linkedID,
                hardcoverPages: pages,
                cover: remote?.imageURL,
                failedJobID: nil
            )
        }
        .confirmationDialog(
            "Remove this book and its imported file?",
            isPresented: $deletingLocal,
            titleVisibility: .visible
        ) {
            Button("Remove Book", role: .destructive) {
                guard let id = local?.id else { return }
                library.remove(id)
                dismiss()
            }
        }
        .confirmationDialog(
            "Remove this book from your Hardcover shelves?",
            isPresented: $removingHardcoverShelf,
            titleVisibility: .visible
        ) {
            Button("Remove from Shelves", role: .destructive) {
                guard let item = myHardcoverBook else { return }
                Task {
                    busy = true
                    await hardcover.remove(userBookID: item.id)
                    myHardcoverBook = nil
                    busy = false
                }
            }
        }
        .confirmationDialog(
            "Reset your reading progress for this book?",
            isPresented: $resettingProgress,
            titleVisibility: .visible
        ) {
            Button("Reset Progress", role: .destructive) {
                guard let id = local?.id else { return }
                library.update(id) {
                    $0.progress = 0
                    $0.position = ReadingPosition()
                    $0.lastOpenedAt = nil
                }
            }
        }
        .task(id: linkedID) { await loadHardcoverData() }
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 17) {
            Group {
                if let local, library.coverURL(local) != nil {
                    FolioMobileCover(book: local)
                } else {
                    FolioMobileRemoteCover(url: remote?.imageURL, title: title)
                }
            }
            .frame(width: sizeClass == .compact ? 110 : 142,
                   height: sizeClass == .compact ? 158 : 202)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 14, x: 3, y: 7)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 9) {
                Text(title)
                    .font(.system(size: sizeClass == .compact ? 26 : 34, weight: .regular, design: .serif))
                    .foregroundStyle(FolioTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(author.isEmpty ? "Unknown Author" : author)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let local {
                    Label(local.format.label, systemImage: local.format.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    if let year = local?.publishedYear ?? remote?.year {
                        Text(String(year))
                    }
                    if let pages {
                        Text("\(pages) pages")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let rating = remote?.rating, rating > 0 {
                    Label(String(format: "%.1f", rating), systemImage: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    private var primaryActions: some View {
        VStack(spacing: 10) {
            if let local {
                FolioGlassButton(title: local.progress > 0 && local.status != .finished ? "Continue Reading" : "Read",
                                 systemImage: "book.fill", prominent: true, fullWidth: true) {
                    navigation.read(local.id)
                }
                .accessibilityIdentifier("folio.readBook")
                HStack(spacing: 8) {
                    Label(local.status == .none ? "Not Started" : local.status.label,
                          systemImage: local.status.symbol)
                    Spacer(minLength: 8)
                    Text(local.progressLabel).monospacedDigit()
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            } else {
                FolioGlassButton(title: "Find Source", systemImage: "magnifyingglass", prominent: true, fullWidth: true) {
                    FolioMobileDownloadNotice.enqueue(
                        title: title,
                        author: author,
                        hardcoverBookID: linkedID,
                        hardcoverPages: pages,
                        cover: remote?.imageURL
                    )
                }
                .accessibilityIdentifier("folio.findSource")

                if let job = matchingDownload {
                    HStack(spacing: 9) {
                        Image(systemName: job.stage.isActive ? "arrow.down.circle" :
                              job.stage == .failed ? "exclamationmark.triangle" : "checkmark.circle")
                        Text(job.statusText.isEmpty ? job.stage.rawValue.capitalized : job.statusText)
                            .lineLimit(2)
                        Spacer(minLength: 4)
                        Button("Downloads") { navigation.openDownloads() }
                            .folioGlassPill()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                FolioGlassButton(title: "Choose a Source", systemImage: "list.bullet", fullWidth: true) {
                    choosingSource = true
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if local != nil {
                    Button("Edit Book Details", systemImage: "square.and.pencil") { editingMetadata = true }
                    Button("Match with Hardcover", systemImage: "link") { choosingHardcover = true }
                } else {
                    Button("Choose a Source", systemImage: "list.bullet") { choosingSource = true }
                    Button("View Downloads", systemImage: "arrow.down.circle") { navigation.openDownloads() }
                }
                if local != nil {
                    Divider()
                    Button("Remove from Library", systemImage: "trash", role: .destructive) {
                        deletingLocal = true
                    }
                }
            } label: {
                Label("Book Options", systemImage: "ellipsis.circle")
            }
        }
    }

    private var readingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your Reading").font(.folioDisplay(.title3)).foregroundStyle(FolioTheme.ink)
            if let local {
                localReading(local)
            } else if let linkedID {
                hardcoverReading(bookID: linkedID)
            } else {
                Text("Add this book to your library to track your reading.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .detailPanel()
    }

    private func localReading(_ local: LocalBook) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Progress").font(.subheadline)
                Spacer()
                Text(local.progressLabel).foregroundStyle(.secondary)
            }
            ProgressView(value: min(1, local.progress))
            Slider(
                value: Binding(
                    get: { min(1, library.book(local.id)?.progress ?? 0) },
                    set: { fraction in
                        library.update(local.id) { $0.progress = min(1, max(0, fraction)) }
                    }
                ),
                in: 0...1
            )
            .accessibilityLabel("Reading progress")
            Text("Status").font(.subheadline.weight(.medium))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 9) {
                ForEach(ReadingStatus.allCases) { status in
                    let isSelected = local.status == status
                    Button {
                        library.setStatus(local.id, status, hardcover: hardcover)
                    } label: {
                        Label(status == .none ? "Not Started" : status.label,
                              systemImage: isSelected ? "checkmark.circle.fill" : status.symbol)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, minHeight: 33)
                    }
                    .folioGlassPill(prominent: isSelected)
                }
            }
            if let date = local.lastOpenedAt {
                Text("Last opened \(date.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if local.hardcoverBookID != nil {
                remoteReadingControls
            }
        }
    }

    private func hardcoverReading(bookID: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !hardcover.isConnected {
                Text("Connect your Hardcover account to rate this book and track its status.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Go to Account Settings") { navigation.openSettings() }
                    .folioGlassPill()
            } else {
                hardcoverStatuses(bookID: bookID)
                remoteReadingControls
            }
        }
    }

    private func hardcoverStatuses(bookID: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hardcover Shelf").font(.subheadline.weight(.medium))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 9) {
                ForEach(HCStatus.allCases) { status in
                    let isSelected = myHardcoverBook?.status == status
                    Button {
                        Task {
                            busy = true
                            myHardcoverBook = await hardcover.setStatus(bookID: bookID, status: status)
                            pagesRead = String(myHardcoverBook?.progressPages ?? 0)
                            busy = false
                            if myHardcoverBook == nil { showError(hardcover.lastError ?? "Could not update status.") }
                        }
                    } label: {
                        Label(status.shortLabel,
                              systemImage: isSelected ? "checkmark.circle.fill" : status.symbol)
                            .font(.subheadline)
                            .frame(maxWidth: .infinity, minHeight: 33)
                    }
                    .folioGlassPill(prominent: isSelected)
                    .disabled(busy)
                }
            }
        }
    }

    private var remoteReadingControls: some View {
        VStack(alignment: .leading, spacing: 13) {
            if hardcover.isConnected, let myHardcoverBook {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Your Rating").font(.subheadline.weight(.medium))
                    HStack(spacing: 9) {
                        ForEach(1...5, id: \.self) { number in
                            Button {
                                self.myHardcoverBook?.rating = Double(number)
                                Task {
                                    await hardcover.setRating(userBookID: myHardcoverBook.id, rating: Double(number))
                                    if let linkedID {
                                        self.myHardcoverBook = try? await hardcover.userBook(bookID: linkedID)
                                    }
                                }
                            } label: {
                                Image(systemName: number <= Int((myHardcoverBook.rating ?? 0).rounded()) ? "star.fill" : "star")
                                    .font(.title2)
                                    .foregroundStyle(FolioTheme.caution)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Rate \(number) stars")
                        }
                        if let rating = myHardcoverBook.rating {
                            Text(rating.formatted(.number.precision(.fractionLength(1))))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if hardcover.isConnected, let linkedID,
               let total = pages, total > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Hardcover Page Progress").font(.subheadline.weight(.medium))
                    ProgressView(
                        value: Double(min(total, myHardcoverBook?.progressPages ?? 0)),
                        total: Double(total)
                    )
                    HStack {
                        TextField("Pages read", text: $pagesRead)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                        Text("of \(total)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Update") {
                            Task {
                                busy = true
                                await hardcover.setProgress(
                                    bookID: linkedID,
                                    pages: min(total, max(0, Int(pagesRead) ?? 0))
                                )
                                self.myHardcoverBook = try? await hardcover.userBook(bookID: linkedID)
                                busy = false
                            }
                        }
                        .folioGlassPill()
                        .disabled(busy || Int(pagesRead) == nil)
                    }
                }
            }
        }
    }

    private var informationSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Details").font(.folioDisplay(.title3)).foregroundStyle(FolioTheme.ink)
                Spacer()
                if local != nil {
                    Button("Edit", systemImage: "pencil") { editingMetadata = true }
                        .folioGlassPill()
                }
            }
            if let local {
                LabeledContent("Added", value: local.addedAt.formatted(date: .abbreviated, time: .omitted))
                if let series = local.series, !series.isEmpty {
                    LabeledContent("Series", value: local.seriesIndex.map { "\(series) #\($0.formatted())" } ?? series)
                }
                if let isbn = local.isbn, !isbn.isEmpty { LabeledContent("ISBN", value: isbn) }
                if let publisher = local.publisher, !publisher.isEmpty {
                    LabeledContent("Publisher", value: publisher)
                }
                if let language = local.language, !language.isEmpty {
                    LabeledContent("Language", value: language)
                }
            }
            if !bookSeries.isEmpty {
                ForEach(bookSeries.prefix(3), id: \.id) { series in
                    LabeledContent("Hardcover Series", value: series.name)
                }
            }
            if let year = local?.publishedYear ?? remote?.year {
                LabeledContent("Published", value: String(year))
            }
        }
        .detailPanel()
    }

    private func collectionsSection(_ local: LocalBook) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Collections").font(.folioDisplay(.title3)).foregroundStyle(FolioTheme.ink)
                Spacer()
                Text("\(local.collections.count) selected")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if library.data.collections.isEmpty {
                Text("Create collections in Library to organize your books.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(library.data.collections) { collection in
                    Button {
                        library.toggle(local.id, in: collection.id)
                    } label: {
                        HStack {
                            Text(collection.name).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: local.collections.contains(collection.id) ? "checkmark.circle.fill" : "circle")
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .detailPanel()
    }

    private func hardcoverSection(_ local: LocalBook) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Hardcover Association").font(.folioDisplay(.title3)).foregroundStyle(FolioTheme.ink)
                Spacer()
                if let id = local.hardcoverBookID {
                    Label("Linked #\(id)", systemImage: "link")
                        .font(.caption).foregroundStyle(FolioTheme.success)
                }
            }
            if let id = local.hardcoverBookID {
                Text(remote?.title ?? "Hardcover book #\(id)")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    FolioGlassButton(title: "Change Match", systemImage: "magnifyingglass") {
                        choosingHardcover = true
                    }
                    .disabled(!hardcover.isConnected || busy)
                    FolioGlassButton(title: "Unlink", systemImage: "link.badge.minus") {
                        library.update(local.id) {
                            $0.hardcoverBookID = nil
                            $0.hardcoverPages = nil
                            $0.hardcoverSlug = nil
                            $0.hardcoverAutoLinkChecked = true
                        }
                        remoteDetails = nil
                        myHardcoverBook = nil
                        bookSeries = []
                    }
                }
                if !hardcover.isConnected {
                    Text("Connect your Hardcover account in Settings before changing the match or refreshing EPUB metadata.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if local.format == .epub, hardcover.isConnected {
                    Button {
                        Task { await updateEPUB(local.id) }
                    } label: {
                        HStack {
                            Label("Update EPUB Details & Cover", systemImage: "arrow.down.doc")
                            if busy { ProgressView().controlSize(.small) }
                        }
                    }
                    .folioGlassPill(prominent: true)
                    .disabled(busy || remote == nil)
                    Text("Updates the embedded metadata and cover, with a backup of the original EPUB.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if hardcover.isConnected {
                Text("Link this local book to its Hardcover catalogue record.")
                    .font(.subheadline).foregroundStyle(.secondary)
                FolioGlassButton(title: "Find on Hardcover", systemImage: "magnifyingglass") {
                    choosingHardcover = true
                }
            } else {
                Text("Connect Hardcover in Settings to link metadata and synchronize your reading.")
                    .font(.subheadline).foregroundStyle(.secondary)
                FolioGlassButton(title: "Account Settings", systemImage: "person.crop.circle") {
                    navigation.openSettings()
                }
            }
            Divider()
            Label(
                GoodreadsClient.shared.isLinked ? "Goodreads shelves linked" : "Goodreads shelves not linked",
                systemImage: GoodreadsClient.shared.isLinked ? "checkmark.circle.fill" : "books.vertical"
            )
            .font(.subheadline).foregroundStyle(.secondary)
        }
        .detailPanel()
    }

    private var accountConnections: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connections").font(.folioDisplay(.title3)).foregroundStyle(FolioTheme.ink)
            HStack(spacing: 9) {
                Image(systemName: hardcover.isConnected ? "checkmark.circle.fill" : "person.crop.circle.badge.plus")
                    .foregroundStyle(hardcover.isConnected ? .green : .secondary)
                Text(hardcover.isConnected ? "Hardcover account connected" : "Connect Hardcover to save ratings and shelf status.")
                    .font(.subheadline)
            }
            if !hardcover.isConnected {
                FolioGlassButton(title: "Account Settings", systemImage: "gearshape") {
                    navigation.openSettings()
                }
            }
            let goodreads = GoodreadsClient.shared
            Label(
                goodreads.isLinked ? "Goodreads shelves linked" : "Goodreads shelves not linked",
                systemImage: goodreads.isLinked ? "checkmark.circle.fill" : "books.vertical"
            )
            .font(.subheadline).foregroundStyle(.secondary)
            if let myHardcoverBook, hardcover.isConnected {
                Button(role: .destructive) {
                    removingHardcoverShelf = true
                } label: {
                    Label("Remove from Hardcover Shelves", systemImage: "trash")
                }
                .folioGlassPill()
                .disabled(busy || myHardcoverBook.id <= 0)
            }
        }
        .detailPanel()
    }

    private func libraryActions(_ local: LocalBook) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { libraryUtilityActions(local) }
                VStack(alignment: .leading, spacing: 9) { libraryUtilityActions(local) }
            }
            Button(role: .destructive) {
                deletingLocal = true
            } label: {
                Label("Remove from Library", systemImage: "trash")
            }
            .folioGlassPill()
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func libraryUtilityActions(_ local: LocalBook) -> some View {
        FolioGlassButton(title: "Edit Details", systemImage: "square.and.pencil") {
            editingMetadata = true
        }
        ShareLink(item: library.fileURL(local)) {
            Label("Export File", systemImage: "square.and.arrow.up")
        }
        .folioGlassPill()
        FolioGlassButton(title: "Reset Progress", systemImage: "arrow.counterclockwise") {
            resettingProgress = true
        }
    }

    @MainActor
    private func loadHardcoverData() async {
        myHardcoverBook = nil
        bookSeries = []
        guard let linkedID, hardcover.isConnected else { return }
        if let refreshed = try? await hardcover.book(id: linkedID) {
            remoteDetails = refreshed
        }
        myHardcoverBook = try? await hardcover.userBook(bookID: linkedID)
        bookSeries = (try? await hardcover.series(forBook: linkedID)) ?? []
        pagesRead = String(myHardcoverBook?.progressPages ?? 0)
    }

    @MainActor
    private func updateEPUB(_ id: UUID) async {
        guard let remote, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await library.enrichEPUB(id, from: remote)
            noticeIsError = false
            notice = "EPUB metadata and cover updated. Original saved in EPUB Backups."
            await loadHardcoverData()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func showError(_ text: String) {
        noticeIsError = true
        notice = text
    }
}

private struct FolioMobileDetailPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .folioCard(cornerRadius: 18)
    }
}

private extension View {
    func detailPanel() -> some View { modifier(FolioMobileDetailPanel()) }
}

/// Mobile metadata editor has the same editable fields as the macOS detail
/// panel and supports replacing the library artwork from Files.
struct FolioMobileEditBook: View {
    let bookID: UUID
    @Environment(LibraryStore.self) private var store
    @Environment(HardcoverClient.self) private var hardcover
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var author = ""
    @State private var summary = ""
    @State private var series = ""
    @State private var seriesNumber = ""
    @State private var isbn = ""
    @State private var year = ""
    @State private var publisher = ""
    @State private var language = ""
    @State private var choosingCover = false
    @State private var coverError: String?
    @State private var matchingHardcover = false
    @State private var fetching = false
    @State private var fetchNotice: String?
    @State private var fetchFailed = false

    var body: some View {
        NavigationStack {
            Form {
                hardcoverDetailsSection
                Section("Book") {
                    TextField("Title", text: $title)
                    TextField("Author", text: $author)
                    TextField("Description", text: $summary, axis: .vertical).lineLimit(3...8)
                }
                .folioRow()
                Section("Series") {
                    TextField("Series name", text: $series)
                    TextField("Book number", text: $seriesNumber).keyboardType(.decimalPad)
                }
                .folioRow()
                Section("Publication") {
                    TextField("ISBN", text: $isbn)
                    TextField("Year", text: $year).keyboardType(.numberPad)
                    TextField("Publisher", text: $publisher)
                    TextField("Language", text: $language)
                }
                .folioRow()
                Section("Library Cover") {
                    if let book = store.book(bookID) {
                        HStack(spacing: 16) {
                            FolioMobileCover(book: book)
                                .frame(width: 86, height: 123)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 8) {
                                FolioGlassButton(title: "Choose Image", systemImage: "photo") {
                                    choosingCover = true
                                }
                                Text("Changes Folio's library artwork. To embed Hardcover artwork in the EPUB, use Update EPUB Details & Cover.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .folioRow()
            }
            .navigationTitle("Edit Book")
            .folioScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $matchingHardcover, onDismiss: {
                // A new match brings its details straight in, without overwriting edits.
                if let id = store.book(bookID)?.hardcoverBookID, hardcover.isConnected {
                    Task { await fetchDetails(id, replace: false) }
                }
            }) {
                FolioMobileHardcoverLinkSheet(bookID: bookID)
            }
            .fileImporter(isPresented: $choosingCover, allowedContentTypes: [.image]) { result in
                switch result {
                case .success(let url): updateCover(from: url)
                case .failure(let error): coverError = error.localizedDescription
                }
            }
            .alert("Cover Not Updated", isPresented: Binding(
                get: { coverError != nil },
                set: { if !$0 { coverError = nil } }
            )) { Button("OK") { coverError = nil } }
            message: { Text(coverError ?? "") }
        }
        .onAppear(perform: load)
    }

    /// Fills the form from the linked Hardcover record. Missing-only keeps
    /// anything the person already typed; Replace overwrites every field Hardcover has.
    @ViewBuilder
    private var hardcoverDetailsSection: some View {
        let linkedID = store.book(bookID)?.hardcoverBookID
        Section {
            if !hardcover.isConnected {
                Text("Connect Hardcover in Settings to fetch missing details automatically.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if let linkedID {
                Button {
                    Task { await fetchDetails(linkedID, replace: false) }
                } label: {
                    HStack {
                        Label("Fill Missing Details", systemImage: "wand.and.stars")
                        Spacer()
                        if fetching { ProgressView() }
                    }
                }
                .disabled(fetching)
                .accessibilityIdentifier("folio.fillMissingDetails")
                Button {
                    Task { await fetchDetails(linkedID, replace: true) }
                } label: {
                    Label("Replace with Hardcover Details", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(fetching)
                Button {
                    matchingHardcover = true
                } label: {
                    Label("Change Hardcover Match", systemImage: "link")
                }
            } else {
                Button {
                    matchingHardcover = true
                } label: {
                    Label("Find on Hardcover", systemImage: "magnifyingglass")
                }
            }
            if let fetchNotice {
                Label(fetchNotice, systemImage: fetchFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(fetchFailed ? FolioTheme.danger : Color.secondary)
            }
        } header: {
            Text("Hardcover")
        } footer: {
            if hardcover.isConnected {
                Text(linkedID == nil
                     ? "Match this book with Hardcover, then fill in its description, year, series and cover."
                     : "Review the filled fields, then tap Save. A missing cover is added right away.")
            }
        }
        .folioRow()
    }

    @MainActor
    private func fetchDetails(_ hardcoverID: Int, replace: Bool) async {
        guard !fetching else { return }
        fetching = true
        fetchFailed = false
        fetchNotice = nil
        defer { fetching = false }
        do {
            guard let remote = try await hardcover.book(id: hardcoverID) else {
                fetchFailed = true
                fetchNotice = "Hardcover didn't return this book."
                return
            }
            let hcSeries = (try? await hardcover.series(forBook: hardcoverID))?.first
            var filled: [String] = []
            func pick(_ current: String, _ value: String?, _ name: String) -> String {
                let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let existing = current.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty, replace || existing.isEmpty, existing != cleaned else { return current }
                filled.append(name)
                return cleaned
            }
            title = pick(title, remote.title, "title")
            author = pick(author, remote.authors, "author")
            summary = pick(summary, remote.description?.plainText, "description")
            year = pick(year, remote.year.map { String($0) }, "year")
            series = pick(series, hcSeries?.name, "series")
            seriesNumber = pick(seriesNumber, hcSeries?.position.map { String($0.formatted()) }, "book number")
            if let pages = remote.pages {
                store.update(bookID) { if replace || $0.hardcoverPages == nil { $0.hardcoverPages = pages } }
            }
            if let book = store.book(bookID), replace || store.coverURL(book) == nil,
               let url = remote.imageURL, await downloadCover(url) {
                filled.append("cover")
            }
            fetchNotice = filled.isEmpty
                ? "Nothing missing. Hardcover has no extra details for this book."
                : "Filled \(filled.joined(separator: ", ")). Tap Save to keep them."
        } catch {
            fetchFailed = true
            fetchNotice = error.localizedDescription
        }
    }

    @MainActor
    private func downloadCover(_ url: URL) async -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        guard let (bytes, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !bytes.isEmpty, bytes.count <= 15_000_000,
              let image = UIImage(data: bytes),
              let png = CoverMaker.pngData(image) else { return false }
        let filename = "\(bookID.uuidString)-hc-\(UUID().uuidString).png"
        do {
            try png.write(to: store.coversDir.appendingPathComponent(filename), options: .atomic)
            store.update(bookID) { $0.coverFileName = filename }
            return true
        } catch {
            return false
        }
    }

    private func load() {
        guard let book = store.book(bookID) else { return }
        title = book.title
        author = book.author
        summary = book.summary ?? ""
        series = book.series ?? ""
        seriesNumber = book.seriesIndex.map { String($0) } ?? ""
        isbn = book.isbn ?? ""
        year = book.publishedYear.map { String($0) } ?? ""
        publisher = book.publisher ?? ""
        language = book.language ?? ""
    }

    private func save() {
        store.update(bookID) { book in
            book.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            book.author = author.trimmingCharacters(in: .whitespacesAndNewlines)
            book.summary = nilIfBlank(summary)
            book.series = nilIfBlank(series)
            book.seriesIndex = Double(seriesNumber)
            book.isbn = nilIfBlank(isbn)
            book.publishedYear = Int(year)
            book.publisher = nilIfBlank(publisher)
            book.language = nilIfBlank(language)
        }
        dismiss()
    }

    private func nilIfBlank(_ value: String) -> String? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func updateCover(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let image = UIImage(contentsOfFile: url.path),
              let bytes = CoverMaker.pngData(image) else {
            coverError = "The selected image could not be opened."
            return
        }
        let filename = "\(bookID.uuidString)-custom-\(UUID().uuidString).png"
        do {
            try bytes.write(to: store.coversDir.appendingPathComponent(filename), options: .atomic)
            store.update(bookID) { $0.coverFileName = filename }
        } catch {
            coverError = error.localizedDescription
        }
    }
}

/// A safe manual Hardcover association: the user chooses the catalogue record
/// explicitly, then the local file receives its id, page count and slug.
struct FolioMobileHardcoverLinkSheet: View {
    let bookID: UUID
    @Environment(LibraryStore.self) private var store
    @Environment(HardcoverClient.self) private var hardcover
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var matches: [HCBook] = []
    @State private var searching = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Title or author", text: $query)
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    Button {
                        Task { await search() }
                    } label: {
                        HStack {
                            Label("Search Hardcover", systemImage: "magnifyingglass")
                            Spacer()
                            if searching { ProgressView() }
                        }
                    }
                    .folioGlassPill(prominent: true)
                    .disabled(searching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .folioRow()
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(FolioTheme.danger)
                }
                if !matches.isEmpty {
                    Section("Select a Matching Book") {
                        ForEach(matches) { book in
                            Button {
                                link(book)
                            } label: {
                                HStack(spacing: 12) {
                                    FolioMobileRemoteCover(url: book.imageURL, title: book.title)
                                        .frame(width: 48, height: 69)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(book.title).font(.headline)
                                        Text(book.authors).font(.caption).foregroundStyle(.secondary)
                                        if let year = book.year {
                                            Text(String(year)).font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "link")
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .folioRow()
                }
            }
            .navigationTitle("Match on Hardcover")
            .folioScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .task {
            guard let local = store.book(bookID) else { return }
            if query.isEmpty { query = [local.title, local.author].filter { !$0.isEmpty }.joined(separator: " ") }
            if hardcover.isConnected { await search() }
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !searching, hardcover.isConnected else { return }
        searching = true
        defer { searching = false }
        do {
            matches = try await hardcover.search(text)
            error = matches.isEmpty ? "No matching titles. Try a shorter search." : nil
        } catch {
            matches = []
            self.error = error.localizedDescription
        }
    }

    private func link(_ remote: HCBook) {
        store.update(bookID) {
            $0.hardcoverBookID = remote.id
            $0.hardcoverPages = remote.pages
            $0.hardcoverSlug = remote.slug
            $0.hardcoverAutoLinkChecked = true
        }
        if let status = store.book(bookID)?.status.hardcover {
            Task { await hardcover.setStatus(bookID: remote.id, status: status) }
        }
        dismiss()
    }
}

struct FolioMobileDiscoverView: View {
    @Environment(HardcoverClient.self) private var hardcover
    @Environment(FolioMobileNavigation.self) private var navigation

    @State private var query = ""
    @State private var feed = FolioMobileDiscoverFeed()
    @State private var searchHits: [HCBook] = []
    @State private var completedSearch: String?
    @State private var loading = false
    @State private var error: String?
    @State private var activeRequest = UUID()
    @ScaledMetric(relativeTo: .body) private var tileWidth: CGFloat = 118

    private var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearching: Bool { !searchText.isEmpty }
    private var taskKey: String { "\(hardcover.isConnected)|\(searchText)" }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 34) {
                if !hardcover.isConnected {
                    ContentUnavailableView {
                        Label("Connect Hardcover", systemImage: "person.crop.circle.badge.plus")
                    } description: {
                        Text("Connect your Hardcover account in Settings to explore and search books.")
                    } actions: {
                        Button("Open Settings") { navigation.openSettings() }
                            .folioGlassPill(prominent: true)
                    }
                } else if isSearching {
                    if loading || completedSearch != searchText {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else if let error {
                        failureView(error)
                    } else if searchHits.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                    } else {
                        FolioMobileRemoteBookGridSection(
                            title: "Results",
                            books: FolioMobileDiscoverySections.unique(searchHits)
                        )
                    }
                } else if feed.rows.isEmpty {
                    if let message = feed.error {
                        failureView(message)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 160)
                    }
                } else {
                    ForEach(feed.rows) { row in
                        VStack(alignment: .leading, spacing: 14) {
                            Text(row.title)
                                .font(.folioDisplay(.title2))
                                .foregroundStyle(FolioTheme.ink)
                                .accessibilityAddTraits(.isHeader)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 14) {
                                    ForEach(row.books) { book in
                                        FolioMobileRemoteBookTile(book: book, width: min(tileWidth, 180))
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .contentMargins(.horizontal, 20)
                            .padding(.horizontal, -20)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 30)
            .frame(maxWidth: 1120)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Discover")
        .folioScreen()
        .searchable(text: $query, prompt: "Titles, authors or series")
        .refreshable {
            if isSearching { await search(searchText) }
            else { await feed.load(from: hardcover, force: true) }
        }
        .task(id: taskKey) {
            // Invalidate requests as soon as the search changes, not only after debounce.
            activeRequest = UUID()
            if !hardcover.isConnected {
                loading = false
                error = nil
            } else if !isSearching {
                loading = false
                await feed.load(from: hardcover)
            } else {
                loading = true
                do {
                    try await Task.sleep(for: .milliseconds(320))
                    guard !Task.isCancelled else { return }
                    await search(searchText)
                } catch {
                    // A newer search replaced this request.
                }
            }
        }
    }

    @ViewBuilder
    private func failureView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: "wifi.exclamationmark")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry") {
                Task {
                    if isSearching { await search(searchText) }
                    else { await feed.load(from: hardcover, force: true) }
                }
            }
            .folioGlassPill(prominent: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor
    private func search(_ text: String) async {
        guard hardcover.isConnected, !text.isEmpty else { return }
        let requestID = UUID()
        activeRequest = requestID
        loading = true
        error = nil
        defer { if activeRequest == requestID { loading = false } }
        do {
            let books = try await hardcover.search(text)
            guard !Task.isCancelled, activeRequest == requestID else { return }
            searchHits = FolioMobileDiscoverySections.unique(books)
            completedSearch = text
            error = nil
        } catch {
            guard !Task.isCancelled, activeRequest == requestID else { return }
            searchHits = []
            completedSearch = text
            self.error = error.localizedDescription
        }
    }

}

/// Compatibility route for callers created before the unified detail screen.
struct FolioMobileRemoteBookDetail: View {
    let book: HCBook

    var body: some View {
        FolioMobileBookDetail(book: book)
    }
}
