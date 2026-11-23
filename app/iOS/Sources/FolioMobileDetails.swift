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
    @State private var bookSeries: [HCBookSeries] = []
    @State private var seriesEntries: [HCSeriesBook] = []
    @State private var stats: HCBookStats?
    @State private var edition: HCEdition?
    @State private var topReviews: [HCReview] = []
    @State private var remoteProgress = 0.0
    /// The Hardcover record found for a book that arrived without one (an
    /// unlinked library file or a Goodreads shelf entry).
    @State private var resolvedID: Int?
    @State private var editingMetadata = false
    @State private var choosingHardcover = false
    @State private var choosingSource = false
    @State private var deletingLocal = false
    @State private var removingHardcoverShelf = false
    @State private var resettingProgress = false
    @State private var aboutExpanded = false
    @State private var busy = false
    @State private var notice: String?
    @State private var noticeIsError = false

    init(bookID: UUID) {
        localBookID = bookID
        initialRemote = nil
        if let id = LibraryStore.shared.book(bookID)?.hardcoverBookID { restore(FolioBookPageCache.load(id)) }
    }

    init(book: HCBook) {
        localBookID = nil
        initialRemote = book
        _remoteDetails = State(initialValue: book)
        if book.id > 0 { restore(FolioBookPageCache.load(book.id)) }
    }

    /// Open with the last data shown for this book, so nothing pops in later.
    private mutating func restore(_ snapshot: FolioBookPageCache.Snapshot?) {
        guard let snapshot else { return }
        let page = snapshot.page
        if let book = page.book { _remoteDetails = State(initialValue: book) }
        _myHardcoverBook = State(initialValue: page.userBook)
        _stats = State(initialValue: page.stats)
        _edition = State(initialValue: page.edition)
        _bookSeries = State(initialValue: page.series)
        _seriesEntries = State(initialValue: snapshot.seriesBooks)
        _topReviews = State(initialValue: snapshot.reviews)
        if let total = page.book?.pages ?? page.edition?.pages, total > 0 {
            _remoteProgress = State(initialValue: min(1, Double(page.userBook?.progressPages ?? 0) / Double(total)))
        }
    }

    private var local: LocalBook? {
        if let localBookID { return library.book(localBookID) }
        guard let remote = initialRemote else { return nil }
        // Prefer an explicit Hardcover association, then an exact local copy.
        return library.books.first(where: { $0.hardcoverBookID == remote.id })
            ?? library.localCopy(author: remote.authors, title: remote.title)
    }

    private var linkedID: Int? {
        local?.hardcoverBookID ?? initialRemote.flatMap { $0.id > 0 ? $0.id : nil } ?? resolvedID
    }

    private var remote: HCBook? {
        guard let linkedID else { return nil }
        if remoteDetails?.id == linkedID { return remoteDetails }
        return initialRemote?.id == linkedID ? initialRemote : nil
    }

    private var title: String { local?.title ?? remote?.title ?? initialRemote?.title ?? "Book" }
    private var author: String { local?.author ?? remote?.authors ?? initialRemote?.authors ?? "" }
    private var pages: Int? { local?.hardcoverPages ?? remote?.pages ?? edition?.pages }
    private var overview: String? {
        let value = local?.summary ?? (remote ?? initialRemote)?.description?.plainText
        return value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : value
    }

    /// The byline as author pages: Hardcover ids when known, names otherwise.
    private var authorRoutes: [FolioMobileAuthorRoute] {
        if let refs = remote?.authorRefs, !refs.isEmpty {
            return refs.map { FolioMobileAuthorRoute(name: $0.name, id: $0.id) }
        }
        return FolioAuthorNames.split(author).map { FolioMobileAuthorRoute(name: $0, id: nil) }
    }

    /// Status shown on the single status control: Hardcover's when the book is
    /// on a Hardcover shelf, otherwise the library's.
    private var currentStatus: HCStatus? {
        myHardcoverBook?.status ?? local?.status.hardcover
    }

    private var canSyncHardcover: Bool { linkedID != nil && hardcover.isConnected }

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
                VStack(alignment: .leading, spacing: 24) {
                    hero
                    primaryActions
                    readingCard
                    if let notice {
                        Label(notice, systemImage: noticeIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(noticeIsError ? FolioTheme.danger : FolioTheme.success)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let overview, !overview.isEmpty { about(overview) }
                    ratingsCard
                    seriesSection
                    detailsSection
                    if let local, !library.data.collections.isEmpty { collectionsSection(local) }
                }
                .padding(20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(title)
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
                cover: (remote ?? initialRemote)?.imageURL,
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
        .task(id: "\(linkedID ?? 0)-\(hardcover.isConnected)") { await loadHardcoverData() }
        .task(id: "\(local?.id.uuidString ?? title)-\(hardcover.isConnected)") { await resolveHardcover() }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: 17) {
            Group {
                if let local, library.coverURL(local) != nil {
                    FolioMobileCover(book: local)
                } else {
                    FolioMobileRemoteCover(url: (remote ?? initialRemote)?.imageURL, title: title)
                }
            }
            .frame(width: sizeClass == .compact ? 110 : 142,
                   height: sizeClass == .compact ? 158 : 202)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 14, x: 3, y: 7)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: sizeClass == .compact ? 26 : 34, weight: .regular, design: .serif))
                    .foregroundStyle(FolioTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                byline
                heroFacts
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    /// The quick facts good reading apps put beside the cover: community
    /// rating, place in the series, length and year. Each opens its page.
    @ViewBuilder
    private var heroFacts: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let linkedID, let rating = stats?.rating ?? remote?.rating, rating > 0 {
                NavigationLink(value: FolioMobileRatingsRoute(bookID: linkedID, title: title)) {
                    HStack(spacing: 6) {
                        FolioStars(rating: rating, size: 13)
                        Text(rating.formatted(.number.precision(.fractionLength(2))))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(FolioTheme.ink)
                        if let count = stats?.ratingsCount ?? remote?.ratingsCount, count > 0 {
                            Text("(\(count.formatted(.number.notation(.compactName))))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .monospacedDigit()
                }
                .buttonStyle(.plain)
                .accessibilityHint("Show ratings and reviews")
            }
            if let series = bookSeries.first {
                NavigationLink(value: FolioMobileSeriesRoute(id: series.id, name: series.name, currentBookID: linkedID)) {
                    Label {
                        Text(series.position.map { "Book \($0.formatted()) of \(series.name)" } ?? series.name)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    } icon: {
                        Image(systemName: "books.vertical")
                    }
                    .font(.footnote)
                    .foregroundStyle(FolioTheme.olive)
                }
                .buttonStyle(.plain)
            } else if let local, let series = nonEmpty(local.series) {
                Label(local.seriesIndex.map { "Book \($0.formatted()) of \(series)" } ?? series, systemImage: "books.vertical")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            let facts = [pages.map { "\($0.formatted()) pages" }, (local?.publishedYear ?? remote?.year).map { String($0) }]
                .compactMap { $0 }
            if !facts.isEmpty {
                Text(facts.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    /// Each author opens their page.
    @ViewBuilder
    private var byline: some View {
        let routes = Array(authorRoutes.prefix(3))
        if routes.isEmpty {
            Text("Unknown Author").font(.subheadline).foregroundStyle(.secondary)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { authorLinks(routes) }
                VStack(alignment: .leading, spacing: 4) { authorLinks(routes) }
            }
        }
    }

    private func authorLinks(_ routes: [FolioMobileAuthorRoute]) -> some View {
        ForEach(routes, id: \.self) { route in
            NavigationLink(value: route) {
                Text(route.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(FolioTheme.olive)
                    .underline(color: FolioTheme.olive.opacity(0.35))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Open author page")
        }
    }

    private var primaryActions: some View {
        VStack(spacing: 10) {
            if let local {
                FolioGlassButton(title: local.progress > 0 && local.status != .finished ? "Continue Reading" : "Read",
                                 systemImage: "book.fill", prominent: true, fullWidth: true) {
                    navigation.read(local.id)
                }
                .accessibilityIdentifier("folio.readBook")
            } else {
                FolioGlassButton(title: "Find Source", systemImage: "magnifyingglass", prominent: true, fullWidth: true) {
                    FolioMobileDownloadNotice.enqueue(
                        title: title,
                        author: author,
                        hardcoverBookID: linkedID,
                        hardcoverPages: pages,
                        cover: (remote ?? initialRemote)?.imageURL
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
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        // The title sits on the page; the bar keeps it only as the back label.
        ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if let local {
                    Button("Edit Book Details", systemImage: "square.and.pencil") { editingMetadata = true }
                    ShareLink(item: library.fileURL(local)) {
                        Label("Export File", systemImage: "square.and.arrow.up")
                    }
                    if local.progress > 0 || local.lastOpenedAt != nil {
                        Button("Reset Progress", systemImage: "arrow.counterclockwise") { resettingProgress = true }
                    }
                    Section("Hardcover") {
                        Button(local.hardcoverBookID == nil ? "Match with Hardcover" : "Change Match",
                               systemImage: "link") { choosingHardcover = true }
                            .disabled(!hardcover.isConnected)
                        if local.hardcoverBookID != nil {
                            if local.format == .epub, hardcover.isConnected {
                                Button("Update EPUB Details & Cover", systemImage: "arrow.down.doc") {
                                    Task { await updateEPUB(local.id) }
                                }
                                .disabled(busy || remote == nil)
                            }
                            Button("Unlink", systemImage: "link.badge.minus") { unlink(local) }
                        }
                    }
                } else {
                    Button("Choose a Source", systemImage: "list.bullet") { choosingSource = true }
                    Button("View Downloads", systemImage: "arrow.down.circle") { navigation.openDownloads() }
                }
                if let url = remote?.webURL {
                    Link(destination: url) { Label("Open on Hardcover", systemImage: "arrow.up.right.square") }
                }
                if let myHardcoverBook, hardcover.isConnected, myHardcoverBook.id > 0 {
                    Button("Remove from Hardcover Shelves", systemImage: "minus.circle", role: .destructive) {
                        removingHardcoverShelf = true
                    }
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

    // MARK: Reading

    /// One status control, one progress bar and, on Hardcover, your stars.
    @ViewBuilder
    private var readingCard: some View {
        if local == nil && !hardcover.isConnected {
            HStack(spacing: 12) {
                Text("Connect Hardcover to track this book.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Connect") { navigation.openSettings() }
                    .folioGlassPill()
            }
            .detailPanel()
        } else if local != nil || linkedID != nil {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    statusMenu
                    Spacer(minLength: 8)
                    progressLabel
                }
                progressSlider
                if canSyncHardcover, let myHardcoverBook {
                    Divider()
                    HStack {
                        Text("Your rating").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        ratingStars(myHardcoverBook)
                    }
                }
            }
            .detailPanel()
        }
    }

    private var statusOptions: [HCStatus] {
        canSyncHardcover ? HCStatus.allCases : [.wantToRead, .reading, .read]
    }

    private var statusMenu: some View {
        Menu {
            ForEach(statusOptions) { status in
                Button {
                    choose(status)
                } label: {
                    Label(status.label, systemImage: currentStatus == status ? "checkmark" : status.symbol)
                }
            }
            if currentStatus != nil {
                Divider()
                Button("Clear Status", systemImage: "xmark", role: .destructive) { clearStatus() }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: currentStatus?.symbol ?? "plus")
                Text(currentStatus?.label ?? "Add to Shelf")
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 4)
        }
        .folioGlassPill(prominent: currentStatus == nil)
        .disabled(busy)
        .accessibilityLabel("Reading status, \(currentStatus?.label ?? "none")")
    }

    /// Books outside the library track pages on Hardcover while being read.
    private var remotePagesTotal: Int? {
        guard local == nil, canSyncHardcover, let total = pages, total > 0,
              currentStatus == .reading || currentStatus == .paused else { return nil }
        return total
    }

    /// The one progress control: drag it, and Hardcover follows when you let go.
    @ViewBuilder
    private var progressSlider: some View {
        if let local {
            Slider(
                value: Binding(
                    get: { min(1, library.book(local.id)?.progress ?? 0) },
                    set: { fraction in library.update(local.id) { $0.progress = min(1, max(0, fraction)) } }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing { FolioHardcoverProgressSync.push(local.id, store: library, hardcover: hardcover) }
                }
            )
            .tint(FolioTheme.olive)
            .accessibilityLabel("Reading progress")
        } else if let total = remotePagesTotal {
            Slider(value: $remoteProgress, in: 0...1, onEditingChanged: { editing in
                if !editing { savePages(Int((remoteProgress * Double(total)).rounded())) }
            })
            .tint(FolioTheme.olive)
            .accessibilityLabel("Pages read")
        }
    }

    @ViewBuilder
    private var progressLabel: some View {
        if let local {
            Text(local.progressLabel)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        } else if let total = remotePagesTotal {
            Text("p. \(Int((remoteProgress * Double(total)).rounded())) of \(total)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func ratingStars(_ item: HCUserBook) -> some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { number in
                Button {
                    myHardcoverBook?.rating = Double(number)
                    Task {
                        await hardcover.setRating(userBookID: item.id, rating: Double(number))
                        if let linkedID {
                            myHardcoverBook = try? await hardcover.userBook(bookID: linkedID)
                            saveSnapshot()
                        }
                    }
                } label: {
                    Image(systemName: number <= Int((item.rating ?? 0).rounded()) ? "star.fill" : "star")
                        .font(.title3)
                        .foregroundStyle(FolioTheme.caution)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rate \(number) stars")
            }
        }
    }

    private func choose(_ status: HCStatus) {
        if let local {
            library.setStatus(local.id, status.local)
        }
        guard canSyncHardcover, let linkedID else { return }
        Task {
            busy = true
            let updated = await hardcover.setStatus(bookID: linkedID, status: status)
            busy = false
            if let updated {
                myHardcoverBook = updated
                saveSnapshot()
            } else {
                showError(hardcover.lastError ?? "Could not update status.")
            }
        }
    }

    private func clearStatus() {
        if let local { library.setStatus(local.id, .none) }
        if myHardcoverBook != nil, hardcover.isConnected { removingHardcoverShelf = true }
    }

    private func savePages(_ page: Int) {
        guard let linkedID, let total = pages else { return }
        Task {
            busy = true
            await hardcover.setProgress(bookID: linkedID, pages: min(total, max(0, page)))
            myHardcoverBook = try? await hardcover.userBook(bookID: linkedID)
            busy = false
        }
    }

    // MARK: About, ratings, series, details

    private func about(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.body)
                .foregroundStyle(FolioTheme.ink)
                .lineLimit(aboutExpanded ? nil : 6)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if text.count > 320 {
                Button(aboutExpanded ? "Less" : "More") {
                    withAnimation(.easeInOut(duration: 0.2)) { aboutExpanded.toggle() }
                }
                .font(.subheadline)
                .foregroundStyle(FolioTheme.olive)
            }
        }
    }

    @ViewBuilder
    private var ratingsCard: some View {
        if let linkedID, let stats, (stats.ratingsCount ?? 0) > 0 {
            let route = FolioMobileRatingsRoute(bookID: linkedID, title: title)
            VStack(alignment: .leading, spacing: 16) {
                NavigationLink(value: route) {
                    HStack {
                        Text("Ratings & Reviews").font(.folioDisplay(.title3)).foregroundStyle(FolioTheme.ink)
                        Spacer()
                        Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                FolioMobileRatingsSummary(stats: stats)
                ForEach(topReviews.prefix(2)) { review in
                    Divider()
                    FolioMobileReviewRow(review: review, lineLimit: 4)
                }
                if let count = stats.reviewsCount, count > 0 {
                    NavigationLink(value: route) {
                        Text(count == 1 ? "Read the review" : "Read all \(count.formatted()) reviews")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(FolioTheme.olive)
                    }
                    .buttonStyle(.plain)
                }
            }
            .detailPanel()
        }
    }

    /// The saga as a shelf of covers, with this book marked.
    @ViewBuilder
    private var seriesSection: some View {
        if let first = bookSeries.first {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(first.name)
                        .font(.folioDisplay(.title2))
                        .foregroundStyle(FolioTheme.ink)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    NavigationLink("See all", value: FolioMobileSeriesRoute(id: first.id, name: first.name, currentBookID: linkedID))
                        .font(.subheadline)
                        .foregroundStyle(FolioTheme.olive)
                }
                if seriesEntries.isEmpty {
                    NavigationLink(value: FolioMobileSeriesRoute(id: first.id, name: first.name, currentBookID: linkedID)) {
                        Text(first.position.map { "Book \($0.formatted())" } ?? "Explore the series")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(seriesEntries) { entry in
                                    seriesTile(entry)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .contentMargins(.horizontal, 20)
                        .padding(.horizontal, -20)
                        .onAppear {
                            if let linkedID { proxy.scrollTo(linkedID, anchor: .center) }
                        }
                    }
                }
                ForEach(bookSeries.dropFirst().prefix(2), id: \.id) { other in
                    NavigationLink(value: FolioMobileSeriesRoute(id: other.id, name: other.name, currentBookID: linkedID)) {
                        HStack {
                            Text(other.name).font(.subheadline).foregroundStyle(FolioTheme.ink)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func seriesTile(_ entry: HCSeriesBook) -> some View {
        let isCurrent = entry.book.id == linkedID
        return NavigationLink(value: entry.book) {
            VStack(alignment: .leading, spacing: 6) {
                FolioMobileRemoteCover(url: entry.book.imageURL, title: entry.book.title)
                    .frame(width: 92, height: 134)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(isCurrent ? FolioTheme.olive : .clear, lineWidth: 2.5)
                    }
                Text(entry.position.map { "Book \($0.formatted())" } ?? entry.book.title)
                    .font(.caption.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? FolioTheme.olive : .secondary)
                    .lineLimit(1)
            }
            .frame(width: 92, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
        .id(entry.book.id)
        .accessibilityLabel("\(entry.position.map { "Book \($0.formatted()), " } ?? "")\(entry.book.title)")
    }

    private var hasDetails: Bool {
        local != nil || edition != nil || nonEmpty(local?.publisher) != nil
    }

    @ViewBuilder
    private var detailsSection: some View {
        if hasDetails {
        VStack(alignment: .leading, spacing: 11) {
            Text("Details").font(.folioDisplay(.title3)).foregroundStyle(FolioTheme.ink)
            if let publisher = nonEmpty(local?.publisher) ?? nonEmpty(edition?.publisher) {
                LabeledContent("Publisher", value: publisher)
            }
            if let published = publishedText {
                LabeledContent("Published", value: published)
            }
            if let format = nonEmpty(edition?.format) {
                LabeledContent("Edition", value: format.capitalized)
            }
            if let language = nonEmpty(local?.language) ?? nonEmpty(edition?.language) {
                LabeledContent("Language", value: language.count <= 3
                               ? (Locale.current.localizedString(forLanguageCode: language) ?? language) : language)
            }
            if let isbn = nonEmpty(local?.isbn) ?? nonEmpty(edition?.isbn13) ?? nonEmpty(edition?.isbn10) {
                LabeledContent("ISBN") { Text(isbn).textSelection(.enabled).monospacedDigit() }
            }
            if let local {
                LabeledContent("File", value: local.format.label)
                LabeledContent("Added", value: local.addedAt.formatted(date: .abbreviated, time: .omitted))
            }
        }
        .font(.subheadline)
        .detailPanel()
        }
    }

    private var publishedText: String? {
        // The year is already beside the cover; only a full date adds anything.
        guard let date = stats?.releaseDate ?? edition?.releaseDate, date.count >= 10 else { return nil }
        return date.folioReadableDate
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func collectionsSection(_ local: LocalBook) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Collections").font(.folioDisplay(.title3)).foregroundStyle(FolioTheme.ink)
            ForEach(library.data.collections) { collection in
                Button {
                    library.toggle(local.id, in: collection.id)
                } label: {
                    HStack {
                        Text(collection.name).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: local.collections.contains(collection.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(FolioTheme.olive)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .detailPanel()
    }

    // MARK: Loading and actions

    private func unlink(_ local: LocalBook) {
        library.update(local.id) {
            $0.hardcoverBookID = nil
            $0.hardcoverPages = nil
            $0.hardcoverSlug = nil
            $0.hardcoverAutoLinkChecked = true
            $0.hardcoverManuallyUnlinked = true
        }
        resolvedID = nil
        remoteDetails = nil
        clearHardcoverData()
    }

    /// Every book page gets the same Hardcover data: books without a record
    /// are matched by title and author, and library files keep the link.
    @MainActor
    private func resolveHardcover() async {
        // A library copy opened from a Hardcover shelf keeps that record from now on.
        if let local, local.hardcoverBookID == nil, local.hardcoverManuallyUnlinked != true,
           let remoteID = initialRemote?.id, remoteID > 0 {
            library.update(local.id) {
                $0.hardcoverBookID = remoteID
                if $0.hardcoverPages == nil { $0.hardcoverPages = initialRemote?.pages }
                $0.hardcoverSlug = initialRemote?.slug
            }
            return
        }
        guard linkedID == nil, hardcover.isConnected, local?.hardcoverManuallyUnlinked != true else { return }
        guard let match = await FolioHardcoverMatch.find(title: title, author: author, hardcover: hardcover),
              linkedID == nil else { return }
        if let local {
            library.update(local.id) {
                $0.hardcoverBookID = match.id
                if $0.hardcoverPages == nil { $0.hardcoverPages = match.pages }
                $0.hardcoverSlug = match.slug
            }
        } else {
            resolvedID = match.id
        }
    }

    /// Shows the cached page (if this is a different book than what is on
    /// screen), then refreshes from Hardcover. A failed refresh keeps what is shown.
    @MainActor
    private func loadHardcoverData() async {
        guard let linkedID else { return }
        if remoteDetails?.id != linkedID {
            clearHardcoverData()
            if let snapshot = FolioBookPageCache.load(linkedID) { apply(snapshot) }
        }
        guard hardcover.isConnected else { return }
        if let local { FolioHardcoverProgressSync.push(local.id, store: library, hardcover: hardcover) }
        // Hardcover limits requests per minute: reviews, bars and the series of a
        // page seen moments ago are fresh enough; only the book and your shelf reload.
        let recentlyLoaded = FolioBookPageCache.load(linkedID).map {
            Date().timeIntervalSince($0.saved) < 10 * 60 && !$0.seriesBooks.isEmpty == !$0.page.series.isEmpty
        } ?? false
        guard let page = try? await hardcover.bookPage(id: linkedID), !Task.isCancelled else { return }
        if let book = page.book { remoteDetails = book }
        myHardcoverBook = page.userBook
        if let total = pages, total > 0 {
            remoteProgress = min(1, Double(myHardcoverBook?.progressPages ?? 0) / Double(total))
        }
        edition = page.edition
        bookSeries = page.series
        var fresh = page.stats
        // Keep the bars on screen while the distribution refreshes.
        if let old = stats?.distribution, !old.isEmpty { fresh?.distribution = old }
        stats = fresh
        if recentlyLoaded {
            saveSnapshot()
            return
        }
        saveSnapshot()

        async let distribution = hardcover.ratingDistribution(bookID: linkedID)
        async let reviews = try? hardcover.reviews(bookID: linkedID, limit: 2)
        if let first = bookSeries.first {
            let rows = (try? await hardcover.seriesBooks(first.id)) ?? []
            if !rows.isEmpty { seriesEntries = rows.map { HCSeriesBook(position: $0.position, book: $0.book) } }
        } else {
            seriesEntries = []
        }
        let bars = await distribution
        if !bars.isEmpty { stats?.distribution = bars }
        if let list = await reviews { topReviews = list }
        guard !Task.isCancelled else { return }
        saveSnapshot()
    }

    private func apply(_ snapshot: FolioBookPageCache.Snapshot) {
        if let book = snapshot.page.book { remoteDetails = book }
        myHardcoverBook = snapshot.page.userBook
        stats = snapshot.page.stats
        edition = snapshot.page.edition
        bookSeries = snapshot.page.series
        seriesEntries = snapshot.seriesBooks
        topReviews = snapshot.reviews
    }

    private func clearHardcoverData() {
        myHardcoverBook = nil
        bookSeries = []
        seriesEntries = []
        stats = nil
        edition = nil
        topReviews = []
    }

    private func saveSnapshot() {
        guard let linkedID, remoteDetails?.id == linkedID else { return }
        let page = HCBookPage(book: remoteDetails, userBook: myHardcoverBook, stats: stats,
                              edition: edition, series: bookSeries)
        FolioBookPageCache.save(.init(page: page, seriesBooks: seriesEntries, reviews: topReviews), for: linkedID)
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

/// Finds the Hardcover record for a title and author, remembering answers
/// (including misses) for the session.
@MainActor
enum FolioHardcoverMatch {
    private static var answers: [String: HCBook?] = [:]

    /// "Red Rising (Red Rising Saga, #1)" is "Red Rising".
    static func plainTitle(_ title: String) -> String {
        var t = title
        if let open = t.range(of: " (", options: .backwards), t.hasSuffix(")") { t = String(t[..<open.lowerBound]) }
        return t.trimmingCharacters(in: .whitespaces)
    }

    static func find(title: String, author: String, hardcover: HardcoverClient) async -> HCBook? {
        let key = BookMatch.key(author: author, title: title)
        if let known = answers[key] { return known }
        let wanted = plainTitle(title)
        guard !BookAutoMatch.words(wanted).isEmpty,
              let results = try? await hardcover.search(wanted) else { return nil }
        let firstAuthor = FolioAuthorNames.split(author).first ?? author
        // Search ranks the most-read edition first; take the first exact title and author.
        let match = results.first { candidate in
            BookAutoMatch.sameTitle(wanted, plainTitle(candidate.title)) &&
                FolioAuthorNames.split(candidate.authors).contains { BookAutoMatch.sameAuthor(firstAuthor, $0) }
        }
        answers[key] = .some(match)
        return match
    }
}

extension TrackedBook {
    /// A Goodreads shelf entry opens the same book page as everything else.
    var folioBook: HCBook {
        HCBook(id: hardcoverBookID ?? 0, title: title, authors: author,
               imageURL: coverURL.flatMap(URL.init(string:)), year: year, pages: pages,
               rating: averageRating, ratingsCount: nil, description: nil, slug: nil)
    }
}

/// Sends a library book's reading progress to Hardcover as pages, so the app
/// and Hardcover agree without a separate page field.
@MainActor
enum FolioHardcoverProgressSync {
    static func push(_ bookID: UUID, store: LibraryStore, hardcover: HardcoverClient = .shared) {
        guard let book = store.book(bookID), let hcID = book.hardcoverBookID,
              hardcover.isConnected, book.status != .finished,
              let total = book.hardcoverPages, total > 0 else { return }
        let pages = Int((min(1, book.progress) * Double(total)).rounded())
        guard pages > 0, pages != book.syncedProgressPages else { return }
        Task {
            if await hardcover.setProgress(bookID: hcID, pages: pages) {
                store.update(bookID) { $0.syncedProgressPages = pages }
            }
        }
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

/// Compatibility route for callers created before the unified detail screen.
struct FolioMobileRemoteBookDetail: View {
    let book: HCBook

    var body: some View {
        FolioMobileBookDetail(book: book)
    }
}
