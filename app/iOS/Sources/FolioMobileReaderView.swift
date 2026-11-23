import SwiftUI
import WebKit
import PDFKit
import UIKit
import Combine
import Translation

/// A native, full-screen iOS reader. EPUB and HTML books use the shared
/// `ReaderScript` page engine (the same pagination as macOS); PDFs use PDFKit.
/// Both share the persisted progress, annotations and reader preferences.
///
/// Reading is immersive: the controls fade away after the first page turn
/// and come back with a tap in the middle of the page. Tapping or swiping
/// on the sides turns pages.
struct FolioMobileReaderView: View {
    let bookID: UUID
    @Environment(LibraryStore.self) private var store
    @Environment(ReaderPrefsStore.self) private var preferences
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    @State private var engine: FolioMobileReaderEngine?
    @State private var pdf: PDFDocument?
    @State private var pdfPage = 0
    @State private var error: String?
    @State private var chromeVisible = true
    @State private var scrubValue: Double?
    @State private var showContents = false
    @State private var showAppearance = false
    @State private var showAnnotations = false
    @State private var showSelectionActions = false
    @State private var showNoteEditor = false
    @State private var showDictionary = false
    @State private var showFact = false
    @State private var showTranslation = false
    @State private var chooseTranslationLanguage = false
    @State private var translationSource = ""
    @State private var translatedText = ""
    @State private var translationError: String?
    @State private var translating = false
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var pendingSelection: FolioMobileSelection?
    @State private var selectionError: String?
    @State private var noteDraft = ""
    @State private var annotations = ReadingAnnotationsStore.shared
    @State private var pdfInteraction = FolioMobilePDFInteraction()
    @State private var lastTick = Date()
    @State private var lastSaved = Date.distantPast

    private let tick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var book: LocalBook? { store.book(bookID) }
    private var dark: Bool { preferences.appearance.isDark(systemDark: systemColorScheme == .dark) }
    private var palette: ReaderTheme.Palette { preferences.prefs.theme.palette(dark: dark) }
    private var paginated: Bool { preferences.prefs.navigation == .pages && !(engine?.content.isComic ?? false) }
    private var showsChrome: Bool { chromeVisible || voiceOver || (engine == nil && pdf == nil) }

    private var progress: Double {
        if let pdf { return Double(pdfPage + 1) / Double(max(1, pdf.pageCount)) }
        return engine?.progress ?? 0
    }

