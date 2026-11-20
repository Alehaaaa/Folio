import SwiftUI
import WebKit
import PDFKit
import UIKit
import Combine
import Translation

/// A native, full-screen iOS reader backed by the existing EPUB package parser,
/// PDFKit and the same persisted progress and reader preferences as macOS.
struct FolioMobileReaderView: View {
    let bookID: UUID
    @Environment(LibraryStore.self) private var store
    @Environment(ReaderPrefsStore.self) private var preferences
    @Environment(HardcoverClient.self) private var hardcover
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    @State private var content: WebContent?
    @State private var pdf: PDFDocument?
    @State private var chapter = 0
    @State private var chapterFraction = 0.0
    @State private var pdfPage = 0
    @State private var error: String?
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
    @State private var selectionText: String?
    @State private var selectionError: String?
    @State private var noteDraft = ""
    @State private var annotations = ReadingAnnotationsStore.shared
    @State private var webInteraction = FolioMobileWebInteraction()
    @State private var pdfInteraction = FolioMobilePDFInteraction()
    @State private var openedAt = Date()
    @State private var lastTick = Date()
    @State private var lastSaved = Date.distantPast

    private let tick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var book: LocalBook? { store.book(bookID) }
    private var dark: Bool { preferences.appearance.isDark(systemDark: systemColorScheme == .dark) }
    private var palette: ReaderTheme.Palette { preferences.prefs.theme.palette(dark: dark) }
    private var totalChapters: Int { content?.chapters.count ?? 0 }
    private var chapterTitle: String {
        content?.toc.last(where: { $0.chapter <= chapter })?.title ?? "Chapter \(chapter + 1)"
    }

