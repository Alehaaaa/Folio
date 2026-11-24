import Foundation
import WebKit
import CryptoKit
#if os(iOS)
import UIKit
#endif

/// An offscreen, private WebKit page for each source extension. The JavaScriptCore
/// engine calls this bridge from its own serial worker, never from the main thread.
/// No NSWindow, NSViewRepresentable, external browser, or user-visible UI is made.
final class ExtensionBrowser: @unchecked Sendable {
    enum Command { case open, html, evaluate, url, waitFor, close }

    private let permitted: () -> Set<String>
    @MainActor private var page: ExtensionBrowserPage?
    @MainActor private var shutDown = false
    /// A browser operation may suspend across WebKit's asynchronous navigation.
    /// Never destroy its NSWindow/WKWebView underneath that suspended operation;
    /// request interruption first, then release the page after its final return.
    @MainActor private var activeOperations = 0

    init(permitted: @escaping () -> Set<String>) { self.permitted = permitted }

    /// Shares only same-origin, non-persistent WebKit session headers with the
    /// app's download request. The extension JS never sees browser cookies.
    /// This allows an ordinary browser verification to survive the transition
    /// from a rendered record page to Folio's file downloader.
    func requestHeaders(for url: URL) async -> [String: String] {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                guard !self.shutDown else {
                    continuation.resume(returning: [:])
                    return
                }
                guard let page = self.page else {
                    continuation.resume(returning: [:])
                    return
                }
                let headers = (try? await page.requestHeaders(for: url)) ?? [:]
                continuation.resume(returning: headers)
            }
        }
    }

    func perform(_ command: Command, argument: String = "") throws -> String {
        let completed = DispatchSemaphore(value: 0)
        let box = BrowserResponseBox()
        Task { @MainActor [self] in
            guard !self.shutDown else {
                box.set(.failure(ExtensionError(message: "This background browser was closed with its download job.")))
                completed.signal()
                return
            }
            self.activeOperations += 1
            defer {
                self.activeOperations -= 1
                if self.shutDown && self.activeOperations == 0 {
                    self.page?.close()
                    self.page = nil
                }
                completed.signal()
            }
            do {
                // Closing an unused per-job browser must not create a fresh
                // WKWebView (or attach a new offscreen UIView to an iOS window).
                if case .close = command, self.page == nil {
                    box.set(.success(""))
                    return
                }
                if self.page == nil {
                    self.page = ExtensionBrowserPage(permitted: { [weak self] in self?.permitted() ?? [] })
                }
                guard let page = self.page else { throw ExtensionError(message: "Browser was released.") }
                let response: String
                switch command {
                case .open: response = try await page.open(argument)
                case .html: response = try await page.html()
                case .evaluate: response = try await page.evaluate(argument)
                case .url: response = try page.currentURL()
                case .waitFor: response = try await page.waitFor(argument)
                case .close:
                    page.close()
                    self.page = nil
                    response = ""
                }
                box.set(.success(response))
            } catch { box.set(.failure(error)) }
        }
        // A failed or hung site must never block an extension's worker indefinitely.
        // Navigation may take 30 seconds, followed by up to 25 seconds of
        // ordinary JavaScript interstitial navigation. Keep the sync bridge
        // longer than the total bounded WebKit operation.
        guard completed.wait(timeout: .now() + 65) == .success else {
            throw ExtensionError(message: "Background browser timed out.")
        }
        return try box.result()
    }

    /// Force an in-flight browser countdown/navigation to stop when its job
    /// is cancelled or finished. Unlike the source-visible `browser.close()`,
    /// this also permanently rejects future commands from the finished job.
    func shutdown() async {
        await MainActor.run {
            guard !self.shutDown else { return }
            self.shutDown = true
            self.page?.interrupt()
            if self.activeOperations == 0 {
                self.page?.close()
                self.page = nil
            }
        }
    }
}

