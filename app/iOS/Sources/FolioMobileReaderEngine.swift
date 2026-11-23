import SwiftUI
import WebKit
import UIKit
import Observation

/// Text chosen in the current chapter, with surrounding context so a saved
/// highlight can be found again even when the same phrase repeats.
struct FolioMobileSelection: Equatable {
    let text: String
    let prefix: String
    let suffix: String
}

/// The edit-menu actions Folio adds next to Copy, Look Up and Translate.
enum FolioMobileSelectionAction {
    case highlight, note, quote, more
}

/// Drives one EPUB/HTML book on iOS with the same `ReaderScript` page engine
/// as the macOS reader: exact column pagination, anchor-preserving restyles,
/// non-destructive CSS highlights, fragment links and selection context.
@Observable
@MainActor
final class FolioMobileReaderEngine {
    enum Target { case fraction(Double), end, fragment(String) }

    let content: WebContent
    private(set) var chapter = 0
    private(set) var page = 0
    private(set) var pages = 1
    private(set) var chapterFraction = 0.0
    private(set) var ready = false
    var selection: FolioMobileSelection?

    /// Set by the host view; called after the reader moves to a new position.
    @ObservationIgnored var onPositionChange: (() -> Void)?
    /// Set by the host view; a tap outside a link, as a 0...1 fraction of width.
    @ObservationIgnored var onTap: ((Double) -> Void)?
    /// Set by the host view; the user turned a page or chapter.
    @ObservationIgnored var onTurn: (() -> Void)?
    /// Set by the host view; the book's saved annotations, read when a chapter is ready.
    @ObservationIgnored var annotationsForBook: (() -> [ReadingAnnotation])?

    @ObservationIgnored weak var webView: FolioMobileReaderWebView?
    @ObservationIgnored var lastConfig = ""
    @ObservationIgnored private(set) var loadID = 0
    @ObservationIgnored private(set) var pendingTarget: Target
    @ObservationIgnored var activeNavigation: WKNavigation?
    @ObservationIgnored private var navigationInFlight = false
    @ObservationIgnored private var highlightPayload: [[String: String]] = []
    @ObservationIgnored private var turnCover: UIView?
    @ObservationIgnored private var turnDirection = 1

    init(content: WebContent, chapter: Int, fraction: Double) {
        self.content = content
        self.chapter = max(0, min(content.chapters.count - 1, chapter))
        self.chapterFraction = max(0, min(0.999, fraction))
        pendingTarget = .fraction(max(0, min(0.999, fraction)))
    }

    var paginated = true

    // MARK: Position

    private var totalSize: Double { max(1, content.chapterSizes.reduce(0, +)) }

    private func size(of index: Int) -> Double {
        content.chapterSizes.indices.contains(index) ? max(0, content.chapterSizes[index]) : 1
    }

    /// Overall book progress, counting the page being read as read.
    var progress: Double {
        guard !content.chapters.isEmpty else { return 0 }
        let before = content.chapterSizes.prefix(chapter).reduce(0, +)
        let here: Double
        if paginated { here = size(of: chapter) * Double(page + 1) / Double(max(pages, 1)) }
        else { here = size(of: chapter) * chapterFraction }
        return min(1, (before + here) / totalSize)
    }

    var pagesLeftInChapter: Int { max(0, pages - page - 1) }
    var isFirstChapter: Bool { chapter == 0 }
    var isLastChapter: Bool { chapter >= content.chapters.count - 1 }
    var atStart: Bool { chapter == 0 && (paginated ? page == 0 : chapterFraction < 0.001) }
    var atEnd: Bool { isLastChapter && (paginated ? page >= pages - 1 : chapterFraction > 0.995) }

    func title(ofChapter index: Int) -> String {
        content.toc.last(where: { $0.chapter <= index })?.title ?? "Chapter \(index + 1)"
    }

    var chapterTitle: String { title(ofChapter: chapter) }

    /// The chapter and in-chapter fraction an overall 0...1 position lands on.
    func location(at overall: Double) -> (chapter: Int, fraction: Double) {
        let target = max(0, min(1, overall)) * totalSize
        var running = 0.0
        for index in content.chapters.indices {
            let length = size(of: index)
            if target <= running + length || index == content.chapters.count - 1 {
                return (index, max(0, min(0.999, (target - running) / max(length, 1))))
            }
            running += length
        }
        return (0, 0)
    }

