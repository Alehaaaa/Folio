import SwiftUI
import UniformTypeIdentifiers
import PDFKit

// MARK: - Book detail (status, rating, progress)

struct HCBookDetail: View {
    @State var book: HCBook
    /// When supplied, the same detail panel shows the local library's editable information.
    let localBookID: UUID?
    @Environment(HardcoverClient.self) private var hc
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var series: [(id: Int, name: String, position: Double?)] = []
    @State private var showAllSeries = false
    @State private var findingCopy = false
    @Environment(\.openWindow) private var openWindow
    @State private var mine: HCUserBook?
    @State private var loaded = false
    @State private var busy = false
    @State private var pages = 0
    @State private var localProgressPercent = 0
    @State private var progressNotice: String?
    @State private var progressFailed = false
    @State private var editingDetails = false
    @State private var selectingCover = false
    @State private var findingHardcover = false
    @State private var hardcoverQuery = ""
    @State private var hardcoverResults: [HCBook] = []
    @State private var searchingHardcover = false
    @State private var updatingEPUB = false
    @State private var actionNotice: String?
    @State private var actionFailed = false
    @Namespace private var glass

    init(book: HCBook) {
        _book = State(initialValue: book)
        localBookID = nil
    }

    @MainActor init(localBookID: UUID) {
        self.localBookID = localBookID
        let local = LibraryStore.shared.book(localBookID)
        _book = State(initialValue: HCBook(
            id: local?.hardcoverBookID ?? -1,
            title: local?.title ?? "Book",
            authors: local?.author ?? "",
            imageURL: nil,
            year: local?.publishedYear,
            pages: local?.hardcoverPages
        ))
    }