private final class BrowserResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<String, Error>?

    func set(_ newValue: Result<String, Error>) {
        lock.lock(); value = newValue; lock.unlock()
    }

    func result() throws -> String {
        lock.lock(); defer { lock.unlock() }
        return try (value ?? .failure(ExtensionError(message: "Browser did not respond."))).get()
    }
}

@MainActor
private final class ExtensionBrowserPage: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let permitted: () -> Set<String>
    private var web: WKWebView?
    #if os(macOS)
    private var offscreenHost: NSWindow?
    #else
    private var offscreenHost: UIView?
    #endif
    private var pending: CheckedContinuation<Void, Error>?
    private var deadline: Task<Void, Never>?
    private var interrupted = false

    init(permitted: @escaping () -> Set<String>) { self.permitted = permitted }

    /// Abort an in-flight await without releasing WebKit views that still have
    /// active async calls on their stack. ExtensionBrowser performs final
    /// teardown once its active operation counter reaches zero.
    func interrupt() {
        interrupted = true
        web?.stopLoading()
        finishNavigation(.failure(ExtensionError(message: "The background download job was cancelled.")))
    }

    private func checkInterrupted() throws {
        if interrupted {
            throw ExtensionError(message: "The background download job was cancelled.")
        }
    }

    private func check(_ url: URL) throws {
        guard let key = SourceRuntime.hostKey(url), permitted().contains(key) else {
            throw ExtensionError(message: "Background browser blocked an unapproved address: \(url.host ?? url.absoluteString)")
        }
    }

    /// Compiled WebKit content rules are native request filters, not the uBlock
    /// browser extension (which cannot be hosted inside WKWebView).
    private func installBlocker(into configuration: WKWebViewConfiguration) async throws {
        let hosts = permitted().sorted()
        var rules: [[String: Any]] = [
            // Do not allow a page to load third-party resources absent from the
            // extension's host allowlist, including scripts, pixels and frames.
            ["trigger": ["url-filter": ".*", "load-type": ["third-party"]], "action": ["type": "block"]]
        ]
        for key in hosts {
            guard let u = URL(string: key), let scheme = u.scheme, let host = u.host else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: host)
            let port = u.port.map { ":\($0)" } ?? ""
            rules.append(["trigger": ["url-filter": "^\(scheme)://\(escaped)\(port)/"], "action": ["type": "ignore-previous-rules"]])
        }
        let advertisingDomains = [
            "doubleclick.net", "googlesyndication.com", "google-analytics.com",
            "googletagmanager.com", "adservice.google.com", "adnxs.com",
            "adsrvr.org", "taboola.com", "outbrain.com", "criteo.com",
            "scorecardresearch.com", "hotjar.com", "facebook.net", "pubmatic.com",
            "rubiconproject.com", "openx.net", "quantserve.com"
        ]
        for domain in advertisingDomains {
            let escaped = NSRegularExpression.escapedPattern(for: domain)
            rules.append(["trigger": ["url-filter": "^https?://([^.]+\\.)*\(escaped)/"], "action": ["type": "block"]])
        }
        rules.append([
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none", "selector": "ins.adsbygoogle, [data-ad-slot], .OUTBRAIN, .taboola, [id^='google_ads_iframe']"]
        ])
        let data = try JSONSerialization.data(withJSONObject: rules)
        let encoded = String(decoding: data, as: UTF8.self)
        let id = SHA256.hash(data: Data(hosts.joined(separator: "|").utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let ruleList = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WKContentRuleList, Error>) in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "FolioBackgroundBrowser-\(id)-v1", encodedContentRuleList: encoded) { list, error in
                if let list { continuation.resume(returning: list) }
                else { continuation.resume(throwing: error ?? ExtensionError(message: "Could not compile the privacy blocker.")) }
            }
        }
        configuration.userContentController.add(ruleList)
    }

    private func prepare() async throws -> WKWebView {
        if let web { return web }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        try await installBlocker(into: configuration)
        let view = WKWebView(frame: .init(x: 0, y: 0, width: 1024, height: 768), configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        // WebKit can suspend document loading in a WKWebView that is not in
        // any view hierarchy. Keep a non-displayed, offscreen host instead.
        #if os(macOS)
        let host = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        // AppKit's default `isReleasedWhenClosed` can autorelease this window
        // inside close(). We also own it strongly in `offscreenHost`, so that
        // implicit AppKit release followed by ARC's release produces a
        // use-after-free (objc_release during the main actor's pool drain).
        // The caller owns the window lifetime exclusively.
        host.isReleasedWhenClosed = false
        host.contentView = view
        host.orderOut(nil)
        #else
        // Keep the private WebKit session in the active scene's view hierarchy
        // so iOS allows network navigation while the reader is foregrounded.
        // The host is one point, clipped and nearly transparent, and sits beneath the
        // app's own views: without the clip the 1024x768 page drew over the whole
        // window at 1% opacity, so a faded web page showed through the interface.
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        host.alpha = 0.01
        host.clipsToBounds = true
        host.isUserInteractionEnabled = false
        host.accessibilityElementsHidden = true
        host.addSubview(view)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
           let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first {
            window.insertSubview(host, at: 0)
        }
        #endif
        offscreenHost = host
        web = view
        return view
    }

    func open(_ string: String) async throws -> String {
        try checkInterrupted()
        guard let url = URL(string: string), url.user == nil, url.password == nil else {
            throw ExtensionError(message: "Invalid browser address.")
        }
        try check(url)
        let view = try await prepare()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            finishNavigation(.failure(ExtensionError(message: "Previous background navigation interrupted.")))
            pending = continuation
            deadline = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                self.web?.stopLoading()
                self.finishNavigation(.failure(ExtensionError(message: "Background browser navigation timed out.")))
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 30
            if view.load(request) == nil {
                finishNavigation(.failure(ExtensionError(message: "Background browser couldn't start navigation.")))
            }
        }
        try checkInterrupted()
        var document = try await html()
        // Some sites render a JavaScript "checking your browser" interstitial
        // first, then navigate to the requested document automatically. Simply
        // returning at the first didFinish() incorrectly reports a blocked page.
        // Give normal page scripts a bounded opportunity to settle; no CAPTCHA
        // solving, verification bypass or user-visible prompt is performed.
        if document.range(of: "data-ddg-origin", options: .caseInsensitive) != nil ||
            document.range(of: "<title>DDoS-Guard</title>", options: .caseInsensitive) != nil {
            let limit = ContinuousClock.now.advanced(by: .seconds(25))
            repeat {
                try await Task.sleep(for: .milliseconds(500))
                document = try await html()
                let ready = (try? await evaluate("document.readyState")) == "complete"
                if !document.localizedCaseInsensitiveContains("data-ddg-origin") &&
                    !document.localizedCaseInsensitiveContains("<title>DDoS-Guard</title>") &&
                    !view.isLoading && ready {
                    break
                }
            } while ContinuousClock.now < limit
        }
        return document
    }

    func html() async throws -> String {
        try await evaluate("document.documentElement ? document.documentElement.outerHTML : ''")
    }

    func currentURL() throws -> String {
        try checkInterrupted()
        guard let url = web?.url else { throw ExtensionError(message: "No page is open in the background browser.") }
        try check(url)
        return url.absoluteString
    }

    func requestHeaders(for url: URL) async throws -> [String: String] {
        try checkInterrupted()
        try check(url)
        guard let web else { return [:] }
        let cookies = await withCheckedContinuation { (continuation: CheckedContinuation<[HTTPCookie], Never>) in
            web.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        let host = (url.host ?? "").lowercased()
        let applicable = cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            let normalized = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            let matchesDomain = host == normalized || (domain.hasPrefix(".") && host.hasSuffix("." + normalized))
            return matchesDomain && url.path.hasPrefix(cookie.path) &&
                   (!cookie.isSecure || url.scheme?.lowercased() == "https") &&
                   (cookie.expiresDate == nil || cookie.expiresDate! > Date())
        }
        var headers: [String: String] = [:]
        if let header = HTTPCookie.requestHeaderFields(with: applicable)["Cookie"] {
            headers["Cookie"] = header
        }
        if let ua = try? await evaluate("navigator.userAgent"), !ua.isEmpty, ua.utf8.count < 1024 {
            headers["User-Agent"] = ua
        }
        return headers
    }

    func waitFor(_ selector: String) async throws -> String {
        try checkInterrupted()
        guard !selector.isEmpty, selector.utf8.count <= 1024 else {
            throw ExtensionError(message: "The browser selector is empty or too long.")
        }
        let encoded = String(data: try JSONSerialization.data(withJSONObject: [selector]), encoding: .utf8)!
        let quoted = String(encoded.dropFirst().dropLast())
        let limit = ContinuousClock.now.advanced(by: .seconds(15))
        repeat {
            try checkInterrupted()
            let found = try await evaluate("document.querySelector(\(quoted)) !== null")
            if found == "1" || found == "true" {
                return "true"
            }
            try await Task.sleep(for: .milliseconds(250))
        } while ContinuousClock.now < limit
        try checkInterrupted()
        // A countdown is expected to outlive individual 15-second polls. Let
        // an extension continue waiting and emit progress rather than treating
        // a normal countdown interval as a JavaScript exception.
        return "false"
    }

    func close() {
        finishNavigation(.failure(ExtensionError(message: "The background browser was closed.")))
        web?.stopLoading()
        web?.navigationDelegate = nil
        web?.uiDelegate = nil
        #if os(macOS)
        offscreenHost?.contentView = nil
        offscreenHost?.close()
        #else
        web?.removeFromSuperview()
        offscreenHost?.removeFromSuperview()
        #endif
        offscreenHost = nil
        web = nil
    }

    func evaluate(_ script: String) async throws -> String {
        try checkInterrupted()
        guard let view = web else { throw ExtensionError(message: "Open a page before evaluating JavaScript.") }
        guard let url = view.url else { throw ExtensionError(message: "The background browser has no page.") }
        try check(url)
        let result = try await view.evaluateJavaScript(script)
        try checkInterrupted()
        if let s = result as? String { return s }
        if result is NSNull { return "null" }
        if let result, JSONSerialization.isValidJSONObject(result) {
            let data = try JSONSerialization.data(withJSONObject: result)
            return String(decoding: data, as: UTF8.self)
        }
        return result.map { String(describing: $0) } ?? ""
    }

    private func finishNavigation(_ result: Result<Void, Error>) {
        guard let pending else { return }
        self.pending = nil
        deadline?.cancel()
        deadline = nil
        pending.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url {
            do { try check(url); finishNavigation(.success(())) }
            catch { finishNavigation(.failure(error)) }
        } else { finishNavigation(.failure(ExtensionError(message: "The browser arrived at an empty address."))) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // WebKit reports -999 for a navigation intentionally superseded by
        // a page's own redirect/reload (common after JS browser checks).
        // Only the eventual navigation or explicit deadline should settle it.
        if (error as NSError).domain == NSURLErrorDomain &&
           (error as NSError).code == NSURLErrorCancelled { return }
        finishNavigation(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).domain == NSURLErrorDomain &&
           (error as NSError).code == NSURLErrorCancelled { return }
        finishNavigation(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishNavigation(.failure(ExtensionError(message: "The background browser process stopped.")))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // Popup/target=_blank navigation is not an approved hidden browser tab.
        guard navigationAction.targetFrame != nil, let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        do { try check(url); decisionHandler(.allow) }
        catch {
            decisionHandler(.cancel)
            if navigationAction.targetFrame?.isMainFrame == true { finishNavigation(.failure(error)) }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        guard let url = navigationResponse.response.url else { decisionHandler(.cancel); return }
        do { try check(url); decisionHandler(.allow) }
        catch {
            decisionHandler(.cancel)
            if navigationResponse.isForMainFrame { finishNavigation(.failure(error)) }
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }
}