    var body: some View {
        ZStack {
            Color(hex: palette.bg).ignoresSafeArea()

            readingSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityAction(.magicTap) { toggleChrome() }

            if !showsChrome {
                quietFooter
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            if showsChrome {
                VStack(spacing: 0) {
                    topBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Spacer(minLength: 0)
                    if engine != nil || pdf != nil {
                        bottomPanel
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }

            if hasBookmark {
                bookmarkRibbon
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: showsChrome)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(!showsChrome)
        .persistentSystemOverlays(showsChrome ? .automatic : .hidden)
        .foregroundStyle(Color(hex: palette.fg))
        .sheet(isPresented: $showContents) { contentsSheet }
        .sheet(isPresented: $showAppearance) {
            FolioMobileReaderAppearance()
                .environment(preferences)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .sheet(isPresented: $showAnnotations) {
            FolioMobileAnnotationsSheet(bookID: bookID) { entry in jump(to: entry) }
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showNoteEditor) {
            FolioMobileNoteEditor(selectedText: pendingSelection?.text ?? "", note: $noteDraft) { value in
                saveSelectedAnnotation(.note, note: value)
                showNoteEditor = false
            }
        }
        .sheet(isPresented: $showDictionary) {
            if let text = pendingSelection?.text {
                NavigationStack {
                    FolioMobileDictionaryView(term: text)
                        .navigationTitle("Dictionary")
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showDictionary = false }.folioGlassPill()
                            }
                        }
                }
            }
        }
        .sheet(isPresented: $showFact) {
            if let text = pendingSelection?.text {
                FolioMobileFactView(selection: text)
            }
        }
        .sheet(isPresented: $showTranslation) {
            FolioMobileTranslationView(original: translationSource,
                                       translated: translatedText,
                                       error: translationError,
                                       loading: translating)
        }
        .translationTask(translationConfig) { session in
            do {
                let response = try await session.translate(translationSource)
                translatedText = response.targetText
                translationError = nil
            } catch {
                translationError = error.localizedDescription
            }
            translating = false
        }
        .confirmationDialog("Selected Text", isPresented: $showSelectionActions, titleVisibility: .visible) {
            Button("Highlight") { saveSelectedAnnotation(.highlight) }
            Button("Save Quote") { saveSelectedAnnotation(.quote) }
            Button("Add Note") {
                noteDraft = ""
                showNoteEditor = true
            }
            Button("Define") { showDictionary = true }
            Button("Translate") { chooseTranslationLanguage = true }
            Button("Fun Fact") { showFact = true }
        } message: {
            Text(pendingSelection?.text ?? "")
        }
        .confirmationDialog("Translate To", isPresented: $chooseTranslationLanguage,
                            titleVisibility: .visible) {
            Button("English") { translateSelection(to: "en") }
            Button("Español") { translateSelection(to: "es") }
            Button("Français") { translateSelection(to: "fr") }
            Button("Deutsch") { translateSelection(to: "de") }
            Button("Italiano") { translateSelection(to: "it") }
            Button("Português") { translateSelection(to: "pt") }
        }
        .alert("Text Selection", isPresented: Binding(
            get: { selectionError != nil },
            set: { if !$0 { selectionError = nil } }
        )) {
            Button("OK") { selectionError = nil }
        } message: {
            Text(selectionError ?? "")
        }
        .task { open() }
        .onReceive(tick) { date in
            if scenePhase == .active {
                store.addReading(seconds: min(30, date.timeIntervalSince(lastTick)))
            }
            lastTick = date
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { savePosition() }
            lastTick = Date()
        }
        .onChange(of: engine?.chapter) { _, _ in savePosition() }
        .onChange(of: annotations.entries) { _, _ in engine?.refreshHighlights() }
        .onDisappear {
            if scenePhase == .active {
                store.addReading(seconds: min(30, Date().timeIntervalSince(lastTick)))
            }
            savePosition()
        }
        .preferredColorScheme(preferences.appearance == .system ? nil : (dark ? .dark : .light))
    }

    // MARK: Page

    @ViewBuilder
    private var readingSurface: some View {
        if let pdf {
            FolioMobilePDFPage(
                document: pdf,
                page: pdfPage,
                paged: preferences.prefs.navigation == .pages,
                interaction: pdfInteraction,
                background: palette.bg,
                onPageChange: { newPage in
                    guard newPage != pdfPage else { return }
                    pdfPage = newPage
                    if chromeVisible && !voiceOver { chromeVisible = false }
                    savePositionIfNeeded()
                },
                onTap: { toggleChrome() },
                selectionAction: handleSelection
            )
            .ignoresSafeArea(edges: .bottom)
        } else if let engine {
            FolioMobileEPUBPage(
                engine: engine,
                config: Self.config(
                    preferences.prefs, palette: palette, comic: engine.content.isComic,
                    regularWidth: horizontalSizeClass == .regular
                ),
                paginated: paginated,
                background: palette.bg,
                selectionAction: handleSelection
            )
        } else if let error {
            ContentUnavailableView("Cannot Open Book", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            ProgressView("Opening Book…")
        }
    }

    /// What stays on screen while reading: a quiet page count, like a printed folio.
    @ViewBuilder
    private var quietFooter: some View {
        let text: String? = {
            if let pdf { return "\(pdfPage + 1) of \(pdf.pageCount)" }
            guard let engine, !engine.content.isComic, engine.ready else { return nil }
            if !paginated { return "\(Int((progress * 100).rounded()))%" }
            switch engine.pagesLeftInChapter {
            case 0: return engine.isLastChapter ? "Last page" : "Last page in chapter"
            case 1: return "1 page left in chapter"
            case let n: return "\(n) pages left in chapter"
            }
        }()
        if let text {
            Text(text)
                .font(.caption2.weight(.medium).monospacedDigit())
                .foregroundStyle(Color(hex: palette.fg).opacity(0.45))
                .padding(.bottom, 6)
                .accessibilityHidden(true)
        }
    }

    private var bookmarkRibbon: some View {
        Image(systemName: "bookmark.fill")
            .font(.title2)
            .foregroundStyle(Color(hex: palette.accent))
            .padding(.trailing, 22)
            .offset(y: -4)
            .accessibilityLabel("This page is bookmarked")
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 34, height: 34)
            }
            .folioGlassPill()
            .accessibilityLabel("Close Book")

            Text(book?.title ?? "")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)

            if let engine, !engine.content.toc.isEmpty {
                chromeButton("Contents", systemImage: "list.bullet") { showContents = true }
            }
            if engine != nil || pdf != nil {
                chromeButton("Text and Reading Appearance", systemImage: "textformat.size") { showAppearance = true }
                chromeButton(hasBookmark ? "Remove Bookmark" : "Bookmark This Page",
                             systemImage: hasBookmark ? "bookmark.fill" : "bookmark") { toggleBookmark() }
                Menu {
                    Button("Highlights, Notes & Quotes", systemImage: "text.book.closed") {
                        showAnnotations = true
                    }
                    Button("Annotate Selected Text", systemImage: "highlighter") {
                        handleSelection(.more)
                    }
                    Divider()
                    Picker("Reading Mode", selection: Binding(
                        get: { preferences.prefs.navigation },
                        set: { preferences.prefs.navigation = $0 }
                    )) {
                        Label("Pages", systemImage: "book").tag(PageNavigation.pages)
                        Label("Scroll", systemImage: "scroll").tag(PageNavigation.scroll)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .frame(width: 34, height: 34)
                }
                .folioGlassPill()
                .accessibilityLabel("Reading Tools")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    private func chromeButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 34, height: 34)
        }
        .folioGlassPill()
        .accessibilityLabel(label)
    }

