import SwiftUI
import WebKit
import PDFKit
import Observation
import ImageIO

// MARK: - Web (EPUB, text, comics) reader model

struct ReaderSelection: Equatable {
    let text: String
    let prefix: String
    let suffix: String
}

@Observable
@MainActor
final class WebReaderModel {
    enum Target { case fraction(Double), end, fragment(String) }

    let content: WebContent
    var chapter = 0
    var page = 0
    var pages = 1
    var chapterFraction = 0.0
    var ready = false
    var selection: ReaderSelection?
    weak var webView: WKWebView?
    var pendingTarget: Target = .fraction(0)
    var lastConfig = ""
    var loadID = 0
    var activeNavigation: WKNavigation?
    private var navigationInFlight = false
    private var highlightedExcerpts: [[String: String]] = []

    init(content: WebContent, start: ReadingPosition) {
        self.content = content
        chapter = max(0, min(content.chapters.count - 1, start.chapter))
        pendingTarget = .fraction(start.fraction)
    }

    var totalSize: Double { content.chapterSizes.reduce(0, +) }

    var progress: Double {
        guard !content.chapters.isEmpty else { return 0 }
        let before = content.chapterSizes.prefix(chapter).reduce(0, +)
        let here = content.chapterSizes[chapter] * Double(page + 1) / Double(max(pages, 1))
        return min(1, (before + here) / max(totalSize, 1))
    }

    var atEnd: Bool { chapter == content.chapters.count - 1 && page >= pages - 1 }

    var chapterTitle: String {
        content.toc.last(where: { $0.chapter <= chapter })?.title ?? ""
    }

    var pagesLeftInChapter: Int { max(0, pages - page - 1) }

    func load(_ index: Int, target: Target) {
        guard content.chapters.indices.contains(index), let webView else { return }
        loadID &+= 1
        chapter = index
        pendingTarget = target
        ready = false
        selection = nil
        navigationInFlight = false
        highlightedExcerpts = []
        page = 0
        pages = 1
        chapterFraction = 0
        webView.alphaValue = 0
        activeNavigation = webView.loadFileURL(content.chapters[index], allowingReadAccessTo: content.root)
        // Never leave a blank page if layout takes long (slow fonts, huge images).
        let expectedLoadID = loadID
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.loadID == expectedLoadID, !self.ready else { return }
            self.webView?.alphaValue = 1
        }
    }

    func start() { load(chapter, target: pendingTarget) }

    func next() { navigate(1) }

    func previous() { navigate(-1) }

    private func navigate(_ direction: Int) {
        guard ready, !navigationInFlight, let webView else { return }
        navigationInFlight = true
        let expectedLoadID = loadID
        webView.evaluateJavaScript("folio.navigate(\(direction))") { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.loadID == expectedLoadID else { return }
                self.navigationInFlight = false
                guard self.ready, error == nil, let didTurn = result as? Bool, !didTurn else { return }
                let nextChapter = self.chapter + (direction > 0 ? 1 : -1)
                guard self.content.chapters.indices.contains(nextChapter) else { return }
                self.load(nextChapter, target: direction > 0 ? .fraction(0) : .end)
            }
        }
    }

    func clearSelection() {
        selection = nil
        guard ready else { return }
        webView?.evaluateJavaScript("folio.clearSelection()", completionHandler: nil)
    }

    /// Replace current-chapter excerpt highlights. May be called before the chapter is ready.
    func showHighlights(_ texts: [String]) {
        highlightedExcerpts = texts.map { ["text": $0] }
        guard ready else { return }
        applyHighlights()
    }

    /// Keeps saved selection context so identical quotes can be disambiguated.
    func showHighlights(_ annotations: [ReadingAnnotation]) {
        highlightedExcerpts = annotations
            .filter { $0.chapter == chapter && !$0.text.isEmpty }
            .map { ["text": $0.text, "prefix": $0.prefix, "suffix": $0.suffix] }
        guard ready else { return }
        applyHighlights()
    }

    func applyHighlights() {
        guard ready, let webView,
              let data = try? JSONSerialization.data(withJSONObject: highlightedExcerpts),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("folio.highlightAnnotations(\(json))", completionHandler: nil)
    }

    func go(_ entry: TOCEntry) {
        if let f = entry.fragment { load(entry.chapter, target: .fragment(f)) } else { load(entry.chapter, target: .fraction(0)) }
    }

    /// Jump to an overall position (0...1) in the book, used by the scrubber.
    func seek(_ overall: Double) {
        var acc = 0.0
        let target = overall * totalSize
        for (i, s) in content.chapterSizes.enumerated() {
            if acc + s >= target || i == content.chapterSizes.count - 1 {
                let f = max(0, min(0.999, (target - acc) / max(s, 1)))
                if i == chapter {
                    if ready { webView?.evaluateJavaScript("folio.goFraction(\(f))", completionHandler: nil) }
                    else { pendingTarget = .fraction(f) }
                } else { load(i, target: .fraction(f)) }
                return
            }
            acc += s
        }
    }

    static func config(_ p: ReaderPrefs, dark: Bool, comic: Bool) -> String {
        let pal = p.theme.palette(dark: dark)
        var c: [String: Any] = [
            "bg": pal.bg, "fg": pal.fg, "accent": pal.accent,
            "fontSize": p.fontSize, "mode": p.navigation.rawValue,
            "columns": p.multipleColumns, "justify": p.justify, "bold": p.boldText,
            "margin": p.customMargins ? p.margins : 56, "comic": comic,
        ]
        if let f = p.font.css { c["font"] = f }
        if p.customLineSpacing { c["lineHeight"] = p.lineSpacing }
        if p.customCharacterSpacing { c["letterSpacing"] = p.characterSpacing }
        if p.customWordSpacing { c["wordSpacing"] = p.wordSpacing }
        let d = (try? JSONSerialization.data(withJSONObject: c)) ?? Data("{}".utf8)
        return String(data: d, encoding: .utf8) ?? "{}"
    }
}