    private var progress: Double {
        if let pdf {
            return Double(pdfPage + 1) / Double(max(1, pdf.pageCount))
        }
        guard let content, content.chapterSizes.indices.contains(chapter) else { return 0 }
        let total = max(content.chapterSizes.reduce(0, +), 1)
        let previous = content.chapterSizes.prefix(chapter).reduce(0, +)
        return min(1, (previous + content.chapterSizes[chapter] * chapterFraction) / total)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let pdf {
                    FolioMobilePDFPage(
                        document: pdf,
                        page: pdfPage,
                        interaction: pdfInteraction,
                        background: palette.bg,
                        onPageChange: { newPage in
                            guard newPage != pdfPage else { return }
                            pdfPage = newPage
                            savePositionIfNeeded()
                        }
                    )
                } else if let content, content.chapters.indices.contains(chapter) {
                    FolioMobileHTMLPage(
                        url: content.chapters[chapter],
                        root: content.root,
                        initialFraction: chapterFraction,
                        preferences: preferences.prefs,
                        palette: palette,
                        comic: content.isComic,
                        interaction: webInteraction,
                        highlights: annotations.items(for: bookID)
                            .filter { $0.chapter == chapter && ($0.kind == .highlight || $0.kind == .note) }
                            .map(\.text),
                        onPositionChange: { value in
                            let adjusted = max(0, min(0.999, value))
                            guard abs(adjusted - chapterFraction) > 0.001 else { return }
                            chapterFraction = adjusted
                            savePositionIfNeeded()
                        }
                    )
                    .id(chapter)
                } else if let error {
                    ContentUnavailableView("Cannot Open Book", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    ProgressView("Opening Book…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if pdf != nil || content != nil {
                readingControls
            }
        }
        .background(Color(hex: palette.bg).ignoresSafeArea())
        .navigationTitle(book?.title ?? "Reader")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
                    .folioGlassPill()
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    annotations.toggleBookmark(bookID: bookID, chapter: currentChapter, fraction: currentFraction)
                } label: {
                    Label("Bookmark", systemImage: hasBookmark ? "bookmark.fill" : "bookmark")
                }
                .folioGlassPill()
                Button {
                    showAppearance = true
                } label: {
                    Label("Text and Reading Appearance", systemImage: "textformat.size")
                }
                .folioGlassPill()
                Menu {
                    if let content, !content.toc.isEmpty {
                        Button("Table of Contents", systemImage: "list.bullet") {
                            showContents = true
                        }
                    }
                    Button("Highlights, Notes & Quotes", systemImage: "text.book.closed") {
                        showAnnotations = true
                    }
                    Button("Save Selected Text", systemImage: "highlighter") {
                        Task { await captureSelection() }
                    }
                    Button(hasBookmark ? "Remove Bookmark" : "Bookmark This Page",
                           systemImage: hasBookmark ? "bookmark.slash" : "bookmark") {
                        annotations.toggleBookmark(bookID: bookID, chapter: currentChapter, fraction: currentFraction)
                    }
                } label: {
                    Label("Reading Tools", systemImage: "ellipsis.circle")
                }
                .folioGlassPill()
            }
        }
        .sheet(isPresented: $showContents) {
            NavigationStack {
                List(content?.toc ?? []) { entry in
                    Button {
                        chapter = entry.chapter
                        chapterFraction = 0
                        savePosition()
                        showContents = false
                    } label: {
                        HStack {
                            Text(entry.title).padding(.leading, CGFloat(max(0, entry.level - 1) * 12))
                            Spacer()
                            if entry.chapter == chapter { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .navigationTitle("Contents")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showContents = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showAppearance) {
            FolioMobileReaderAppearance()
                .environment(preferences)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showAnnotations) {
            FolioMobileAnnotationsSheet(bookID: bookID) { entry in
                if pdf != nil {
                    pdfPage = entry.chapter
                } else {
                    chapter = max(0, min(totalChapters - 1, entry.chapter))
                    chapterFraction = entry.fraction
                }
                savePosition()
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showNoteEditor) {
            FolioMobileNoteEditor(selectedText: selectionText ?? "", note: $noteDraft) { value in
                saveSelectedAnnotation(.note, note: value)
                showNoteEditor = false
            }
        }
        .sheet(isPresented: $showDictionary) {
            if let selectionText {
                NavigationStack {
                    FolioMobileDictionaryView(term: selectionText)
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
            if let selectionText {
                FolioMobileFactView(selection: selectionText)
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
            Text(selectionText ?? "")
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
        .onChange(of: chapter) { _, _ in savePosition() }
        .onChange(of: annotations.entries) { _, _ in
            webInteraction.restoreHighlights(annotations.items(for: bookID)
                .filter { $0.chapter == chapter && ($0.kind == .highlight || $0.kind == .note) }
                .map(\.text))
        }
        .onDisappear {
            if scenePhase == .active {
                store.addReading(seconds: min(30, Date().timeIntervalSince(lastTick)))
            }
            savePosition()
        }
        .preferredColorScheme(preferences.appearance == .system ? nil : (dark ? .dark : .light))
    }

    private var readingControls: some View {
        HStack(spacing: 15) {
            Button {
                if pdf != nil { pdfPage = max(0, pdfPage - 1) }
                else if !webInteraction.turnPage(-1) && chapter > 0 {
                    chapter -= 1
                    chapterFraction = 0.999
                }
                savePosition()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .frame(width: 38, height: 38)
            }
            .disabled(pdf != nil ? pdfPage == 0 : (preferences.prefs.navigation == .scroll && chapter == 0))
            .accessibilityLabel("Previous page or chapter")
            .folioGlassPill()

            VStack(spacing: 7) {
                Text(pdf != nil ? "Page \(pdfPage + 1) of \(pdf?.pageCount ?? 1)" : chapterTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .accessibilityAddTraits(.isHeader)
                Slider(value: Binding(
                    get: { progress },
                    set: { seek(to: $0) }
                ), in: 0...1)
                    .tint(Color(hex: palette.accent))
                    .accessibilityLabel("Reading progress")
                    .accessibilityValue("\(Int((progress * 100).rounded())) percent")
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.footnote.weight(.medium).monospacedDigit())
            }
            .frame(maxWidth: .infinity)

            Button {
                if let pdf { pdfPage = min(pdf.pageCount - 1, pdfPage + 1) }
                else if !webInteraction.turnPage(1) && chapter + 1 < totalChapters {
                    chapter += 1
                    chapterFraction = 0
                }
                savePosition()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.title3.weight(.semibold))
                    .frame(width: 38, height: 38)
            }
            .disabled(pdf != nil ? pdfPage >= (pdf?.pageCount ?? 1) - 1 : (preferences.prefs.navigation == .scroll && chapter >= totalChapters - 1))
            .accessibilityLabel("Next page or chapter")
            .folioGlassPill()
        }
        .foregroundStyle(Color(hex: palette.fg))
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background {
            if #available(iOS 26, *) {
                RoundedRectangle(cornerRadius: 22).glassEffect(.regular)
            } else {
                RoundedRectangle(cornerRadius: 22).fill(.regularMaterial)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    private var currentChapter: Int { pdf != nil ? pdfPage : chapter }
    private var currentFraction: Double { pdf != nil ? 0 : chapterFraction }
    private var hasBookmark: Bool {
        annotations.bookmark(bookID: bookID, chapter: currentChapter, fraction: currentFraction) != nil
    }

    @MainActor
    private func seek(to fraction: Double) {
        let target = max(0, min(1, fraction))
        if let pdf {
            pdfPage = min(max(0, pdf.pageCount - 1), Int(target * Double(pdf.pageCount)))
        } else if let content, !content.chapters.isEmpty {
            let total = max(1, content.chapterSizes.reduce(0, +))
            let raw = target * total
            var running = 0.0
            for index in content.chapters.indices {
                let length = content.chapterSizes.indices.contains(index) ? content.chapterSizes[index] : 1
                if raw <= running + length || index == content.chapters.count - 1 {
                    chapter = index
                    chapterFraction = max(0, min(0.999, (raw - running) / max(1, length)))
                    break
                }
                running += length
            }
        }
        savePositionIfNeeded()
    }

    @MainActor
    private func captureSelection() async {
        let text: String?
        if pdf != nil { text = pdfInteraction.selectedText() }
        else { text = await webInteraction.selectedText() }
        guard let text, !text.isEmpty else {
            selectionError = "Select text in the book, then tap the highlighter to save it."
            return
        }
        selectionText = text
        showSelectionActions = true
    }

    @MainActor
    private func translateSelection(to language: String) {
        guard let selectionText, !selectionText.isEmpty else { return }
        translationSource = selectionText
        translatedText = ""
        translationError = nil
        translating = true
        showTranslation = true
        translationConfig?.invalidate()
        translationConfig = TranslationSession.Configuration(
            source: nil, target: Locale.Language(identifier: language)
        )
    }

    @MainActor
    private func saveSelectedAnnotation(_ kind: ReadingAnnotationKind, note: String = "") {
        guard let selectedText = selectionText, !selectedText.isEmpty else { return }
        _ = annotations.add(bookID: bookID, chapter: currentChapter,
                            fraction: currentFraction, kind: kind, text: selectedText,
                            prefix: "", suffix: "", note: note)
        if kind == .highlight || kind == .note {
            if pdf != nil { pdfInteraction.highlightSelection() }
            else {
                Task { await webInteraction.highlightSelection() }
            }
        }
        selectionText = nil
    }

    @MainActor
    private func open() {
        guard let book, pdf == nil, content == nil else { return }
        store.update(bookID) {
            $0.lastOpenedAt = Date()
            if $0.status == .none || $0.status == .wantToRead { $0.status = .reading }
        }
        openedAt = Date()
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
            chapter = max(0, min(parsed.chapters.count - 1, book.position.chapter))
            chapterFraction = max(0, min(0.999, book.position.fraction))
            content = parsed
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func savePositionIfNeeded() {
        guard Date().timeIntervalSince(lastSaved) > 3 else { return }
        savePosition()
    }

    @MainActor
    private func savePosition() {
        guard book != nil, pdf != nil || content != nil else { return }
        let chapter = chapter
        let fraction = chapterFraction
        let page = pdfPage
        let progress = progress
        store.update(bookID) {
            $0.position.chapter = chapter
            $0.position.fraction = fraction
            $0.position.pdfPage = page
            if $0.status != .finished { $0.progress = progress }
        }
        lastSaved = Date()
    }
}

/// A WKWebView renders extracted EPUB chapters and local HTML assets.
struct FolioMobileHTMLPage: UIViewRepresentable {
    let url: URL
    let root: URL
    let initialFraction: Double
    let preferences: ReaderPrefs
    let palette: ReaderTheme.Palette
    let comic: Bool
    let interaction: FolioMobileWebInteraction
    let highlights: [String]
    let onPositionChange: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero)
        interaction.view = web
        interaction.paginated = preferences.navigation == .pages && !comic
        web.isOpaque = false
        web.backgroundColor = UIColor(Color(hex: palette.bg))
        web.scrollView.backgroundColor = UIColor(Color(hex: palette.bg))
        web.scrollView.delegate = context.coordinator
        web.navigationDelegate = context.coordinator
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.allowsBackForwardNavigationGestures = false
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        interaction.view = web
        interaction.paginated = preferences.navigation == .pages && !comic
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            context.coordinator.startFraction = initialFraction
            context.coordinator.lastPreferences = preferences
            context.coordinator.lastPalette = palette.bg
            web.loadFileURL(url, allowingReadAccessTo: root)
        } else if context.coordinator.lastPreferences != preferences || context.coordinator.lastPalette != palette.bg {
            context.coordinator.lastPreferences = preferences
            context.coordinator.lastPalette = palette.bg
            context.coordinator.installAppearance(in: web, scroll: false)
        } else if context.coordinator.lastHighlights != highlights {
            context.coordinator.lastHighlights = highlights
            interaction.restoreHighlights(highlights)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate {
        var parent: FolioMobileHTMLPage
        var loadedURL: URL?
        var startFraction = 0.0
        var lastPreferences: ReaderPrefs?
        var lastPalette: String?
        var lastHighlights: [String] = []
        private var didLoad = false

        init(_ parent: FolioMobileHTMLPage) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            didLoad = false
            lastHighlights = parent.highlights
            installAppearance(in: webView, scroll: true)
        }

        func installAppearance(in web: WKWebView, scroll: Bool) {
            let prefs = parent.preferences
            let pal = parent.palette
            let fontFamily = prefs.font.css ?? "-apple-system"
            let margin = parent.comic ? 0 : (prefs.customMargins ? Int(prefs.margins / 3) : 16)
            let isPaged = prefs.navigation == .pages && !parent.comic
            let readableFontSize = min(78, max(12, UIFontMetrics(forTextStyle: .body).scaledValue(for: CGFloat(prefs.fontSize))))
            let css = """
                html, body { background: \(pal.bg) !important; color: \(pal.fg) !important; }
                body { font-family: \(fontFamily), serif !important;
                       font-size: \(readableFontSize)px !important;
                       font-weight: \(prefs.boldText ? "700" : "400") !important;
                       line-height: \(prefs.customLineSpacing ? prefs.lineSpacing : 1.55) !important;
                       letter-spacing: \(prefs.customCharacterSpacing ? prefs.characterSpacing : 0)em !important;
                       word-spacing: \(prefs.customWordSpacing ? prefs.wordSpacing : 0)em !important;
                       text-align: \(prefs.justify ? "justify" : "start") !important;
                       margin: \(margin)px !important;
                       -webkit-text-size-adjust: 100%; }
                body :is(p, li, blockquote, h1, h2, h3, h4, h5, h6, span) {
                    color: inherit !important;
                }
                img, svg, video { max-width: 100% !important; height: auto; }
                a { color: \(pal.accent) !important; }
                mark.folio-mobile-highlight { background: #F7D85F !important; color: #222 !important; border-radius: 2px; }
                \(isPaged ?
                    "html { height:100%; overflow-x:auto; overflow-y:hidden; scroll-snap-type:x mandatory; } body { height:calc(100vh - 6px) !important; column-width:calc(100vw - \(margin * 3)px); column-gap:\(margin * 2)px; column-fill:auto; overflow-y:hidden; margin:0 !important; padding:\(margin)px; box-sizing:border-box; }" :
                    (prefs.multipleColumns && !parent.comic ? "@media (min-width: 900px) { body { column-count: 2; column-gap: 44px; } }" : ""))
                """
            guard let encoded = try? JSONSerialization.data(withJSONObject: ["css": css], options: []),
                  let json = String(data: encoded, encoding: .utf8) else { return }
            let fraction = max(0, min(0.999, startFraction))
            let script = """
                (function () {
                    const styles = \(json);
                    let style = document.getElementById('folio-mobile-appearance');
                    if (!style) { style = document.createElement('style'); style.id = 'folio-mobile-appearance'; document.head.appendChild(style); }
                    style.textContent = styles.css;
                    \(scroll ? (isPaged
                        ? "requestAnimationFrame(() => window.scrollTo((document.documentElement.scrollWidth - innerWidth) * \(fraction), 0));"
                        : "requestAnimationFrame(() => window.scrollTo(0, (document.documentElement.scrollHeight - innerHeight) * \(fraction)));") : "")
                })();
                """
            web.evaluateJavaScript(script) { _, _ in
                self.didLoad = true
                Task { @MainActor in self.parent.interaction.restoreHighlights(self.parent.highlights) }
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard didLoad else { return }
            let horizontal = parent.preferences.navigation == .pages && !parent.comic
            let total = horizontal
                ? max(1, scrollView.contentSize.width - scrollView.bounds.width)
                : max(1, scrollView.contentSize.height - scrollView.bounds.height)
            let offset = horizontal ? scrollView.contentOffset.x : scrollView.contentOffset.y
            let fraction = max(0, min(0.999, offset / total))
            parent.onPositionChange(fraction)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if url.isFileURL || url.scheme == "about" {
                decisionHandler(.allow)
            } else {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            }
        }
    }
}

struct FolioMobilePDFPage: UIViewRepresentable {
    let document: PDFDocument
    let page: Int
    let interaction: FolioMobilePDFInteraction
    let background: String
    let onPageChange: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        interaction.view = view
        view.document = document
        view.autoScales = true
        view.displayDirection = .vertical
        view.displayMode = .singlePageContinuous
        view.backgroundColor = UIColor(Color(hex: background))
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: view,
            queue: .main
        ) { [weak view, weak coordinator = context.coordinator] _ in
            guard let view, let current = view.currentPage,
                  let idx = view.document?.index(for: current) else { return }
            coordinator?.parent.onPageChange(idx)
        }
        if let target = document.page(at: page) { view.go(to: target) }
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        interaction.view = view
        if view.document !== document { view.document = document }
        view.backgroundColor = UIColor(Color(hex: background))
        if let current = view.currentPage,
           document.index(for: current) == page { return }
        if let target = document.page(at: page) { view.go(to: target) }
    }

    final class Coordinator {
        var parent: FolioMobilePDFPage
        var observer: NSObjectProtocol?
        init(_ parent: FolioMobilePDFPage) { self.parent = parent }
        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}

struct FolioMobileReaderAppearance: View {
    @Environment(ReaderPrefsStore.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                FolioMobileReadabilitySettings()
                Section("Theme") {
                    Picker("Reading Theme", selection: Binding(
                        get: { preferences.prefs.theme },
                        set: { preferences.pickTheme($0) }
                    )) {
                        ForEach(ReaderTheme.allCases) { theme in
                            Text(theme.label).tag(theme)
                        }
                    }
                    Picker("Appearance", selection: Binding(
                        get: { preferences.appearance },
                        set: { preferences.appearance = $0 }
                    )) {
                        ForEach(ReaderAppearance.allCases) { appearance in
                            Text(appearance.label).tag(appearance)
                        }
                    }
                }
                Section("Text") {
                    Stepper(
                        "Font Size: \(preferences.prefs.fontSize) pt",
                        value: Binding(
                            get: { preferences.prefs.fontSizeIndex },
                            set: { preferences.prefs.fontSizeIndex = $0 }
                        ),
                        in: 0...(ReaderPrefs.fontSizes.count - 1)
                    )
                    Toggle("Bold Text", isOn: Binding(
                        get: { preferences.prefs.boldText },
                        set: { preferences.prefs.boldText = $0 }
                    ))
                }
            }
            .navigationTitle("Reading Appearance")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}