    private var bottomPanel: some View {
        let shown = scrubValue ?? progress
        return VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(panelTitle(at: scrubValue))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(panelDetail)
                        .font(.caption)
                        .foregroundStyle(Color(hex: palette.fg).opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("\(Int((shown * 100).rounded()))%")
                    .font(.footnote.weight(.semibold).monospacedDigit())
            }
            HStack(spacing: 12) {
                pageButton(-1)
                Slider(value: Binding(
                    get: { scrubValue ?? progress },
                    set: { scrubValue = $0 }
                ), in: 0...1, onEditingChanged: { editing in
                    if !editing, let value = scrubValue {
                        seek(to: value)
                        scrubValue = nil
                    }
                })
                .tint(Color(hex: palette.accent))
                .accessibilityLabel("Reading progress")
                .accessibilityValue("\(Int((shown * 100).rounded())) percent")
                pageButton(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background {
            if #available(iOS 26, *) {
                RoundedRectangle(cornerRadius: 26).glassEffect(.regular)
            } else {
                RoundedRectangle(cornerRadius: 26).fill(.regularMaterial)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private func pageButton(_ direction: Int) -> some View {
        Button { turn(direction) } label: {
            Image(systemName: direction > 0 ? "chevron.right" : "chevron.left")
                .font(.body.weight(.semibold))
                .frame(width: 30, height: 30)
        }
        .folioGlassPill()
        .disabled(direction > 0 ? atEnd : atStart)
        .accessibilityLabel(direction > 0 ? "Next Page" : "Previous Page")
    }

    private func panelTitle(at scrub: Double?) -> String {
        if let pdf {
            let page = scrub.map { min(pdf.pageCount - 1, Int($0 * Double(pdf.pageCount))) } ?? pdfPage
            return "Page \(page + 1) of \(pdf.pageCount)"
        }
        guard let engine else { return "" }
        if let scrub { return engine.title(ofChapter: engine.location(at: scrub).chapter) }
        return engine.chapterTitle
    }

    private var panelDetail: String {
        if pdf != nil { return book?.author ?? "" }
        guard let engine else { return "" }
        if scrubValue != nil { return "Release to jump here" }
        if !paginated || engine.content.isComic { return book?.author ?? "" }
        switch engine.pagesLeftInChapter {
        case 0: return engine.isLastChapter ? "End of book" : "Last page in chapter"
        case 1: return "1 page left in chapter"
        case let n: return "\(n) pages left in chapter"
        }
    }

    private var contentsSheet: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(engine?.content.toc ?? []) { entry in
                    Button {
                        engine?.go(entry)
                        showContents = false
                    } label: {
                        HStack {
                            Text(entry.title)
                                .fontWeight(entry.chapter == currentTOCChapter ? .semibold : .regular)
                                .padding(.leading, CGFloat(max(0, entry.level - 1) * 14))
                            Spacer()
                            if entry.chapter == currentTOCChapter {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(.primary)
                    .id(entry.id)
                }
                .onAppear {
                    if let current = engine?.content.toc.last(where: { $0.chapter <= (engine?.chapter ?? 0) }) {
                        proxy.scrollTo(current.id, anchor: .center)
                    }
                }
            }
            .navigationTitle("Contents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showContents = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var currentTOCChapter: Int? {
        guard let engine else { return nil }
        return engine.content.toc.last(where: { $0.chapter <= engine.chapter })?.chapter
    }

    // MARK: Navigation

    private var atStart: Bool { pdf != nil ? pdfPage == 0 : (engine?.atStart ?? true) }
    private var atEnd: Bool { pdf != nil ? pdfPage >= (pdf?.pageCount ?? 1) - 1 : (engine?.atEnd ?? true) }

    private func toggleChrome() {
        guard !voiceOver else { return }
        chromeVisible.toggle()
    }

    private func handleTap(_ x: Double) {
        if paginated && x < 0.3 { turn(-1) }
        else if paginated && x > 0.7 { turn(1) }
        else { toggleChrome() }
    }

    private func turn(_ direction: Int) {
        if let pdf {
            pdfPage = max(0, min(pdf.pageCount - 1, pdfPage + direction))
            savePositionIfNeeded()
        } else {
            engine?.turn(direction)
        }
    }

    private func seek(to fraction: Double) {
        let target = max(0, min(1, fraction))
        if let pdf {
            pdfPage = min(max(0, pdf.pageCount - 1), Int(target * Double(pdf.pageCount)))
            savePosition()
        } else {
            engine?.seek(target)
        }
    }

    private func jump(to entry: ReadingAnnotation) {
        if let pdf {
            pdfPage = max(0, min(pdf.pageCount - 1, entry.chapter))
        } else if let engine {
            engine.go(chapter: max(0, min(engine.content.chapters.count - 1, entry.chapter)), fraction: entry.fraction)
        }
        savePosition()
    }

    // MARK: Bookmarks and selection

    private var currentChapter: Int { pdf != nil ? pdfPage : (engine?.chapter ?? 0) }
    private var currentFraction: Double { pdf != nil ? 0 : (engine?.chapterFraction ?? 0) }
    /// Paged EPUBs compare real pages so a bookmark follows the page it was made on.
    private var bookmarkPageCount: Int? { pdf == nil && paginated ? engine?.pages : nil }

    private var hasBookmark: Bool {
        guard engine?.ready == true || pdf != nil else { return false }
        return annotations.bookmark(bookID: bookID, chapter: currentChapter, fraction: currentFraction,
                                    pageCount: bookmarkPageCount) != nil
    }

    private func toggleBookmark() {
        annotations.toggleBookmark(bookID: bookID, chapter: currentChapter, fraction: currentFraction,
                                   pageCount: bookmarkPageCount)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func handleSelection(_ action: FolioMobileSelectionAction) {
        Task { @MainActor in
            let selection: FolioMobileSelection?
            if pdf != nil {
                selection = pdfInteraction.selectedText().map { FolioMobileSelection(text: $0, prefix: "", suffix: "") }
            } else {
                selection = await engine?.currentSelection()
            }
            guard let selection else {
                selectionError = "Select text in the book first. Touch and hold a word, then drag to choose more."
                return
            }
            pendingSelection = selection
            switch action {
            case .highlight: saveSelectedAnnotation(.highlight)
            case .quote: saveSelectedAnnotation(.quote)
            case .note:
                noteDraft = ""
                showNoteEditor = true
            case .more:
                showSelectionActions = true
            }
        }
    }

    private func translateSelection(to language: String) {
        guard let text = pendingSelection?.text, !text.isEmpty else { return }
        translationSource = text
        translatedText = ""
        translationError = nil
        translating = true
        showTranslation = true
        translationConfig?.invalidate()
        translationConfig = TranslationSession.Configuration(
            source: nil, target: Locale.Language(identifier: language)
        )
    }

    private func saveSelectedAnnotation(_ kind: ReadingAnnotationKind, note: String = "") {
        guard let selection = pendingSelection, !selection.text.isEmpty else { return }
        annotations.add(bookID: bookID, chapter: currentChapter,
                        fraction: currentFraction, kind: kind, text: selection.text,
                        prefix: selection.prefix, suffix: selection.suffix, note: note)
        if pdf != nil {
            if kind == .highlight || kind == .note { pdfInteraction.highlightSelection() }
        } else {
            // Highlights are painted from the saved annotations, not the live selection.
            engine?.clearSelection()
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        pendingSelection = nil
    }

    // MARK: Opening and saving

    private func open() {
        guard let book, pdf == nil, engine == nil else { return }
        store.update(bookID) {
            $0.lastOpenedAt = Date()
            if $0.status == .none || $0.status == .wantToRead { $0.status = .reading }
        }
        lastTick = Date()
        if book.format == .pdf {
            guard let document = PDFDocument(url: store.fileURL(book)) else {
                error = "This PDF is missing or damaged."
                return
            }
            pdfPage = max(0, min(document.pageCount - 1, book.position.pdfPage))
            pdf = document
            return
        }
        do {
            let parsed = try store.webContent(book)
            guard !parsed.chapters.isEmpty else {
                error = "There are no readable chapters in this file."
                return
            }
            let reader = FolioMobileReaderEngine(content: parsed, chapter: book.position.chapter,
                                                 fraction: book.position.fraction)
            reader.paginated = preferences.prefs.navigation == .pages && !parsed.isComic
            let id = bookID
            let annotationStore = annotations
            reader.annotationsForBook = { annotationStore.items(for: id) }
            reader.onPositionChange = { savePositionIfNeeded() }
            reader.onTap = { x in handleTap(x) }
            reader.onTurn = {
                if chromeVisible && !voiceOver { chromeVisible = false }
            }
            engine = reader
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func savePositionIfNeeded() {
        guard Date().timeIntervalSince(lastSaved) > 3 else { return }
        savePosition()
    }

    private func savePosition() {
        guard book != nil, pdf != nil || engine?.ready == true else { return }
        let chapter = engine?.chapter ?? 0
        let fraction = engine?.chapterFraction ?? 0
        let page = pdfPage
        let progress = progress
        store.update(bookID) {
            if pdf != nil {
                $0.position.pdfPage = page
            } else {
                $0.position.chapter = chapter
                $0.position.fraction = fraction
            }
            if $0.status != .finished { $0.progress = progress }
        }
        lastSaved = Date()
    }

    /// The `ReaderScript` configuration, sized for iPhone and iPad screens.
    static func config(_ prefs: ReaderPrefs, palette: ReaderTheme.Palette, comic: Bool, regularWidth: Bool) -> String {
        // Respect Dynamic Type: the chosen size is a base that scales with the system text size.
        let fontSize = min(78, max(12, UIFontMetrics(forTextStyle: .body).scaledValue(for: CGFloat(prefs.fontSize))))
        let margin: Double
        if comic { margin = 4 }
        else if prefs.customMargins { margin = regularWidth ? prefs.margins : max(10, prefs.margins / 2) }
        else { margin = regularWidth ? 56 : 24 }
        var config: [String: Any] = [
            "bg": palette.bg, "fg": palette.fg, "accent": palette.accent,
            "fontSize": Int(fontSize.rounded()), "mode": comic ? "scroll" : prefs.navigation.rawValue,
            "columns": prefs.multipleColumns, "justify": prefs.justify, "bold": prefs.boldText,
            "margin": margin, "comic": comic,
        ]
        if let font = prefs.font.css { config["font"] = font }
        if prefs.customLineSpacing { config["lineHeight"] = prefs.lineSpacing }
        if prefs.customCharacterSpacing { config["letterSpacing"] = prefs.characterSpacing }
        if prefs.customWordSpacing { config["wordSpacing"] = prefs.wordSpacing }
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - PDF

/// Adds Folio's annotation commands to PDF text selection.
final class FolioMobilePDFView: PDFView {
    var selectionAction: ((FolioMobileSelectionAction) -> Void)?

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .context, let selectionAction, currentSelection != nil else { return }
        let menu = UIMenu(title: "", identifier: UIMenu.Identifier("app.folio.reader.pdf-annotate"),
                          options: .displayInline, children: [
            UIAction(title: "Highlight", image: UIImage(systemName: "highlighter")) { _ in selectionAction(.highlight) },
            UIAction(title: "Add Note", image: UIImage(systemName: "note.text.badge.plus")) { _ in selectionAction(.note) },
            UIAction(title: "More…", image: UIImage(systemName: "ellipsis.circle")) { _ in selectionAction(.more) },
        ])
        if builder.menu(for: .standardEdit) != nil {
            builder.insertSibling(menu, beforeMenu: .standardEdit)
        } else {
            builder.insertChild(menu, atStartOfMenu: .root)
        }
    }
}

/// PDFKit pages: swipe one page at a time in Pages mode, or scroll continuously.
struct FolioMobilePDFPage: UIViewRepresentable {
    let document: PDFDocument
    let page: Int
    let paged: Bool
    let interaction: FolioMobilePDFInteraction
    let background: String
    let onPageChange: (Int) -> Void
    let onTap: () -> Void
    let selectionAction: (FolioMobileSelectionAction) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> FolioMobilePDFView {
        let view = FolioMobilePDFView()
        interaction.view = view
        view.document = document
        view.selectionAction = selectionAction
        configure(view, paged: paged)
        context.coordinator.paged = paged
        view.backgroundColor = UIColor(Color(hex: background))
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: view,
            queue: .main
        ) { [weak view, weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated {
                guard let view, let current = view.currentPage,
                      let index = view.document?.index(for: current) else { return }
                coordinator?.parent.onPageChange(index)
            }
        }
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        let target = page
        DispatchQueue.main.async {
            if let destination = document.page(at: target) { view.go(to: destination) }
        }
        return view
    }

    func updateUIView(_ view: FolioMobilePDFView, context: Context) {
        context.coordinator.parent = self
        interaction.view = view
        view.selectionAction = selectionAction
        if view.document !== document { view.document = document }
        view.backgroundColor = UIColor(Color(hex: background))
        if context.coordinator.paged != paged {
            context.coordinator.paged = paged
            configure(view, paged: paged)
        }
        if let current = view.currentPage, document.index(for: current) == page { return }
        if let target = document.page(at: page) { view.go(to: target) }
    }

    private func configure(_ view: PDFView, paged: Bool) {
        view.autoScales = true
        if paged {
            view.displayMode = .singlePage
            view.displayDirection = .horizontal
            view.usePageViewController(true, withViewOptions: [UIPageViewController.OptionsKey.interPageSpacing: 16])
        } else {
            view.usePageViewController(false, withViewOptions: nil)
            view.displayMode = .singlePageContinuous
            view.displayDirection = .vertical
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: FolioMobilePDFPage
        var paged = true
        var observer: NSObjectProtocol?
        init(_ parent: FolioMobilePDFPage) { self.parent = parent }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard parent.interaction.selectedText() == nil else { return }
            parent.onTap()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

// MARK: - Appearance

/// Quick reading controls shown over the page, so changes are visible while
/// adjusting them. Deeper spacing options live in Typography & Layout.
struct FolioMobileReaderAppearance: View {
    @Environment(ReaderPrefsStore.self) private var preferences
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.dismiss) private var dismiss

    private var dark: Bool { preferences.appearance.isDark(systemDark: systemColorScheme == .dark) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        sizeButton(smaller: true)
                        VStack(spacing: 2) {
                            Text("\(preferences.prefs.fontSize) pt")
                                .font(.headline.monospacedDigit())
                            Text("Text Size").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .combine)
                        sizeButton(smaller: false)
                    }
                    .padding(.vertical, 2)

                    themeGrid
                        .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))

                    Picker("Appearance", selection: Binding(
                        get: { preferences.appearance },
                        set: { preferences.appearance = $0 }
                    )) {
                        ForEach(ReaderAppearance.allCases) { appearance in
                            Label(appearance.label, systemImage: appearance.symbol).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Layout") {
                    Picker("Reading Mode", selection: Binding(
                        get: { preferences.prefs.navigation },
                        set: { preferences.prefs.navigation = $0 }
                    )) {
                        ForEach(PageNavigation.allCases) { mode in Text(mode.label).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Font", selection: Binding(
                        get: { preferences.prefs.font },
                        set: { preferences.prefs.font = $0 }
                    )) {
                        ForEach(ReaderFont.allCases) { font in
                            Text(font.label).font(font.swiftUIFont).tag(font)
                        }
                    }
                    Toggle("Bold Text", isOn: Binding(
                        get: { preferences.prefs.boldText },
                        set: { preferences.prefs.boldText = $0 }
                    ))
                    Toggle("Justify Paragraphs", isOn: Binding(
                        get: { preferences.prefs.justify },
                        set: { preferences.prefs.justify = $0 }
                    ))
                    NavigationLink("Typography & Layout") {
                        FolioMobileReaderAdvancedSettings()
                            .environment(preferences)
                    }
                }

                FolioMobileReadabilitySettings()
            }
            .navigationTitle("Themes & Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    private func sizeButton(smaller: Bool) -> some View {
        let index = preferences.prefs.fontSizeIndex
        let limit = smaller ? 0 : ReaderPrefs.fontSizes.count - 1
        return Button {
            preferences.prefs.fontSizeIndex = max(0, min(ReaderPrefs.fontSizes.count - 1, index + (smaller ? -1 : 1)))
        } label: {
            Text("A")
                .font(.system(size: smaller ? 15 : 24, weight: .semibold, design: .serif))
                .frame(width: 52, height: 40)
        }
        .folioGlassPill()
        .disabled(index == limit)
        .accessibilityLabel(smaller ? "Smaller Text" : "Larger Text")
    }

    private var themeGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(ReaderTheme.allCases) { theme in
                let palette = theme.palette(dark: dark)
                let selected = preferences.prefs.theme == theme
                Button { preferences.pickTheme(theme) } label: {
                    VStack(spacing: 4) {
                        Text("Aa")
                            .font(theme.defaultFont.swiftUIFont.weight(theme.isBold ? .bold : .regular))
                            .imageScale(.large)
                        Text(theme.label).font(.caption2)
                    }
                    .foregroundStyle(Color(hex: palette.fg))
                    .frame(maxWidth: .infinity, minHeight: 58)
                    .background(Color(hex: palette.bg), in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(selected ? Color(hex: palette.accent) : Color.secondary.opacity(0.25),
                                          lineWidth: selected ? 2.5 : 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(theme.label) theme")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}