private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

struct WebReaderView: NSViewRepresentable {
    let model: WebReaderModel
    let config: String

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView {
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: ReaderScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.add(WeakHandler(context.coordinator), name: "folio")
        let cfg = WKWebViewConfiguration()
        cfg.userContentController = ucc
        cfg.preferences.isElementFullscreenEnabled = false
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.setValue(false, forKey: "drawsBackground")
        wv.allowsMagnification = false
        model.webView = wv
        model.lastConfig = config
        context.coordinator.config = config
        model.start()
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        context.coordinator.config = config
        if model.lastConfig != config {
            model.lastConfig = config
            wv.evaluateJavaScript("folio.restyle(\(config))")
        }
    }

    static func dismantleNSView(_ wv: WKWebView, coordinator: Coordinator) {
        wv.configuration.userContentController.removeScriptMessageHandler(forName: "folio")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let model: WebReaderModel
        var config = "{}"
        private var decorationLoadID = -1
        private var decorationRequestCount = 0
        init(model: WebReaderModel) { self.model = model }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === model.activeNavigation, model.webView === webView else { return }
            let target: String
            switch model.pendingTarget {
            case .fraction(let f): target = "{\"kind\":\"fraction\",\"value\":\(f)}"
            case .end: target = "{\"kind\":\"end\"}"
            case .fragment(let id):
                let data = try? JSONSerialization.data(withJSONObject: ["kind": "fragment", "value": id])
                target = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"kind\":\"fraction\",\"value\":0}"
            }
            let loadID = model.loadID
            webView.evaluateJavaScript("folio.apply(\(config), \(target), \(loadID)); true") { _, error in
                if let error {
                    FileHandle.standardError.write(Data("reader script error: \(error)\n".utf8))
                    if self.model.loadID == loadID { webView.alphaValue = 1 }
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, let url = action.request.url else { return decisionHandler(.allow) }
            if url.isFileURL {
                let path = url.standardizedFileURL.path
                if let i = model.content.chapters.firstIndex(where: { $0.standardizedFileURL.path == path }) {
                    if let f = url.fragment { model.load(i, target: .fragment(f)) } else { model.load(i, target: .fraction(0)) }
                }
            } else {
                NSWorkspace.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            guard let body = m.body as? [String: Any], let type = body["type"] as? String else { return }
            guard let loadID = body["loadID"] as? Int, loadID == model.loadID else { return }
            switch type {
            case "pos":
                model.page = body["page"] as? Int ?? 0
                model.pages = max(1, body["pages"] as? Int ?? 1)
                model.chapterFraction = body["frac"] as? Double ?? 0
            case "ready":
                model.ready = true
                model.applyHighlights()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    model.webView?.animator().alphaValue = 1
                }
            case "nav":
                if (body["dir"] as? Int ?? 1) > 0 { model.next() } else { model.previous() }
            case "selection":
                if let text = body["text"] as? String, !text.isEmpty {
                    model.selection = ReaderSelection(
                        text: text,
                        prefix: body["prefix"] as? String ?? "",
                        suffix: body["suffix"] as? String ?? ""
                    )
                } else {
                    model.selection = nil
                }
            case "decorate":
                sendDecorationData(for: body, message: m)
            default: break
            }
        }

        /// WKWebView deliberately taints file:// images when drawn into a canvas.
        /// Expose only small, decoded raster resources inside the active EPUB root
        /// as data URLs so the reader can safely recolor monochrome ornaments.
        private func sendDecorationData(for body: [String: Any], message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  let requestID = body["requestID"] as? Int, requestID > 0,
                  let webView = model.webView, message.webView === webView else { return }
            if decorationLoadID != model.loadID {
                decorationLoadID = model.loadID
                decorationRequestCount = 0
            }
            var dataURL: String?
            if decorationRequestCount < 24,
               let source = body["src"] as? String,
               let sourceURL = URL(string: source), sourceURL.isFileURL {
                decorationRequestCount += 1
                let root = model.content.root.standardizedFileURL.resolvingSymlinksInPath()
                let file = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
                let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
                let mimeByExtension = [
                    "jpg": "image/jpeg", "jpeg": "image/jpeg",
                    "png": "image/png", "webp": "image/webp",
                    "gif": "image/gif", "bmp": "image/bmp"
                ]
                if file.path.hasPrefix(rootPath),
                   let mime = mimeByExtension[file.pathExtension.lowercased()],
                   let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                   attributes[.type] as? FileAttributeType == .typeRegular,
                   let byteCount = attributes[.size] as? NSNumber,
                   byteCount.intValue > 0, byteCount.intValue <= 1_000_000,
                   let bytes = try? Data(contentsOf: file, options: .mappedIfSafe),
                   let image = CGImageSourceCreateWithData(bytes as CFData, nil),
                   CGImageSourceGetCount(image) == 1,
                   let metadata = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                   let width = metadata[kCGImagePropertyPixelWidth] as? Int,
                   let height = metadata[kCGImagePropertyPixelHeight] as? Int,
                   width >= 8, height >= 8,
                   width <= 640, height <= 640,
                   width * height <= 200_000 {
                    dataURL = "data:\(mime);base64,\(bytes.base64EncodedString())"
                }
            }
            let serialized = (try? JSONEncoder().encode(dataURL))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
            webView.evaluateJavaScript(
                "if (window.folio) folio.receiveDecorationData(\(requestID), \(serialized))",
                completionHandler: nil
            )
        }
    }
}

// MARK: - PDF reader

@Observable
@MainActor
final class PDFReaderModel {
    let document: PDFDocument
    var pageIndex = 0
    var selection: ReaderSelection?
    weak var view: PDFView?

