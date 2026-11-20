import SwiftUI
import PDFKit
import Combine
import Translation

struct ReaderWindow: View {
    let bookID: UUID
    @Environment(LibraryStore.self) private var store
    @Environment(HardcoverClient.self) private var hc
    @Environment(ReaderPrefsStore.self) private var prefsStore
    @Environment(\.colorScheme) private var scheme
    @State private var annotations = ReadingAnnotationsStore.shared

    @State private var web: WebReaderModel?
    @State private var pdf: PDFReaderModel?
    @State private var error: String?
    @State private var showTOC = false
    @State private var showThemes = false
    @State private var showAnnotations = false
    @State private var showNoteEditor = false
    @State private var noteDraft = ""
    @State private var editingNoteID: UUID?
    @State private var noteSelection: ReaderSelection?
    @State private var noteChapter = 0
    @State private var noteFraction = 0.0
    @State private var showTranslation = false
    @State private var translatedText = ""
    @State private var translationError: String?
    @State private var translationSource = ""
    @State private var translationLanguage = "es"
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var showFact = false
    @State private var factTitle = ""
    @State private var factText = ""
    @State private var factURL: URL?
    @State private var factLoading = false
    @State private var lastTick = Date()

    private let tick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var book: LocalBook? { store.book(bookID) }
    var dark: Bool { prefsStore.appearance.isDark(systemDark: scheme == .dark) }
    var palette: ReaderTheme.Palette { prefsStore.prefs.theme.palette(dark: dark) }

    var body: some View {
        readerWindow
            .sheet(isPresented: $showNoteEditor) { noteEditor }
            .sheet(isPresented: $showTranslation) { translationSheet }
            .sheet(isPresented: $showFact) { factSheet }
            .translationTask(translationConfig) { session in
                do {
                    let response = try await session.translate(translationSource)
                    translatedText = response.targetText
                    translationError = nil
                } catch {
                    translationError = error.localizedDescription
                }
            }
    }