    // MARK: Loading and navigation

    func start() { load(chapter, target: pendingTarget) }

    func load(_ index: Int, target: Target, turning direction: Int? = nil) {
        guard content.chapters.indices.contains(index), let webView else { return }
        loadID &+= 1
        chapter = index
        pendingTarget = target
        ready = false
        selection = nil
        navigationInFlight = false
        page = 0
        pages = 1
        switch target {
        case .fraction(let value): chapterFraction = max(0, min(0.999, value))
        case .end: chapterFraction = 0.999
        case .fragment: chapterFraction = 0
        }
        if let direction { coverForTurn(direction) } else if turnCover == nil { webView.alpha = 0 }
        activeNavigation = webView.loadFileURL(content.chapters[index], allowingReadAccessTo: content.root)
        // Never leave a blank page if layout takes long (slow fonts, huge images).
        let expected = loadID
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.loadID == expected, !self.ready else { return }
            self.revealAfterLoad()
        }
    }

    /// Turn one page (or one screen in Scroll mode); crosses chapters at the edges.
    func turn(_ direction: Int) {
        guard ready, !navigationInFlight, let webView else { return }
        navigationInFlight = true
        selection = nil
        let expected = loadID
        let animate = paginated
        if animate { coverForTurn(direction) }
        webView.evaluateJavaScript("folio.navigate(\(direction))") { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.loadID == expected else { return }
                self.navigationInFlight = false
                let didTurn = (result as? Bool) ?? false
                if error == nil, didTurn {
                    self.onTurn?()
                    if animate { self.finishTurn(after: 0.05) }
                    return
                }
                let next = self.chapter + (direction > 0 ? 1 : -1)
                guard error == nil, self.content.chapters.indices.contains(next) else {
                    self.cancelTurn()
                    return
                }
                self.onTurn?()
                self.load(next, target: direction > 0 ? .fraction(0) : .end, turning: animate ? direction : nil)
            }
        }
    }

    func go(_ entry: TOCEntry) {
        if let fragment = entry.fragment { load(entry.chapter, target: .fragment(fragment)) }
        else { load(entry.chapter, target: .fraction(0)) }
    }

    func go(chapter index: Int, fraction: Double) {
        if index == chapter, ready {
            webView?.evaluateJavaScript("folio.goFraction(\(max(0, min(0.999, fraction))))", completionHandler: nil)
        } else {
            load(index, target: .fraction(fraction))
        }
    }

    func seek(_ overall: Double) {
        let target = location(at: overall)
        go(chapter: target.chapter, fraction: target.fraction)
    }

    func openLink(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard let index = content.chapters.firstIndex(where: { $0.standardizedFileURL.path == path }) else { return }
        if let fragment = url.fragment, !fragment.isEmpty {
            if index == chapter, ready, let data = try? JSONEncoder().encode(fragment),
               let json = String(data: data, encoding: .utf8) {
                webView?.evaluateJavaScript("folio.goFragment(\(json))", completionHandler: nil)
            } else {
                load(index, target: .fragment(fragment))
            }
        } else if index != chapter {
            load(index, target: .fraction(0))
        }
    }

    // MARK: Appearance, highlights and selection

    func restyle(_ config: String) {
        guard config != lastConfig else { return }
        lastConfig = config
        guard ready else { return } // `apply` picks up lastConfig after the load.
        webView?.evaluateJavaScript("folio.restyle(\(config))", completionHandler: nil)
    }

    /// Repaint saved highlights and notes for the current chapter.
    func refreshHighlights() {
        guard let annotations = annotationsForBook?() else { return }
        highlightPayload = annotations
            .filter { $0.chapter == chapter && !$0.text.isEmpty && ($0.kind == .highlight || $0.kind == .note) }
            .map { ["text": $0.text, "prefix": $0.prefix, "suffix": $0.suffix] }
        applyHighlights()
    }

    private func applyHighlights() {
        guard ready, let webView,
              let data = try? JSONSerialization.data(withJSONObject: highlightPayload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("folio.highlightAnnotations(\(json))", completionHandler: nil)
    }

    /// The live selection, asking the page directly if no message has arrived yet.
    func currentSelection() async -> FolioMobileSelection? {
        if let selection { return selection }
        guard let webView else { return nil }
        let script = "(function(){const s=window.getSelection();return s&&!s.isCollapsed?String(s).trim().slice(0,3000):'';})()"
        guard let text = try? await webView.evaluateJavaScript(script) as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return FolioMobileSelection(text: text, prefix: "", suffix: "")
    }

    func clearSelection() {
        selection = nil
        guard ready else { return }
        webView?.evaluateJavaScript("folio.clearSelection()", completionHandler: nil)
    }

    // MARK: Script messages

    func receive(_ body: [String: Any], from webView: WKWebView) {
        guard let type = body["type"] as? String,
              let messageLoadID = body["loadID"] as? Int, messageLoadID == loadID else { return }
        switch type {
        case "pos":
            page = max(0, body["page"] as? Int ?? 0)
            pages = max(1, body["pages"] as? Int ?? 1)
            chapterFraction = max(0, min(0.999, (body["frac"] as? Double) ?? Double(body["frac"] as? Int ?? 0)))
            onPositionChange?()
        case "ready":
            ready = true
            refreshHighlights()
            // A change made while the chapter was loading is applied now.
            webView.evaluateJavaScript("folio.restyle(\(lastConfig))", completionHandler: nil)
            revealAfterLoad()
            onPositionChange?()
        case "nav":
            turn((body["dir"] as? Int ?? 1) > 0 ? 1 : -1)
        case "tap":
            let x = (body["x"] as? Double) ?? Double(body["x"] as? Int ?? 0)
            // ReaderScript already turned the page for taps on the outer edges.
            if paginated && (x < 0.12 || x > 0.88) { return }
            onTap?(x)
        case "selection":
            if let text = body["text"] as? String, !text.isEmpty {
                selection = FolioMobileSelection(
                    text: String(text.prefix(3000)),
                    prefix: body["prefix"] as? String ?? "",
                    suffix: body["suffix"] as? String ?? ""
                )
            } else {
                selection = nil
            }
        default:
            break
        }
    }

    func applyTarget(in webView: WKWebView) {
        let target: String
        switch pendingTarget {
        case .fraction(let value): target = "{\"kind\":\"fraction\",\"value\":\(max(0, min(0.999, value)))}"
        case .end: target = "{\"kind\":\"end\"}"
        case .fragment(let id):
            let data = try? JSONSerialization.data(withJSONObject: ["kind": "fragment", "value": id])
            target = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"kind\":\"fraction\",\"value\":0}"
        }
        let expected = loadID
        webView.evaluateJavaScript("folio.apply(\(lastConfig), \(target), \(expected)); true") { [weak self] _, error in
            Task { @MainActor in
                guard let self, error != nil, self.loadID == expected else { return }
                self.revealAfterLoad()
            }
        }
    }

    // MARK: Page-turn animation

    /// Freeze the current page on top while the web view moves underneath.
    private func coverForTurn(_ direction: Int) {
        guard let webView, let host = webView.superview else { return }
        turnCover?.removeFromSuperview()
        turnCover = nil
        guard let snapshot = webView.snapshotView(afterScreenUpdates: false) else { return }
        snapshot.frame = webView.frame
        snapshot.backgroundColor = webView.backgroundColor
        snapshot.layer.shadowColor = UIColor.black.cgColor
        snapshot.layer.shadowOpacity = 0.12
        snapshot.layer.shadowRadius = 8
        snapshot.layer.shadowOffset = .zero
        host.addSubview(snapshot)
        turnCover = snapshot
        turnDirection = direction
        webView.alpha = 1
    }

    private func finishTurn(after delay: TimeInterval) {
        guard let cover = turnCover else { return }
        turnCover = nil
        let direction = turnDirection
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if UIAccessibility.isReduceMotionEnabled {
                UIView.animate(withDuration: 0.18, animations: { cover.alpha = 0 }) { _ in cover.removeFromSuperview() }
            } else {
                let width = cover.bounds.width
                UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
                    cover.transform = CGAffineTransform(translationX: direction > 0 ? -width : width, y: 0)
                } completion: { _ in cover.removeFromSuperview() }
            }
        }
    }

    private func cancelTurn() {
        turnCover?.removeFromSuperview()
        turnCover = nil
    }

    private func revealAfterLoad() {
        if turnCover != nil {
            webView?.alpha = 1
            finishTurn(after: 0)
        } else if let webView, webView.alpha < 1 {
            UIView.animate(withDuration: 0.18) { webView.alpha = 1 }
        }
    }
}