    init(document: PDFDocument, start: Int) {
        self.document = document
        pageIndex = max(0, min(document.pageCount - 1, start))
    }

    var pageCount: Int { max(1, document.pageCount) }
    var progress: Double { Double(pageIndex + 1) / Double(pageCount) }
    var atEnd: Bool { pageIndex >= pageCount - 1 }

    var toc: [TOCEntry] {
        var out: [TOCEntry] = []
        func walk(_ o: PDFOutline, level: Int) {
            for i in 0..<o.numberOfChildren {
                guard let c = o.child(at: i) else { continue }
                if let p = c.destination?.page { out.append(TOCEntry(title: c.label ?? "Section", level: level, chapter: document.index(for: p))) }
                walk(c, level: level + 1)
            }
        }
        if let root = document.outlineRoot { walk(root, level: 0) }
        return out
    }

    func go(_ index: Int) {
        guard let p = document.page(at: max(0, min(document.pageCount - 1, index))) else { return }
        view?.go(to: p)
    }

    func next() { view?.goToNextPage(nil) }
    func previous() { view?.goToPreviousPage(nil) }

    func clearSelection() {
        selection = nil
        view?.clearSelection()
    }
}

struct PDFReaderView: NSViewRepresentable {
    let model: PDFReaderModel
    let prefs: ReaderPrefs
    let dark: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.document = model.document
        v.autoScales = true
        v.displaysPageBreaks = true
        v.pageShadowsEnabled = true
        model.view = v
        apply(v)
        if let p = model.document.page(at: model.pageIndex) { v.go(to: p) }
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.changed(_:)), name: .PDFViewPageChanged, object: v)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.selectionChanged(_:)), name: .PDFViewSelectionChanged, object: v)
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) { apply(v) }

    static func dismantleNSView(_ v: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewPageChanged, object: v)
        NotificationCenter.default.removeObserver(coordinator, name: .PDFViewSelectionChanged, object: v)
    }

    private func apply(_ v: PDFView) {
        let mode: PDFDisplayMode = prefs.navigation == .scroll
            ? (prefs.multipleColumns ? .twoUpContinuous : .singlePageContinuous)
            : (prefs.multipleColumns ? .twoUp : .singlePage)
        if v.displayMode != mode { v.displayMode = mode; v.displaysAsBook = prefs.multipleColumns }
        v.backgroundColor = NSColor(Color(hex: prefs.theme.palette(dark: dark).bg))
    }

    @MainActor
    final class Coordinator: NSObject {
        let model: PDFReaderModel
        init(model: PDFReaderModel) { self.model = model }
        @objc func changed(_ n: Notification) {
            guard let v = n.object as? PDFView, let p = v.currentPage, let doc = v.document else { return }
            model.pageIndex = doc.index(for: p)
        }

        @objc func selectionChanged(_ n: Notification) {
            guard let view = n.object as? PDFView,
                  let picked = view.currentSelection,
                  let text = picked.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                model.selection = nil
                return
            }
            var prefix = ""
            var suffix = ""
            if let pageText = picked.pages.first?.string,
               let range = pageText.range(of: text) {
                prefix = String(pageText[..<range.lowerBound].suffix(80))
                suffix = String(pageText[range.upperBound...].prefix(80))
            }
            model.selection = ReaderSelection(text: text, prefix: prefix, suffix: suffix)
        }
    }
}