    private var readerContent: some View {
        ZStack {
            Color(hex: palette.bg).ignoresSafeArea()
            if let web {
                WebReaderView(model: web, config: WebReaderModel.config(prefsStore.prefs, dark: dark, comic: web.content.isComic))
                    .ignoresSafeArea(edges: .bottom)
            } else if let pdf {
                PDFReaderView(model: pdf, prefs: prefsStore.prefs, dark: dark)
            } else if let error {
                ContentUnavailableView("Can't Open This Book", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView()
            }
        }
        .overlay(alignment: .bottom) { bottomBar }
        .overlay(alignment: .bottom) { selectionBar }
        .overlay { pageCorners }
        .overlay(alignment: .leading) { turnButton(-1) }
        .overlay(alignment: .trailing) { turnButton(1) }
    }

    private var readerWindow: some View {
        readerSession
            .onReceive(tick) { now in
                if NSApp.isActive { store.addReading(seconds: min(30, now.timeIntervalSince(lastTick))) }
                lastTick = now
            }
            .onDisappear { finishSession() }
            .preferredColorScheme(prefsStore.appearance == .system ? nil : (dark ? .dark : .light))
    }

    // Keep SwiftUI's type-checking of this heavily modified view in manageable
    // stages. The combined chain can exceed the compiler's expression budget.
    private var readerSession: some View {
        readerPositions
            .onChange(of: annotations.entries) { _, _ in refreshHighlights() }
            .onChange(of: pdf?.pageIndex) { _, _ in savePosition() }
    }

    private var readerPositions: some View {
        readerContent
        .navigationTitle(book?.title ?? "Book")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
        .frame(minWidth: 520, minHeight: 480)
        .task { open() }
        .onChange(of: web?.page) { _, _ in savePosition() }
        .onChange(of: web?.chapter) { _, _ in savePosition() }
        .onChange(of: web?.ready) { _, ready in if ready == true { refreshHighlights() } }
    }

    private var subtitle: String {
        if let web { return web.chapterTitle }
        if let pdf { return "Page \(pdf.pageIndex + 1) of \(pdf.pageCount)" }
        return book?.author ?? ""
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { showTOC.toggle() } label: { Label("Contents", systemImage: "list.bullet") }
                .help("Table of Contents")
                .popover(isPresented: $showTOC, arrowEdge: .bottom) { tocList }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                prefsStore.appearance = dark ? .light : .dark
            } label: {
                Label(dark ? "Switch to Light Mode" : "Switch to Dark Mode", systemImage: dark ? "sun.max" : "moon")
            }
            .help(dark ? "Light Mode" : "Dark Mode")
            Button { showAnnotations.toggle() } label: {
                Label("Annotations", systemImage: "highlighter")
            }
            .help("Bookmarks, highlights, notes and quotes")
            .popover(isPresented: $showAnnotations, arrowEdge: .bottom) { annotationsPanel }
            Button { showThemes.toggle() } label: { Label("Themes & Settings", systemImage: "textformat.size") }
                .help("Themes & Settings")
                .popover(isPresented: $showThemes, arrowEdge: .bottom) { ThemePanel() }
            if let book {
                Menu {
                    ForEach(ReadingStatus.allCases.filter { $0 != .none }) { s in
                        Button { store.setStatus(book.id, s, hardcover: hc) } label: {
                            Label(s.label, systemImage: book.status == s ? "checkmark" : s.symbol)
                        }
                    }
                } label: { Label("Status", systemImage: book.status.symbol) }
                .help("Reading status")
            }
        }
    }

    private var tocEntries: [TOCEntry] { web?.content.toc ?? pdf?.toc ?? [] }

    private var tocList: some View {
        ScrollViewReader { proxy in
            List {
                if tocEntries.isEmpty {
                    Text("This book has no table of contents.").foregroundStyle(.secondary)
                }
                ForEach(tocEntries) { e in
                    Button {
                        if let web { web.go(e) } else { pdf?.go(e.chapter) }
                        showTOC = false
                    } label: {
                        HStack {
                            Text(e.title).lineLimit(2)
                                .fontWeight(isCurrent(e) ? .semibold : .regular)
                            Spacer()
                            if pdf != nil { Text("\(e.chapter + 1)").foregroundStyle(.secondary).monospacedDigit() }
                        }
                        .padding(.leading, CGFloat(e.level) * 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .id(e.id)
                }
            }
            .frame(width: 320, height: 440)
            .onAppear { if let cur = tocEntries.last(where: { isCurrent($0) || $0.chapter <= (web?.chapter ?? pdf?.pageIndex ?? 0) }) { proxy.scrollTo(cur.id, anchor: .center) } }
        }
    }

    private func isCurrent(_ e: TOCEntry) -> Bool {
        if let web { return web.content.toc.last(where: { $0.chapter <= web.chapter })?.id == e.id }
        return false
    }

    // MARK: Page turning & bar

    private func turnButton(_ dir: Int) -> some View {
        Button {
            if dir > 0 { web?.next() ?? pdf?.next() } else { web?.previous() ?? pdf?.previous() }
        } label: {
            Image(systemName: dir > 0 ? "chevron.right" : "chevron.left")
                .font(.title3.weight(.semibold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .padding(.horizontal, 10)
        .opacity(prefsStore.prefs.navigation == .pages ? 0.85 : 0)
        .help(dir > 0 ? "Next Page" : "Previous Page")
        .keyboardShortcut(dir > 0 ? .rightArrow : .leftArrow, modifiers: [])
    }

    private var progress: Double { web?.progress ?? pdf?.progress ?? 0 }
    private var atEnd: Bool { web?.atEnd ?? pdf?.atEnd ?? false }

    @ViewBuilder
    private var bottomBar: some View {
        if web != nil || pdf != nil {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    HStack(spacing: 10) {
                        if let web {
                            Text(web.pagesLeftInChapter == 0 ? "Last page in chapter" : "\(web.pagesLeftInChapter) pages left in chapter")
                        } else if let pdf {
                            Text("\(pdf.pageIndex + 1) of \(pdf.pageCount)")
                        }
                        Slider(value: Binding(get: { progress }, set: { v in
                            if let web { web.seek(v) } else if let pdf { pdf.go(Int(v * Double(pdf.pageCount - 1))) }
                        }), in: 0...1)
                        .frame(width: 180)
                        .controlSize(.mini)
                        Text("\(Int((progress * 100).rounded()))%").monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)

                    if atEnd, let book, book.status != .finished {
                        Button {
                            store.setStatus(book.id, .finished, hardcover: hc)
                        } label: { Label("Mark as Finished", systemImage: "checkmark.circle.fill") }
                        .buttonStyle(.glassProminent)
                    }
                }
            }
            .padding(.bottom, 14)
        }
    }

    // MARK: Bookmarks, selection and reading tools

    private var currentChapter: Int { web?.chapter ?? pdf?.pageIndex ?? 0 }
    private var currentFraction: Double { web?.chapterFraction ?? 0 }

    @ViewBuilder
    private var pageCorners: some View {
        if let book, web != nil || pdf != nil {
            let marked = annotations.bookmark(bookID: book.id, chapter: currentChapter,
                                               fraction: currentFraction, pageCount: web?.pages)
            let activeCorner = marked.map { PageFoldCorner(rawValue: $0.corner ?? "") ?? .topRight }
            GeometryReader { geometry in
                ForEach(PageFoldCorner.allCases) { corner in
                    Button {
                        annotations.toggleBookmark(bookID: book.id, chapter: currentChapter,
                                                   fraction: currentFraction, pageCount: web?.pages,
                                                   corner: corner.rawValue)
                    } label: {
                        FoldedPageCorner(corner: corner, folded: activeCorner == corner, dark: dark,
                                         pageColor: Color(hex: palette.bg))
                            .frame(width: 38, height: 38)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(activeCorner == corner ? "Unfold page corner" : "Fold page corner to bookmark")
                    .accessibilityLabel(activeCorner == corner ? "Remove page bookmark" : "Bookmark this page at \(corner.label)")
                    .position(
                        x: corner.isRight ? geometry.size.width - 19 : 19,
                        y: corner.isBottom ? geometry.size.height - 19 : 19
                    )
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private var selectionBar: some View {
        if let selection = web?.selection ?? pdf?.selection,
           !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            HStack(spacing: 9) {
                Text(selection.text.replacingOccurrences(of: "\n", with: " "))
                    .font(.caption)
                    .lineLimit(1)
                    .frame(maxWidth: 150)
                    .foregroundStyle(.secondary)
                Divider().frame(height: 20)
                Button { addSelection(.highlight) } label: { Label("Highlight", systemImage: "highlighter") }
                Button { beginNote(with: selection) } label: { Label("Note", systemImage: "note.text.badge.plus") }
                Button { lookUp(selection) } label: { Label("Define", systemImage: "text.book.closed") }
                Menu {
                    Button("English") { translate(selection.text, to: "en") }
                    Button("Español") { translate(selection.text, to: "es") }
                    Button("Français") { translate(selection.text, to: "fr") }
                    Button("Deutsch") { translate(selection.text, to: "de") }
                    Button("Italiano") { translate(selection.text, to: "it") }
                    Button("Português") { translate(selection.text, to: "pt") }
                } label: { Label("Translate", systemImage: "character.book.closed") }
                Button { addSelection(.quote) } label: { Label("Quote", systemImage: "quote.bubble") }
                Button { lookupFact(selection.text) } label: { Label("Fun Fact", systemImage: "sparkles") }
                Button { clearSelection() } label: { Image(systemName: "xmark") }
                    .help("Dismiss selection")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: .capsule)
            .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.14), radius: 10, y: 3)
            .padding(.horizontal, 60)
            .padding(.bottom, 64)
            .transition(.opacity)
        }
    }

    private func addSelection(_ kind: ReadingAnnotationKind) {
        guard let book, let selection = web?.selection ?? pdf?.selection,
              !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        _ = annotations.add(bookID: book.id, chapter: currentChapter, fraction: currentFraction,
                            kind: kind, text: selection.text, prefix: selection.prefix,
                            suffix: selection.suffix, note: "")
        refreshHighlights()
        clearSelection()
    }

    private func beginNote(with selection: ReaderSelection) {
        noteDraft = ""
        editingNoteID = nil
        noteSelection = selection
        noteChapter = currentChapter
        noteFraction = currentFraction
        showNoteEditor = true
    }

    private func editNote(_ entry: ReadingAnnotation) {
        noteDraft = entry.note
        editingNoteID = entry.id
        noteSelection = nil
        showAnnotations = false
        showNoteEditor = true
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editingNoteID == nil ? "Add a note" : "Edit note").font(.title3.weight(.semibold))
            if let selection = noteSelection {
                Text(selection.text).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            TextEditor(text: $noteDraft)
                .font(.body)
                .frame(minHeight: 140)
                .border(.quaternary)
            HStack {
                Spacer()
                Button("Cancel") { showNoteEditor = false }
                Button("Save Note") { saveNote() }
                    .buttonStyle(.borderedProminent)
                    .disabled(noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 470)
    }

    private func saveNote() {
        guard let book else { return }
        if let editingNoteID {
            annotations.updateNote(id: editingNoteID, note: noteDraft)
        } else if let selection = noteSelection {
            _ = annotations.add(bookID: book.id, chapter: noteChapter, fraction: noteFraction,
                                kind: .note, text: selection.text, prefix: selection.prefix,
                                suffix: selection.suffix, note: noteDraft)
        }
        showNoteEditor = false
        clearSelection()
        refreshHighlights()
    }

    private var annotationsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your annotations").font(.headline).padding(.horizontal, 14).padding(.top, 12)
            if let book {
                let entries = annotations.items(for: book.id).sorted { $0.createdAt > $1.createdAt }
                if entries.isEmpty {
                    ContentUnavailableView("No annotations yet", systemImage: "bookmark",
                                           description: Text("Fold a page corner or select text to save a highlight, note or quote."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(entries) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                Button {
                                    jump(to: entry)
                                    showAnnotations = false
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Label(annotationLabel(entry.kind), systemImage: annotationSymbol(entry.kind))
                                            .font(.caption.weight(.semibold))
                                        if !entry.text.isEmpty { Text(entry.text).lineLimit(3).font(.callout) }
                                        if !entry.note.isEmpty { Text(entry.note).lineLimit(3).font(.caption).foregroundStyle(.secondary) }
                                        Text("Location \(entry.chapter + 1)").font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                if entry.kind == .note {
                                    Button { editNote(entry) } label: { Image(systemName: "pencil") }.help("Edit note")
                                }
                                if entry.kind == .quote {
                                    Button { copyQuote(entry.text) } label: { Image(systemName: "doc.on.doc") }.help("Copy quote")
                                }
                                Button {
                                    annotations.remove(id: entry.id)
                                } label: { Image(systemName: "trash") }
                                    .foregroundStyle(.secondary)
                                    .help("Delete annotation")
                            }
                            .padding(.vertical, 5)
                        }
                    }
                    .listStyle(.plain)
                }
            }
        }
        .frame(width: 390, height: 440)
    }

    private func annotationLabel(_ kind: ReadingAnnotationKind) -> String {
        switch kind {
        case .bookmark: "Page Marker"
        case .highlight: "Highlight"
        case .note: "Note"
        case .quote: "Saved Quote"
        }
    }

    private func annotationSymbol(_ kind: ReadingAnnotationKind) -> String {
        switch kind {
        case .bookmark: "bookmark.fill"
        case .highlight: "highlighter"
        case .note: "note.text"
        case .quote: "quote.bubble"
        }
    }

    private func jump(to entry: ReadingAnnotation) {
        if let web { web.load(entry.chapter, target: .fraction(entry.fraction)) }
        else { pdf?.go(entry.chapter) }
    }

    private func refreshHighlights() {
        guard let book else { return }
        let items = annotations.items(for: book.id).filter {
            $0.kind == .highlight || $0.kind == .note
        }
        if let web { web.showHighlights(items.filter { $0.chapter == web.chapter }) }
        if let pdf { pdf.showHighlights(items) }
    }

    private func clearSelection() {
        web?.clearSelection()
        pdf?.clearSelection()
    }

    private func copyQuote(_ text: String) {
        let author = book?.author ?? ""
        let title = book?.title ?? ""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("“\(text)” — \(author), \(title)", forType: .string)
    }

    private func lookUp(_ selection: ReaderSelection) {
        let term = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed),
              let url = URL(string: "dict://" + encoded) else { return }
        NSWorkspace.shared.open(url)
    }

    private func translate(_ text: String, to language: String) {
        translationSource = text
        translationLanguage = language
        translatedText = ""
        translationError = nil
        showTranslation = true
        translationConfig?.invalidate()
        translationConfig = TranslationSession.Configuration(source: nil, target: Locale.Language(identifier: language))
    }

    private var translationSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Translate selection").font(.title3.weight(.semibold))
            Text(translationSource).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            if let translationError {
                Text(translationError).foregroundStyle(.secondary)
            } else if translatedText.isEmpty {
                ProgressView("Translating…")
            } else {
                Text(translatedText).font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                if !translatedText.isEmpty {
                    Button("Copy Translation") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(translatedText, forType: .string)
                    }
                }
                Button("Close") { showTranslation = false }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 500, alignment: .leading)
    }

    private func lookupFact(_ selection: String) {
        let phrase = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return }
        let topic = String(phrase.prefix(80))
        factTitle = topic
        factText = ""
        factURL = nil
        factLoading = true
        showFact = true
        Task {
            do {
                var url = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
                url.queryItems = [
                    URLQueryItem(name: "action", value: "query"),
                    URLQueryItem(name: "prop", value: "extracts"),
                    URLQueryItem(name: "exintro", value: "1"),
                    URLQueryItem(name: "explaintext", value: "1"),
                    URLQueryItem(name: "redirects", value: "1"),
                    URLQueryItem(name: "format", value: "json"),
                    URLQueryItem(name: "titles", value: topic)
                ]
                var request = URLRequest(url: url.url!)
                request.setValue("Folio Reader/1.0 (reading reference)", forHTTPHeaderField: "User-Agent")
                let (data, _) = try await URLSession.shared.data(for: request)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let query = json?["query"] as? [String: Any]
                let pages = query?["pages"] as? [String: [String: Any]]
                if let page = pages?.values.first, page["missing"] == nil,
                   let extract = page["extract"] as? String, !extract.isEmpty {
                    factTitle = page["title"] as? String ?? topic
                    factText = String(extract.prefix(1500))
                    if let id = page["pageid"] as? Int {
                        factURL = URL(string: "https://en.wikipedia.org/?curid=\(id)")
                    }
                } else {
                    factText = "No verified article was found for this selection. Try selecting a name, place or subject."
                }
            } catch {
                factText = "Couldn't retrieve a reference right now: \(error.localizedDescription)"
            }
            factLoading = false
        }
    }

    private var factSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(factTitle).font(.title3.weight(.semibold))
            if factLoading {
                ProgressView("Looking up a reliable fact…")
            } else {
                ScrollView { Text(factText).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 250)
                if factURL != nil { Text("Source: Wikipedia").font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                Spacer()
                if let factURL {
                    Button("Read Article") { NSWorkspace.shared.open(factURL) }
                }
                Button("Close") { showFact = false }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520, alignment: .leading)
    }

    // MARK: Session

    private func open() {
        guard let book, web == nil, pdf == nil else { return }
        lastTick = Date()
        if book.format == .pdf {
            guard let doc = PDFDocument(url: store.fileURL(book)) else { error = "The PDF file is missing or damaged."; return }
            pdf = PDFReaderModel(document: doc, start: book.position.pdfPage)
            refreshHighlights()
        } else {
            do {
                let content = try store.webContent(book)
                if content.chapters.isEmpty { error = "This book has no readable chapters."; return }
                web = WebReaderModel(content: content, start: book.position)
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
        // A missing or unreadable file must not move a book into Reading Now.
        store.update(book.id) { b in
            b.lastOpenedAt = Date()
            if b.status == .none || b.status == .wantToRead { b.status = .reading }
        }
    }

    private func savePosition() {
        guard let book else { return }
        let p = progress
        let nextChapter = web?.chapter
        let nextFraction = web.map { max(0, min(0.999, $0.chapterFraction)) }
        let nextPDFPage = pdf?.pageIndex
        // Page-change callbacks can report the same position several times.
        // Avoid needless library writes and widget refreshes in that case.
        let didMove = (nextChapter.map { $0 != book.position.chapter } ?? false)
            || (nextFraction.map { abs($0 - book.position.fraction) > 0.000001 } ?? false)
            || (nextPDFPage.map { $0 != book.position.pdfPage } ?? false)
            || abs((book.status == .finished ? max(p, book.progress) : p) - book.progress) > 0.000001
        guard didMove else { return }
        store.update(book.id) { b in
            if let web {
                b.position.chapter = web.chapter
                b.position.fraction = max(0, min(0.999, web.chapterFraction))
            }
            if let pdf { b.position.pdfPage = pdf.pageIndex }
            b.progress = b.status == .finished ? max(p, b.progress) : p
        }
    }

    private func finishSession() {
        store.addReading(seconds: NSApp.isActive ? min(30, Date().timeIntervalSince(lastTick)) : 0)
        savePosition()
        // Re-read the saved position; the View's earlier snapshot may predate
        // the final page turn when a reader window closes.
        guard let book = store.book(bookID), let hcID = book.hardcoverBookID,
              hc.isConnected, book.status != .finished else { return }
        let total = book.hardcoverPages ?? pdf?.pageCount ?? 0
        guard total > 0 else { return }
        let pages = Int((book.progress * Double(total)).rounded())
        guard pages != book.syncedProgressPages, pages > 0 else { return }
        let id = book.id
        Task {
            if await hc.setProgress(bookID: hcID, pages: pages) {
                store.update(id) { $0.syncedProgressPages = pages }
            }
        }
    }
}

// MARK: - Themes & Settings panel (Books' theme picker and Customize options)

struct ThemePanel: View {
    @Environment(ReaderPrefsStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @State private var customize = false

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 14) {
            Text("Appearance")
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: true, vertical: false)
            Picker("", selection: $store.appearance) {
                ForEach(ReaderAppearance.allCases) { appearance in
                    Label(appearance.label, systemImage: appearance.symbol).tag(appearance)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            HStack(spacing: 10) {
                Button { store.prefs.fontSizeIndex = max(0, store.prefs.fontSizeIndex - 1) } label: {
                    Text("A").font(.system(size: 13)).frame(maxWidth: .infinity, minHeight: 26)
                }
                .keyboardShortcut("-", modifiers: .command)
                Button { store.prefs.fontSizeIndex = min(ReaderPrefs.fontSizes.count - 1, store.prefs.fontSizeIndex + 1) } label: {
                    Text("A").font(.system(size: 20)).frame(maxWidth: .infinity, minHeight: 26)
                }
                .keyboardShortcut("+", modifiers: .command)
            }
            .buttonStyle(.glass)

            Picker("Page Navigation", selection: $store.prefs.navigation) {
                ForEach(PageNavigation.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(ReaderTheme.allCases) { t in
                    let pal = t.palette(dark: scheme == .dark)
                    Button { store.pickTheme(t) } label: {
                        VStack(spacing: 2) {
                            Text("Aa").font(store.prefs.font.swiftUIFont.weight(store.prefs.boldText ? .bold : .regular))
                            Text(t.label).font(.caption2)
                        }
                        .foregroundStyle(Color(hex: pal.fg))
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background(Color(hex: pal.bg), in: .rect(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(store.prefs.theme == t ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: store.prefs.theme == t ? 2.5 : 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Picker("Font", selection: $store.prefs.font) {
                ForEach(ReaderFont.allCases) { f in Text(f.label).font(f.swiftUIFont).tag(f) }
            }

            DisclosureGroup("Customize", isExpanded: $customize) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Bold Text", isOn: $store.prefs.boldText)
                    Toggle("Line Spacing", isOn: $store.prefs.customLineSpacing)
                    if store.prefs.customLineSpacing { Slider(value: $store.prefs.lineSpacing, in: 1.0...2.4) }
                    Toggle("Character Spacing", isOn: $store.prefs.customCharacterSpacing)
                    if store.prefs.customCharacterSpacing { Slider(value: $store.prefs.characterSpacing, in: 0...0.2) }
                    Toggle("Word Spacing", isOn: $store.prefs.customWordSpacing)
                    if store.prefs.customWordSpacing { Slider(value: $store.prefs.wordSpacing, in: 0...0.6) }
                    Toggle("Margins", isOn: $store.prefs.customMargins)
                    if store.prefs.customMargins { Slider(value: $store.prefs.margins, in: 12...140) }
                    Toggle("Justify Text", isOn: $store.prefs.justify)
                    Toggle("Allow Multiple Columns", isOn: $store.prefs.multipleColumns)
                    Button("Reset Theme") { let t = store.prefs.theme; store.prefs = ReaderPrefs(); store.pickTheme(t) }
                        .buttonStyle(.glass)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.top, 6)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

private enum PageFoldCorner: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight

    var id: String { rawValue }
    var isRight: Bool { self == .topRight || self == .bottomRight }
    var isBottom: Bool { self == .bottomLeft || self == .bottomRight }
    var label: String {
        switch self {
        case .topLeft: "top-left corner"
        case .topRight: "top-right corner"
        case .bottomLeft: "bottom-left corner"
        case .bottomRight: "bottom-right corner"
        }
    }
}

/// Four transparent hit areas. Only the marked corner is painted, with a small
/// inward fold rather than a floating bookmark icon.
private struct FoldedPageCorner: View {
    let corner: PageFoldCorner
    let folded: Bool
    let dark: Bool
    let pageColor: Color

    var body: some View {
        ZStack {
            Color.clear
            if folded {
                foldTriangle
                    .fill(pageColor)
                foldTriangle
                    .fill(Color.black.opacity(dark ? 0.50 : 0.20))
                foldCrease
                    .stroke(Color.primary.opacity(dark ? 0.23 : 0.24), lineWidth: 0.8)
            }
        }
        .contentShape(Rectangle())
    }

    private var foldTriangle: Path {
        Path { path in
            let size: CGFloat = 38
            let x: CGFloat = corner.isRight ? size : 0
            let y: CGFloat = corner.isBottom ? size : 0
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: corner.isRight ? 0 : size, y: y))
            path.addLine(to: CGPoint(x: x, y: corner.isBottom ? 0 : size))
            path.closeSubpath()
        }
    }

    private var foldCrease: Path {
        Path { path in
            let size: CGFloat = 38
            path.move(to: CGPoint(x: corner.isRight ? 0 : size, y: corner.isBottom ? size : 0))
            path.addLine(to: CGPoint(x: corner.isRight ? size : 0, y: corner.isBottom ? 0 : size))
        }
    }
}