/// Adds Folio's annotation commands to the native text edit menu.
final class FolioMobileReaderWebView: WKWebView {
    var selectionAction: ((FolioMobileSelectionAction) -> Void)?

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .context, let selectionAction else { return }
        let actions = [
            UIAction(title: "Highlight", image: UIImage(systemName: "highlighter")) { _ in selectionAction(.highlight) },
            UIAction(title: "Add Note", image: UIImage(systemName: "note.text.badge.plus")) { _ in selectionAction(.note) },
            UIAction(title: "Save Quote", image: UIImage(systemName: "quote.bubble")) { _ in selectionAction(.quote) },
            UIAction(title: "More…", image: UIImage(systemName: "ellipsis.circle")) { _ in selectionAction(.more) },
        ]
        let menu = UIMenu(title: "", identifier: UIMenu.Identifier("app.folio.reader.annotate"),
                          options: .displayInline, children: actions)
        if builder.menu(for: .standardEdit) != nil {
            builder.insertSibling(menu, beforeMenu: .standardEdit)
        } else {
            builder.insertChild(menu, atStartOfMenu: .root)
        }
    }
}

/// iOS-only additions that run beside `ReaderScript`: a phone-sized viewport
/// for EPUB chapters that do not declare one, and tap reporting for chrome
/// and page-turn zones.
enum FolioMobileReaderBridge {
    static let source = #"""
(function(){
if (window.folioIOS) return;
window.folioIOS = true;
const viewport = 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover';
function ensureViewport(){
  const parent = document.head || document.documentElement;
  if (!parent) return;
  const metas = document.querySelectorAll('meta[name="viewport"]');
  let meta = metas[0];
  for (let i = 1; i < metas.length; i++) metas[i].remove();
  if (!meta) {
    meta = document.createElement('meta');
    meta.setAttribute('name', 'viewport');
    parent.insertBefore(meta, parent.firstChild);
  }
  if (meta.getAttribute('content') !== viewport) meta.setAttribute('content', viewport);
}
ensureViewport();
document.addEventListener('DOMContentLoaded', ensureViewport);

let hadSelection = false, clearedAt = 0;
document.addEventListener('selectionchange', () => {
  const s = window.getSelection();
  const active = !!(s && !s.isCollapsed && String(s).length);
  if (hadSelection && !active) clearedAt = Date.now();
  hadSelection = active;
});
document.addEventListener('click', ev => {
  if (ev.defaultPrevented) return;
  const t = ev.target;
  if (t && t.closest && t.closest('a[href],button,input,select,textarea,video,audio,label,summary,[contenteditable="true"],[role="button"],[onclick]')) return;
  if (hadSelection || Date.now() - clearedAt < 500) return;
  const w = Math.max(1, document.documentElement.clientWidth || window.innerWidth);
  try {
    window.webkit.messageHandlers.folio.postMessage({
      type: 'tap', x: ev.clientX / w, loadID: window.folio ? window.folio.loadID : null
    });
  } catch (e) {}
});
})();
"""#
}

private final class FolioMobileWeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// Hosts the engine's WKWebView: paged mode turns pages with taps and swipes
/// (no free horizontal scrolling), Scroll mode pulls past either end of a
/// chapter to continue into the next or previous one.
struct FolioMobileEPUBPage: UIViewRepresentable {
    let engine: FolioMobileReaderEngine
    let config: String
    let paginated: Bool
    let background: String
    let selectionAction: (FolioMobileSelectionAction) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(engine: engine) }

    func makeUIView(context: Context) -> UIView {
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: ReaderScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: FolioMobileReaderBridge.source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(FolioMobileWeakScriptHandler(context.coordinator), name: "folio")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.dataDetectorTypes = []
        configuration.allowsInlineMediaPlayback = true
        let web = FolioMobileReaderWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false
        web.navigationDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = false
        web.allowsLinkPreview = false
        web.scrollView.delegate = context.coordinator
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.showsHorizontalScrollIndicator = false
        web.scrollView.alwaysBounceHorizontal = false
        web.scrollView.pinchGestureRecognizer?.isEnabled = false
        web.selectionAction = selectionAction
        web.translatesAutoresizingMaskIntoConstraints = false

        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swiped(_:)))
            swipe.direction = direction
            swipe.delegate = context.coordinator
            web.addGestureRecognizer(swipe)
            context.coordinator.swipes.append(swipe)
        }

        // A container lets page-turn snapshots sit above the web view.
        let container = UIView()
        container.clipsToBounds = true
        container.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.topAnchor.constraint(equalTo: container.topAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        context.coordinator.web = web
        apply(to: web, coordinator: context.coordinator)
        engine.webView = web
        engine.lastConfig = config
        if engine.paginated != paginated { engine.paginated = paginated }
        engine.start()
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        guard let web = context.coordinator.web else { return }
        web.selectionAction = selectionAction
        if engine.paginated != paginated { engine.paginated = paginated }
        apply(to: web, coordinator: context.coordinator)
        engine.restyle(config)
    }

    private func apply(to web: WKWebView, coordinator: Coordinator) {
        let color = UIColor(Color(hex: background))
        web.backgroundColor = color
        web.scrollView.backgroundColor = color
        web.superview?.backgroundColor = color
        web.underPageBackgroundColor = color
        web.scrollView.isScrollEnabled = !paginated
        web.scrollView.bounces = !paginated
        web.scrollView.alwaysBounceVertical = !paginated
        web.scrollView.showsVerticalScrollIndicator = !paginated
        coordinator.swipes.forEach { $0.isEnabled = paginated }
    }

    static func dismantleUIView(_ container: UIView, coordinator: Coordinator) {
        coordinator.web?.configuration.userContentController.removeScriptMessageHandler(forName: "folio")
        coordinator.web?.scrollView.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        let engine: FolioMobileReaderEngine
        weak var web: FolioMobileReaderWebView?
        var swipes: [UISwipeGestureRecognizer] = []
        private var decorationLoadID = -1
        private var decorationRequests = 0

        init(engine: FolioMobileReaderEngine) { self.engine = engine }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === engine.activeNavigation else { return }
            engine.applyTarget(in: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            webView.alpha = 1
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            webView.alpha = 1
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard action.navigationType == .linkActivated, let url = action.request.url else {
                decisionHandler(.allow)
                return
            }
            if url.isFileURL {
                engine.openLink(url)
            } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
            }
            decisionHandler(.cancel)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            // Memory pressure can kill WebKit's renderer; reopen at the same place.
            engine.load(engine.chapter, target: .fraction(engine.chapterFraction))
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let web, message.webView === web else { return }
            if body["type"] as? String == "decorate" {
                sendDecorationData(for: body, message: message, in: web)
            } else {
                engine.receive(body, from: web)
            }
        }

        private func sendDecorationData(for body: [String: Any], message: WKScriptMessage, in web: WKWebView) {
            guard message.frameInfo.isMainFrame,
                  let requestID = body["requestID"] as? Int, requestID > 0,
                  body["loadID"] as? Int == engine.loadID else { return }
            if decorationLoadID != engine.loadID {
                decorationLoadID = engine.loadID
                decorationRequests = 0
            }
            var dataURL: String?
            if decorationRequests < 24 {
                decorationRequests += 1
                dataURL = ReaderScript.decorationDataURL(source: body["src"] as? String, root: engine.content.root)
            }
            let serialized = (try? JSONEncoder().encode(dataURL)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
            web.evaluateJavaScript("if (window.folio) folio.receiveDecorationData(\(requestID), \(serialized))",
                                   completionHandler: nil)
        }

        @objc func swiped(_ gesture: UISwipeGestureRecognizer) {
            guard engine.paginated, engine.selection == nil else { return }
            engine.turn(gesture.direction == .left ? 1 : -1)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                       targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            guard !engine.paginated, engine.ready else { return }
            let pull: CGFloat = 72
            let bottom = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            if scrollView.contentOffset.y > bottom + pull, !engine.isLastChapter {
                engine.load(engine.chapter + 1, target: .fraction(0))
            } else if scrollView.contentOffset.y < -pull, !engine.isFirstChapter {
                engine.load(engine.chapter - 1, target: .end)
            }
        }
    }
}