    private var local: LocalBook? {
        if let localBookID { return store.book(localBookID) }
        // A book opened from Hardcover can have an exact, explicitly linked local copy.
        // Reuse the same editable detail panel rather than hiding the library actions.
        if book.id > 0 { return store.books.first { $0.hardcoverBookID == book.id } }
        return nil
    }
    private var linkedRemote: HCBook? {
        if let local { return local.hardcoverBookID == book.id ? book : nil }
        return book
    }
    private var displayTitle: String { local?.title ?? book.title }
    private var displayAuthors: String { local?.author ?? book.authors }
    private var displayDescription: String? {
        let value = local?.summary ?? linkedRemote?.description?.plainText
        return value?.isEmpty == true ? nil : value
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 22) {
                    CoverArt(title: displayTitle, author: displayAuthors,
                             local: local.flatMap { store.coverURL($0) },
                             remote: linkedRemote?.imageURL, cornerRadius: 8)
                        .frame(width: 140)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(displayTitle).font(.system(size: 26, weight: .bold, design: .serif)).fixedSize(horizontal: false, vertical: true)
                            .padding(.trailing, 36)
                        AuthorLinks(line: displayAuthors).font(.title3).foregroundStyle(.secondary)
                        if let local {
                            if let name = local.series, !name.isEmpty {
                                SeriesLink(name: name, index: local.seriesIndex).font(.callout).foregroundStyle(.secondary)
                            }
                        } else {
                            ForEach(Array((showAllSeries ? series : Array(series.prefix(2))).enumerated()), id: \.offset) { _, s in
                                SeriesLink(name: s.name, index: s.position, hardcoverID: s.id).font(.callout).foregroundStyle(.secondary)
                            }
                            if series.count > 2 {
                                Button(showAllSeries ? "Show Less" : "\(series.count - 2) More Series…") {
                                    withAnimation(.snappy) { showAllSeries.toggle() }
                                }
                                .buttonStyle(.plain)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                            }
                        }
                        HStack(spacing: 14) {
                            if local == nil, let r = book.rating, r > 0 {
                                HStack(spacing: 4) { StarRating(rating: r); Text(String(format: "%.2f", r)) }
                            }
                            if let y = local?.publishedYear ?? linkedRemote?.year { Text(String(y)) }
                            if let p = local?.hardcoverPages ?? linkedRemote?.pages { Text("\(p) pages") }
                            if let local { Text(local.format.label) }
                        }
                        .font(.callout).foregroundStyle(.secondary)
                        readSection
                            .padding(.top, 14)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                readingSection
                if let local { localOverview(local) }
                if let local {
                    localEditor(local)
                    hardcoverAssociation(local)
                }
                if let d = displayDescription, !d.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("About This Book").font(.headline)
                        Text(d).font(.body).lineSpacing(3).textSelection(.enabled)
                    }
                }
                HStack {
                    if let url = linkedRemote?.webURL { Link(destination: url) { Label("Open on Hardcover", systemImage: "safari") }.buttonStyle(.glass) }
                    if local == nil, let mine {
                        Button(role: .destructive) {
                            Task { busy = true; await hc.remove(userBookID: mine.id); self.mine = nil; busy = false }
                        } label: { Label("Remove from Shelves", systemImage: "trash") }
                        .buttonStyle(.glass)
                    }
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                }
            }
            .padding(28)
        }
        .frame(width: local == nil ? 680 : 760, height: local == nil ? 560 : 630)
        .background {
            CoverArt(title: displayTitle, author: displayAuthors,
                     local: local.flatMap { store.coverURL($0) }, remote: linkedRemote?.imageURL)
                .scaleEffect(2.2).blur(radius: 80).opacity(0.16)
        }
        .task(id: local?.hardcoverBookID ?? book.id) { await refresh() }
        .fileImporter(isPresented: $selectingCover, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { Task { @MainActor in changeCover(url) } }
        }
    }

    private func refresh() async {
        if let local {
            localProgressPercent = Int((min(1, max(0, local.progress)) * 100).rounded())
            guard hc.isConnected, let linkedID = local.hardcoverBookID else {
                mine = nil
                series = []
                loaded = true
                return
            }
            if let full = try? await hc.book(id: linkedID) { book = full }
            if book.id == linkedID {
                mine = try? await hc.userBook(bookID: linkedID)
                series = (try? await hc.series(forBook: linkedID)) ?? []
            }
            pages = mine?.progressPages ?? 0
            loaded = true
            return
        }
        guard hc.isConnected else { loaded = true; return }
        if book.description == nil || book.slug == nil, let full = try? await hc.book(id: book.id) { book = full }
        mine = try? await hc.userBook(bookID: book.id)
        series = (try? await hc.series(forBook: book.id)) ?? []
        pages = mine?.progressPages ?? 0
        loaded = true
    }

    /// Give the next action the full width of the detail panel, independent of book art.
    @ViewBuilder
    private var readSection: some View {
        if let local = local ?? store.localCopy(author: book.authors, title: book.title) {
            Button { openWindow(id: "reader", value: local.id); PopupCenter.shared.close() } label: {
                Label(local.status == .finished ? "Read Again" : (local.progress > 0.001 || local.lastOpenedAt != nil ? "Continue Reading" : "Start Reading"),
                      systemImage: "book.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(BookPrimaryActionStyle())
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .accessibilityIdentifier("bookDetail.primaryAction")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Button { findingCopy.toggle() } label: {
                    Label("Find Source", systemImage: "magnifyingglass")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(BookPrimaryActionStyle())
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .help("Find a readable copy using your configured sources")
                .accessibilityIdentifier("bookDetail.primaryAction")
                if findingCopy {
                    GlassCard(padding: 14) {
                        FindCopyView(title: book.title, author: book.authors, hardcoverBookID: book.id,
                                     hardcoverPages: book.pages, cover: book.imageURL)
                    }
                }
            }
        }
    }

    /// Shelf and progress are primary book actions, so they stay visible without
    /// expanding the metadata editor or looking through a context menu.
    private var readingSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "book.pages")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.10), in: .rect(cornerRadius: 11))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reading & Progress").font(.headline)
                    Text(local != nil ? "Your reading position is saved on this Mac" : "Track this book on your Hardcover shelves")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let local {
                    Label(local.status == .finished ? "Finished" : "In Library", systemImage: local.status == .finished ? "checkmark.circle.fill" : "books.vertical.fill")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                } else if let status = mine?.status {
                    Label(status.label, systemImage: status.symbol)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            Text("Reading shelf")
                .font(.callout.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                if let local {
                    localStatusPicker(local).padding(.vertical, 2)
                } else if hc.isConnected {
                    statusPicker.padding(.vertical, 2)
                }
            }
            if let local {
                localProgressControls(local)
            } else if hc.isConnected {
                hardcoverProgressControls
            } else {
                HStack(alignment: .center, spacing: 12) {
                    Text("Connect Hardcover to choose a shelf and update reading progress.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    SettingsLink { Text("Connect Hardcover…") }.buttonStyle(.glass)
                }
            }

            if hc.isConnected, let mine, linkedRemote != nil {
                HStack(spacing: 10) {
                    Text("Your rating").font(.callout).foregroundStyle(.secondary)
                    StarPicker(rating: mine.rating) { rating in
                        self.mine?.rating = rating
                        Task { await hc.setRating(userBookID: mine.id, rating: rating) }
                    }
                }
            }
            if let local, local.hardcoverBookID != nil, hc.isConnected {
                HStack(spacing: 8) {
                    Label("Linked to Hardcover", systemImage: "link")
                    if let remotePages = mine?.progressPages, remotePages > 0 {
                        Text("· \(remotePages) pages synced")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.background.secondary, in: .rect(cornerRadius: 17))
    }

    private func localProgressControls(_ local: LocalBook) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Divider()
            HStack {
                Text("Reading progress").font(.callout.weight(.semibold))
                Spacer()
                Text(local.progressLabel)
                    .font(.callout.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: max(0, min(1, local.progress)))
                .tint(.accentColor)

            if local.status == .finished {
                Text("This book is marked Finished. Move it to Reading to change its position.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    Text("Set position")
                        .font(.callout)
                    TextField("Percent", value: $localProgressPercent, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 62)
                        .accessibilityLabel("Reading position percentage")
                    Text("%")
                        .foregroundStyle(.secondary)
                    Button("Update Progress") { saveLocalProgress(local) }
                        .buttonStyle(BookSecondaryActionStyle())
                        .disabled(busy || localProgressPercent < 0 || localProgressPercent >= 100)
                        .accessibilityIdentifier("bookDetail.localUpdateProgress")
                    Spacer(minLength: 0)
                }
                Text("Updates the saved reading position. To complete the book, select Finished above.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let progressNotice {
                Label(progressNotice, systemImage: progressFailed ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(progressFailed ? Color.orange : Color.secondary)
            }
        }
    }

    @ViewBuilder
    private var hardcoverProgressControls: some View {
        VStack(alignment: .leading, spacing: 11) {
            Divider()
            if mine?.status == .reading, let total = book.pages, total > 0 {
                HStack {
                    Text("Reading progress").font(.callout.weight(.semibold))
                    Spacer()
                    Text("\(mine?.progressPages ?? 0) of \(total) pages")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: Double(max(0, min(total, mine?.progressPages ?? 0))), total: Double(total))
                    .tint(.accentColor)
                HStack(spacing: 10) {
                    Text("Page")
                    TextField("Page", value: $pages, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                        .accessibilityLabel("Current page on Hardcover")
                    Text("of \(total)").foregroundStyle(.secondary)
                    Button("Update Progress") {
                        Task {
                            busy = true
                            await hc.setProgress(bookID: book.id, pages: pages)
                            await refresh()
                            busy = false
                        }
                    }
                    .buttonStyle(.glass)
                    .disabled(busy || pages < 0 || pages > total || pages == mine?.progressPages)
                    .accessibilityIdentifier("bookDetail.hardcoverUpdateProgress")
                    Spacer(minLength: 0)
                }
                .font(.callout)
            } else if mine?.status == .reading {
                Text("Hardcover doesn't provide a page count for this edition. You can still track its reading shelf above.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text(mine == nil ? "Choose Currently Reading above to begin tracking pages." : "Move this book to Currently Reading to update its page progress.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// A local percentage must also update the saved chapter or PDF page: the
    /// reader restores that position and will otherwise overwrite the percentage.
    private func saveLocalProgress(_ local: LocalBook) {
        guard !busy, local.status != .finished, (0..<100).contains(localProgressPercent) else { return }
        busy = true
        defer { busy = false }
        progressNotice = nil
        let fraction = Double(localProgressPercent) / 100
        if local.format == .pdf {
            guard let pdf = PDFDocument(url: store.fileURL(local)), pdf.pageCount > 0 else {
                progressFailed = true
                progressNotice = "The PDF couldn't be read. No progress was changed."
                return
            }
            let page = min(pdf.pageCount - 1, max(0, Int((fraction * Double(pdf.pageCount - 1)).rounded())))
            store.update(local.id) {
                $0.position.pdfPage = page
                $0.progress = Double(page + 1) / Double(pdf.pageCount)
            }
        } else {
            do {
                let content = try store.webContent(local)
                let lengths = content.chapterSizes
                let total = lengths.reduce(0, +)
                guard !lengths.isEmpty, total > 0 else {
                    progressFailed = true
                    progressNotice = "This book has no readable chapters. No progress was changed."
                    return
                }
                let target = fraction * total
                var before = 0.0
                for (index, length) in lengths.enumerated() {
                    if before + length >= target || index == lengths.count - 1 {
                        let chapterFraction = max(0, min(0.999, (target - before) / max(length, 1)))
                        store.update(local.id) {
                            $0.position.chapter = index
                            $0.position.fraction = chapterFraction
                            $0.progress = fraction
                        }
                        break
                    }
                    before += length
                }
            } catch {
                progressFailed = true
                progressNotice = "Couldn't update this book's position: \(error.localizedDescription)"
                return
            }
        }
        progressFailed = false
        progressNotice = "Saved. Your next reading session starts near this position."
        localProgressPercent = Int((min(1, max(0, store.book(local.id)?.progress ?? fraction)) * 100).rounded())
    }

    private func localStatusPicker(_ local: LocalBook) -> some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(ReadingStatus.allCases, id: \.rawValue) { status in
                    let selected = local.status == status
                    let button = Button {
                        store.setStatus(local.id, status, hardcover: hc)
                    } label: {
                        Label(status == .none ? "Not Started" : status.label,
                              systemImage: selected ? "checkmark.circle.fill" : status.symbol)
                            .font(.callout)
                            .padding(.horizontal, 4)
                    }
                    button.buttonStyle(BookShelfStatusStyle(selected: selected)).disabled(updatingEPUB)
                }
            }
        }
    }

    private func localOverview(_ local: LocalBook) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 18) {
                Label("Added \(local.addedAt.formatted(date: .abbreviated, time: .omitted))", systemImage: "calendar")
                if let date = local.lastOpenedAt {
                    Label("Last read \(date.formatted(date: .abbreviated, time: .omitted))", systemImage: "clock")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let isbn = local.isbn, !isbn.isEmpty {
                Text("ISBN \(isbn)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if !local.collections.isEmpty {
                HStack(spacing: 8) {
                    ForEach(store.data.collections.filter { local.collections.contains($0.id) }) { group in
                        Text(group.name).font(.caption.weight(.medium))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(.background.secondary, in: Capsule())
                    }
                }
            }
        }
    }

    private func localEditor(_ local: LocalBook) -> some View {
        DisclosureGroup(isExpanded: $editingDetails) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    editText("Title", keyPath: \.title, for: local.id)
                    editText("Author", keyPath: \.author, for: local.id)
                }
                HStack(spacing: 12) {
                    editOptional("Series", keyPath: \.series, for: local.id)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Series #").font(.caption).foregroundStyle(.secondary)
                        TextField("Position", value: Binding(
                            get: { store.book(local.id)?.seriesIndex },
                            set: { n in store.update(local.id) { $0.seriesIndex = n } }
                        ), format: .number)
                        .textFieldStyle(.roundedBorder)
                    }
                    .frame(width: 90)
                }
                HStack(spacing: 12) {
                    editOptional("ISBN", keyPath: \.isbn, for: local.id)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Year").font(.caption).foregroundStyle(.secondary)
                        TextField("Year", value: Binding(
                            get: { store.book(local.id)?.publishedYear },
                            set: { n in store.update(local.id) { $0.publishedYear = n } }
                        ), format: .number)
                        .textFieldStyle(.roundedBorder)
                    }
                    .frame(width: 92)
                }
                HStack(spacing: 12) {
                    editOptional("Publisher", keyPath: \.publisher, for: local.id)
                    editOptional("Language", keyPath: \.language, for: local.id)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Description").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { store.book(local.id)?.summary ?? "" },
                        set: { text in store.update(local.id) { $0.summary = text.isEmpty ? nil : text } }
                    ))
                    .font(.callout)
                    .frame(height: 112)
                    .scrollContentBackground(.hidden)
                    .padding(5)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                }
                HStack(spacing: 10) {
                    Button { selectingCover = true } label: {
                        Label("Choose Library Cover…", systemImage: "photo")
                    }
                    .buttonStyle(.glass)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.fileURL(local)])
                    }
                    .buttonStyle(.glass)
                }
                if store.data.collections.isEmpty {
                    Text("Create collections in the sidebar to organize this book.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Collections").font(.caption).foregroundStyle(.secondary)
                        ForEach(store.data.collections) { group in
                            Button {
                                store.toggle(local.id, in: group.id)
                            } label: {
                                Label(group.name, systemImage: (store.book(local.id)?.collections.contains(group.id) ?? false) ? "checkmark.circle.fill" : "circle")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Text("Edits here change Folio's library information. Use Update EPUB Details & Cover below to write Hardcover details into the EPUB file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 14)
        } label: {
            Label("Edit Book Details", systemImage: "square.and.pencil").font(.headline)
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    private func editText(_ title: String, keyPath: WritableKeyPath<LocalBook, String>, for id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: Binding(
                get: { store.book(id)?[keyPath: keyPath] ?? "" },
                set: { text in store.update(id) { $0[keyPath: keyPath] = text } }
            ))
            .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func editOptional(_ title: String, keyPath: WritableKeyPath<LocalBook, String?>, for id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: Binding(
                get: { store.book(id)?[keyPath: keyPath] ?? "" },
                set: { text in store.update(id) { $0[keyPath: keyPath] = text.isEmpty ? nil : text } }
            ))
            .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func changeCover(_ url: URL) {
        guard let id = local?.id else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let image = NSImage(contentsOf: url), let png = CoverMaker.pngData(image) else {
            actionFailed = true
            actionNotice = "The selected image could not be opened."
            return
        }
        let name = "\(id.uuidString)-custom-\(UUID().uuidString).png"
        do {
            try png.write(to: store.coversDir.appendingPathComponent(name), options: .atomic)
            store.update(id) { $0.coverFileName = name }
            actionFailed = false
            actionNotice = "Library cover updated."
        } catch {
            actionFailed = true
            actionNotice = error.localizedDescription
        }
    }

    private func hardcoverAssociation(_ local: LocalBook) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Hardcover").font(.headline)
                Spacer()
                if let linkedID = local.hardcoverBookID {
                    Text("Linked #\(linkedID)").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let linkedID = local.hardcoverBookID {
                HStack(spacing: 12) {
                    if let remote = linkedRemote {
                        CoverArt(title: remote.title, author: remote.authors, remote: remote.imageURL, cornerRadius: 4)
                            .frame(width: 43)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(linkedRemote?.title ?? "Hardcover book #\(linkedID)")
                            .font(.callout.weight(.semibold))
                        Text("Reading progress can sync with your Hardcover account.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Unlink") {
                        store.update(local.id) {
                            $0.hardcoverBookID = nil
                            $0.hardcoverPages = nil
                            $0.hardcoverSlug = nil
                            $0.hardcoverAutoLinkChecked = true
                        }
                        mine = nil
                    }
                    .buttonStyle(.glass)
                    .disabled(updatingEPUB)
                }
                if local.format == .epub, hc.isConnected {
                    HStack(spacing: 10) {
                        Button {
                            guard let remote = linkedRemote else { return }
                            Task { await updateLocalEPUB(id: local.id, from: remote) }
                        } label: {
                            Label("Update EPUB Details & Cover", systemImage: "arrow.down.doc")
                        }
                        .buttonStyle(.glass)
                        .disabled(linkedRemote == nil || updatingEPUB)
                        if updatingEPUB { ProgressView().controlSize(.small) }
                    }
                    Text("Embeds Hardcover metadata and artwork in the EPUB. The original EPUB is backed up.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !hc.isConnected {
                Text("Connect Hardcover in Settings to link this book and retrieve its details.")
                    .font(.callout).foregroundStyle(.secondary)
                SettingsLink { Text("Connect Hardcover…") }.buttonStyle(.glass)
            } else {
                Text("This library book is not linked to Hardcover.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if hc.isConnected {
                Button(findingHardcover ? "Hide Hardcover Search" : "Find on Hardcover…") {
                    findingHardcover.toggle()
                    if findingHardcover {
                        if hardcoverQuery.isEmpty {
                            hardcoverQuery = [local.title, local.author].filter { !$0.isEmpty }.joined(separator: " ")
                        }
                    } else {
                        hardcoverResults = []
                    }
                }
                .buttonStyle(.glass)
                if findingHardcover {
                    HStack(spacing: 10) {
                        TextField("Title or author", text: $hardcoverQuery)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await searchHardcover() } }
                        Button("Search") { Task { await searchHardcover() } }
                            .buttonStyle(.glass)
                            .disabled(hardcoverQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searchingHardcover)
                    }
                    if searchingHardcover { ProgressView().controlSize(.small) }
                    ForEach(hardcoverResults) { result in
                        HStack(spacing: 12) {
                            CoverArt(title: result.title, author: result.authors, remote: result.imageURL, cornerRadius: 3)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.title).font(.callout.weight(.semibold))
                                Text(result.authors).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("Link") { linkLocal(local.id, to: result) }
                                .buttonStyle(.glassProminent)
                                .disabled(updatingEPUB)
                        }
                    }
                }
            }
            if let actionNotice {
                Label(actionNotice, systemImage: actionFailed ? "exclamationmark.triangle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(actionFailed ? Color.red : Color.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    private func linkLocal(_ id: UUID, to result: HCBook) {
        book = result
        findingHardcover = false
        hardcoverResults = []
        actionNotice = nil
        store.update(id) {
            $0.hardcoverBookID = result.id
            $0.hardcoverPages = result.pages
            $0.hardcoverSlug = result.slug
            $0.hardcoverAutoLinkChecked = true
        }
        if let status = store.book(id)?.status.hardcover {
            Task { await hc.setStatus(bookID: result.id, status: status) }
        }
    }

    private func searchHardcover() async {
        let query = hardcoverQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, hc.isConnected, !searchingHardcover else { return }
        searchingHardcover = true
        defer { searchingHardcover = false }
        do {
            hardcoverResults = try await hc.search(query)
            actionFailed = false
            actionNotice = hardcoverResults.isEmpty ? "No Hardcover matches found. Try a different search." : nil
        } catch {
            hardcoverResults = []
            actionFailed = true
            actionNotice = error.localizedDescription
        }
    }

    private func updateLocalEPUB(id: UUID, from remote: HCBook) async {
        guard !updatingEPUB else { return }
        updatingEPUB = true
        actionNotice = nil
        defer { updatingEPUB = false }
        do {
            try await store.enrichEPUB(id, from: remote)
            actionFailed = false
            actionNotice = "EPUB details and cover updated. The original file is saved in EPUB Backups."
            await refresh()
        } catch {
            actionFailed = true
            actionNotice = error.localizedDescription
        }
    }

    private var statusPicker: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(HCStatus.allCases) { s in
                    statusButton(s)
                }
            }
        }
    }

    @ViewBuilder
    private func statusButton(_ s: HCStatus) -> some View {
        let on = mine?.status == s
        let button = Button {
            Task { busy = true; mine = await hc.setStatus(bookID: book.id, status: s); pages = mine?.progressPages ?? 0; busy = false }
        } label: {
            Label(s.shortLabel, systemImage: s.symbol)
                .font(.callout)
                .padding(.horizontal, 2)
        }
        .help(s.label)
        .disabled(!hc.isConnected || busy)
        button.buttonStyle(BookShelfStatusStyle(selected: on)).glassEffectID(s.rawValue, in: glass)
    }
}
