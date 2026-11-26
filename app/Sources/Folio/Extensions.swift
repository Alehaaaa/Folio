import Foundation
import CryptoKit
import JavaScriptCore
import Observation

// MARK: - What a source extension returns

struct SourceDownload: Hashable {
    var format: String
    var url: URL

    /// Formats Folio's reader can open.
    var readable: Bool { ["epub", "pdf", "cbz", "txt", "md", "rtf", "html", "htm"].contains(format) }
}

struct SourceResult: Identifiable, Hashable {
    var id: String
    var title: String
    var authors: [String]
    var cover: URL?
    var year: Int?
    /// Optional provider-reported popularity. Never infer this from the number
    /// of mirror URLs: multiple links can all refer to the same single file.
    var downloadCount: Int?
    var origin: String
    var downloads: [SourceDownload]
    /// Language of this particular edition; missing is never assumed English.
    var language: String? = nil

    var author: String { authors.joined(separator: ", ") }

    /// Best format to fetch: EPUB first, as demeter does by default.
    var preferred: SourceDownload? {
        for f in ["epub", "pdf", "cbz", "txt", "md", "rtf", "html"] {
            if let d = downloads.first(where: { $0.format == f }) { return d }
        }
        return nil
    }

    static func from(_ any: Any) -> SourceResult? {
        guard let d = any as? [String: Any], let title = d["title"] as? String else { return nil }
        let downloads: [SourceDownload] = (d["downloads"] as? [[String: Any]] ?? []).compactMap {
            guard let f = $0["format"] as? String, let u = ($0["url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return SourceDownload(format: f.lowercased(), url: u)
        }
        return SourceResult(
            id: (d["id"] as? String) ?? (d["id"] as? NSNumber)?.stringValue ?? UUID().uuidString,
            title: title,
            authors: (d["authors"] as? [String]) ?? [],
            cover: (d["cover"] as? String).flatMap(URL.init(string:)),
            year: (d["year"] as? NSNumber)?.intValue,
            downloadCount: (d["downloadCount"] as? NSNumber).flatMap { $0.intValue >= 0 ? $0.intValue : nil },
            origin: (d["origin"] as? String) ?? "",
            downloads: downloads,
            language: (d["language"] as? String) ??
                ((d["languages"] as? [String]).flatMap { $0.count == 1 ? $0.first : nil })
        )
    }
}

struct SourceSetting: Hashable {
    var key: String
    var label: String
    var kind: String
    var placeholder: String
}

struct SourceManifest: Hashable {
    var id: String
    var name: String
    var description: String
    var version: String
    var syncIntervalHours: Double
    var settings: [SourceSetting]
    var canSearch: Bool
    var canSync: Bool
    /// Optional JS hook for resolving a landing page to a real file URL.
    var canPrepareDownload: Bool = false
    /// Servers the source always needs (declared as `allowedHosts`), shown to the person.
    var fixedHosts: [String] = []
    /// ISO 639-1 codes supplied by the source. Empty or ["*"] means any language.
    var languages: [String] = []
    /// "source" finds books to download; "metadata" answers Edit Details with book records.
    var kind: String = "source"

    var isMetadata: Bool { kind == "metadata" }

    func supportsLanguage(_ requested: String?) -> Bool {
        guard let code = BookLanguage.code(requested), !languages.isEmpty,
              !languages.contains("*") else { return true }
        return languages.contains(code)
    }

    var languageLabel: String {
        let codes = languages.filter { $0 != "*" }
        return codes.isEmpty ? "All languages" : codes.map(BookLanguage.displayName).joined(separator: ", ")
    }

    /// The languages to show beside the source's name, or nil when it takes any language.
    var restrictedLanguageLabel: String? {
        languages.contains(where: { $0 != "*" }) && !languages.contains("*") ? languageLabel : nil
    }

    /// The source's name, followed by its languages when it is limited to some.
    var nameWithLanguages: String {
        restrictedLanguageLabel.map { "\(name) · \($0)" } ?? name
    }
}

struct ExtensionError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Structured progress supplied by an extension. Status is the short line for
/// the queue; logs retain diagnostic context with the downloading job.
enum SourceEvent: Sendable {
    case status(String)
    case log(String)
    /// Bytes of the file transfer so far; `expected` is -1 when the server
    /// did not say how big the file is.
    case transfer(received: Int64, expected: Int64)
}

/// The source engine's queue is the sole consumer of these payloads. The
/// sender never mutates them after enqueueing, but JavaScriptCore arguments
/// and user-config JSON bridge through `[String: Any]`, which Swift cannot
/// infer as Sendable even when these values are immutable snapshots.
private struct SourceQueuePayload<Value>: @unchecked Sendable {
    let value: Value
}

// MARK: - The isolated runtime

/// One extension: its own JavaScript virtual machine (separate heap, no shared globals), its own
/// serial queue, no file access, and network access only to the hosts in its own settings.
final class SourceRuntime: @unchecked Sendable {
    let script: String
    private let queue: DispatchQueue
    private var context: JSContext?
    private var lastException: String?
    private var logs: [String] = []
    private var activeReporter: ((SourceEvent) -> Void)?
    /// Used only on this runtime's serial queue; closed job runtimes never
    /// silently start another JS engine or hidden browser after cancellation.
    private var closed = false
    private let lock = NSLock()
    /// Set (under `lock`) as soon as close() starts. A search Folio stopped
    /// waiting for can still be running JavaScript; its next request must fail
    /// at once instead of touching a URLSession that is being invalidated.
    private var stopping = false
    /// "<source id>" or "<source id>.job.<token>"; names this source's notes.
    private let label: String
    private var configHosts: Set<String> = []
    private var fixedHosts: Set<String> = []
    private var config: [String: Any] = [:]
    private var guard_: RedirectGuard!
    /// Set by Folio for its own bundled Hardcover source only: runs a GraphQL query with the
    /// reader's account (the token never reaches JavaScript) and returns the data as JSON text.
    var hardcoverBridge: ((String, String) -> String?)?
    /// WebKit itself is created on demand. Synchronize construction of its
    /// lightweight bridge because a cancelled job can close it while a JS
    /// worker is opening its first page.
    private let browserLock = NSLock()
    private var cachedBrowser: ExtensionBrowser?
    private var browser: ExtensionBrowser {
        browserLock.lock(); defer { browserLock.unlock() }
        if let cachedBrowser { return cachedBrowser }
        let instance = ExtensionBrowser(permitted: { [weak self] in self?.allowedHosts ?? [] })
        cachedBrowser = instance
        return instance
    }
    /// Every request this extension causes (its own fetches and its downloads) goes through this
    /// session, which refuses redirects to servers outside the allow-list.
    private(set) var session: URLSession!

    init(script: String, label: String) {
        self.script = script
        self.label = label
        queue = DispatchQueue(label: "folio.extension.\(label)", qos: .userInitiated)
        guard_ = RedirectGuard { [weak self] url in self?.isAllowed(url) ?? false }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        // Let iOS follow a Wi-Fi/cellular/VPN transition instead of failing a
        // just-created task immediately with a TCP/DNS connectivity error.
        // URLSession still performs connect-by-name (including IPv4/IPv6
        // Happy Eyeballs) and the request/resource deadlines remain bounded.
        cfg.waitsForConnectivity = true
        cfg.allowsCellularAccess = true
        cfg.allowsExpensiveNetworkAccess = true
        cfg.allowsConstrainedNetworkAccess = true
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 45
        cfg.httpAdditionalHeaders = ["User-Agent": "Folio / demeter-compatible"]
        session = URLSession(configuration: cfg, delegate: guard_, delegateQueue: nil)
    }

    private var allowedHosts: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return configHosts.union(fixedHosts)
    }

    static func keys(_ list: [String]) -> Set<String> {
        Set(list.compactMap { URL(string: $0.trimmingCharacters(in: .whitespaces)).flatMap(hostKey) })
    }

    static func hostKey(_ url: URL) -> String? {
        guard let s = url.scheme?.lowercased(), s == "http" || s == "https", let h = url.host?.lowercased() else { return nil }
        return "\(s)://\(h):\(url.port ?? (s == "https" ? 443 : 80))"
    }

    /// The extension may only reach http(s) servers the person listed in its settings.
    static func allowed(from config: [String: Any]) -> Set<String> {
        var out = Set<String>()
        for (_, v) in config {
            let items = (v as? [String]) ?? [(v as? String) ?? ""]
            for item in items {
                if let u = URL(string: item.trimmingCharacters(in: .whitespaces)), let k = hostKey(u) { out.insert(k) }
            }
        }
        return out
    }

    func isAllowed(_ url: URL) -> Bool {
        Self.hostKey(url).map { allowedHosts.contains($0) } ?? false
    }

    func browserDownloadHeaders(for url: URL) async -> [String: String] {
        guard isAllowed(url) else { return [:] }
        return await browser.requestHeaders(for: url)
    }

    func configure(_ config: [String: Any]) {
        lock.lock(); configHosts = Self.allowed(from: config); lock.unlock()
        let snapshot = SourceQueuePayload(value: config)
        queue.async {
            self.config = snapshot.value
            self.context?.objectForKeyedSubscript("folio")?.setObject(snapshot.value, forKeyedSubscript: "config" as NSString)
        }
    }

    private func browserCall(_ command: ExtensionBrowser.Command, _ value: String = "") -> String? {
        do { return try browser.perform(command, argument: value) }
        catch {
            JSContext.current()?.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: JSContext.current())
            return nil
        }
    }

    private func setUp() throws {
        guard context == nil else { return }
        guard let ctx = JSContext(virtualMachine: JSVirtualMachine()) else { throw ExtensionError(message: "Couldn't start the extension engine.") }
        ctx.name = "Folio extension"
        ctx.exceptionHandler = { [weak self] _, exc in
            self?.lastException = exc?.toString() ?? "unknown error"
        }
        let folio = JSValue(newObjectIn: ctx)!
        let log: @convention(block) (String) -> Void = { [weak self] msg in
            self?.logs.append(msg)
            if (self?.logs.count ?? 0) > 200 { self?.logs.removeFirst() }
            self?.activeReporter?(.log(msg))
        }
        let status: @convention(block) (String) -> Void = { [weak self] message in
            let cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                self?.activeReporter?(.status(String(cleaned.prefix(180))))
            }
        }
        let fetchText: @convention(block) (String) -> String? = { [weak self] urlString in
            guard let self else { return nil }
            do { return try self.blockingFetch(urlString) } catch {
                JSContext.current()?.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: JSContext.current())
                return nil
            }
        }
        // A privileged browser is deliberately exposed through a tiny, synchronous
        // bridge. WebKit itself runs asynchronously on the main actor; extension
        // JavaScript continues to run only on its isolated background queue.
        let browserOpen: @convention(block) (String) -> String? = { [weak self] address in
            self?.browserCall(.open, address)
        }
        let browserHTML: @convention(block) () -> String? = { [weak self] in
            self?.browserCall(.html)
        }
        let browserEvaluate: @convention(block) (String) -> String? = { [weak self] script in
            self?.browserCall(.evaluate, script)
        }
        let browserURL: @convention(block) () -> String? = { [weak self] in
            self?.browserCall(.url)
        }
        let browserWaitFor: @convention(block) (String) -> String? = { [weak self] selector in
            self?.browserCall(.waitFor, selector)
        }
        let browserClose: @convention(block) () -> String? = { [weak self] in
            self?.browserCall(.close)
        }
        let browserAPI = JSValue(newObjectIn: ctx)!
        browserAPI.setObject(browserOpen, forKeyedSubscript: "open" as NSString)
        browserAPI.setObject(browserHTML, forKeyedSubscript: "html" as NSString)
        browserAPI.setObject(browserEvaluate, forKeyedSubscript: "evaluate" as NSString)
        browserAPI.setObject(browserURL, forKeyedSubscript: "url" as NSString)
        browserAPI.setObject(browserWaitFor, forKeyedSubscript: "waitFor" as NSString)
        browserAPI.setObject(browserClose, forKeyedSubscript: "close" as NSString)
        folio.setObject(log, forKeyedSubscript: "log" as NSString)
        folio.setObject(status, forKeyedSubscript: "status" as NSString)
        folio.setObject(fetchText, forKeyedSubscript: "fetchText" as NSString)
        // Like fetchText, with request headers: folio.fetchWith(url, JSON.stringify({headers: {...}})).
        let fetchWith: @convention(block) (String, String) -> String? = { [weak self] urlString, optionsJSON in
            guard let self else { return nil }
            let options = (try? JSONSerialization.jsonObject(with: Data(optionsJSON.utf8))) as? [String: Any]
            let headers = (options?["headers"] as? [String: String]) ?? [:]
            let timeout = (options?["timeout"] as? NSNumber)?.doubleValue
            do { return try self.blockingFetch(urlString, headers: headers, timeout: timeout) } catch {
                JSContext.current()?.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: JSContext.current())
                return nil
            }
        }
        folio.setObject(fetchWith, forKeyedSubscript: "fetchWith" as NSString)
        // folio.fetchFirst(JSON.stringify([url, …]), JSON.stringify({timeout: 12}))
        // asks every address at once and returns JSON {url, text} for the first
        // that answers. Used to race a source's equivalent mirrors instead of
        // waiting out each one's timeout in turn. If all fail, it throws one
        // error listing "host: reason" for each, separated by " | ".
        let fetchFirst: @convention(block) (String, String) -> String? = { [weak self] urlsJSON, optionsJSON in
            guard let self else { return nil }
            let urls = ((try? JSONSerialization.jsonObject(with: Data(urlsJSON.utf8))) as? [String]) ?? []
            let options = (try? JSONSerialization.jsonObject(with: Data(optionsJSON.utf8))) as? [String: Any]
            let headers = (options?["headers"] as? [String: String]) ?? [:]
            let timeout = (options?["timeout"] as? NSNumber)?.doubleValue
            do {
                let (url, text) = try self.blockingFetchFirst(urls, headers: headers, timeout: timeout)
                let data = try JSONSerialization.data(withJSONObject: ["url": url, "text": text])
                return String(data: data, encoding: .utf8)
            } catch {
                JSContext.current()?.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: JSContext.current())
                return nil
            }
        }
        folio.setObject(fetchFirst, forKeyedSubscript: "fetchFirst" as NSString)
        // folio.remember(key, text, seconds) / folio.recall(key): small notes a
        // source keeps across download jobs until the app quits (each job has
        // a fresh runtime). Used for "these mirrors did not answer a minute
        // ago" so a retry doesn't wait out the same timeouts again.
        let space = label.components(separatedBy: ".job.").first ?? label
        let remember: @convention(block) (String, String, Double) -> Void = { key, value, seconds in
            SourceMemo.shared.set(space + "|" + key, value, seconds: seconds)
        }
        let recall: @convention(block) (String) -> String? = { key in
            SourceMemo.shared.get(space + "|" + key)
        }
        folio.setObject(remember, forKeyedSubscript: "remember" as NSString)
        folio.setObject(recall, forKeyedSubscript: "recall" as NSString)
        // folio.decodeHTML("Mu&ntilde;oz") -> "Muñoz": every HTML character
        // reference, so scrapers needn't keep their own partial tables.
        let decodeHTML: @convention(block) (String) -> String = { $0.decodingHTMLEntities }
        folio.setObject(decodeHTML, forKeyedSubscript: "decodeHTML" as NSString)
        if hardcoverBridge != nil {
            let hardcover: @convention(block) (String, String) -> String? = { [weak self] query, variables in
                self?.hardcoverBridge?(query, variables)
            }
            folio.setObject(hardcover, forKeyedSubscript: "hardcover" as NSString)
        }
        folio.setObject(browserAPI, forKeyedSubscript: "browser" as NSString)
        folio.setObject(config, forKeyedSubscript: "config" as NSString)
        ctx.setObject(folio, forKeyedSubscript: "folio" as NSString)
        ctx.evaluateScript("folio.fetchJSON = function (u) { var t = folio.fetchText(u); return JSON.parse(t); };")
        lastException = nil
        ctx.evaluateScript(script)
        if let e = lastException { throw ExtensionError(message: "The extension has an error: \(e)") }
        guard let src = ctx.objectForKeyedSubscript("source"), src.isObject else {
            throw ExtensionError(message: "The extension doesn't define `var source = {…}`.")
        }
        let declared = (src.objectForKeyedSubscript("allowedHosts")?.toArray() as? [String]) ?? []
        lock.lock(); fixedHosts = Self.keys(declared); lock.unlock()
        context = ctx
    }

    private func makeRequest(_ urlString: String, headers: [String: String], timeout: TimeInterval) throws -> (URL, URLRequest) {
        guard let url = URL(string: urlString) else { throw ExtensionError(message: "Bad address: \(urlString)") }
        guard let key = Self.hostKey(url), allowedHosts.contains(key) else {
            throw ExtensionError(message: "Blocked: this extension may only reach the servers in its settings (\(url.host ?? urlString)).")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue("Folio / demeter-compatible", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { req.setValue(value, forHTTPHeaderField: name) }
        return (url, req)
    }

    /// Turns one finished request into page text or a short, readable error.
    private static func pageResult(_ url: URL, _ data: Data?, _ resp: URLResponse?, _ err: Error?) -> Result<String, Error> {
        if let err { return .failure(err) }
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            return .failure(ExtensionError(message: "\(url.host ?? "server") answered \(http.statusCode)"))
        }
        guard let data, data.count <= 20_000_000 else { return .failure(ExtensionError(message: "Answer too large")) }
        // Honor the page's declared character set; Spanish and other
        // Latin pages are not always UTF-8.
        let contentType = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
        return .success(FolioWebText.string(from: data, contentType: contentType))
    }

    private var isStopping: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopping
    }

    /// Runs on the extension's own queue, so this blocking request never touches the app's main thread.
    /// `timeout` (seconds) bounds the whole request, so a source can probe a
    /// slow mirror briefly; without it a page gets the usual 30 seconds.
    private func blockingFetch(_ urlString: String, headers: [String: String] = [:],
                               timeout: TimeInterval? = nil) throws -> String {
        guard !isStopping else { throw ExtensionError(message: "Search stopped") }
        let limit = min(max(timeout ?? 30, 3), 30)
        let (url, req) = try makeRequest(urlString, headers: headers, timeout: limit)
        let sem = DispatchSemaphore(value: 0)
        let box = FetchBox()
        let task = session.dataTask(with: req) { data, resp, err in
            box.set(Self.pageResult(url, data, resp, err))
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + limit + 2) == .timedOut {
            task.cancel()
            throw ExtensionError(message: "Timed out")
        }
        return try (box.get() ?? .failure(ExtensionError(message: "Timed out"))).get()
    }

    /// Asks every address at once; the first readable page wins and the rest
    /// are cancelled. Fails only when every address failed or none answered
    /// within `timeout` seconds.
    private func blockingFetchFirst(_ urls: [String], headers: [String: String],
                                    timeout: TimeInterval?) throws -> (String, String) {
        guard !isStopping else { throw ExtensionError(message: "Search stopped") }
        guard !urls.isEmpty else { throw ExtensionError(message: "No addresses") }
        let limit = min(max(timeout ?? 15, 3), 30)
        let sem = DispatchSemaphore(value: 0)
        let race = FetchRace(count: urls.count)
        var tasks: [URLSessionDataTask] = []
        for (index, address) in urls.enumerated() {
            do {
                let (url, req) = try makeRequest(address, headers: headers, timeout: limit)
                let task = session.dataTask(with: req) { data, resp, err in
                    if race.finish(index, Self.pageResult(url, data, resp, err)) { sem.signal() }
                }
                tasks.append(task)
            } catch {
                if race.finish(index, .failure(error)) { sem.signal() }
            }
        }
        tasks.forEach { $0.resume() }
        let timedOut = sem.wait(timeout: .now() + limit + 2) == .timedOut
        tasks.forEach { $0.cancel() }
        if let won = race.winner { return (urls[won.0], won.1) }
        let reasons = urls.enumerated().map { index, address in
            let host = URL(string: address)?.host ?? address
            let reason = race.error(index).map { $0.localizedDescription } ?? (timedOut ? "Timed out" : "No answer")
            return "\(host): \(reason)"
        }
        throw ExtensionError(message: reasons.joined(separator: " | "))
    }

    func manifest() async throws -> SourceManifest {
        try await run { ctx in
            let s = ctx.objectForKeyedSubscript("source")!
            let settings = (s.objectForKeyedSubscript("settings")?.toArray() as? [[String: Any]] ?? []).compactMap { d -> SourceSetting? in
                guard let k = d["key"] as? String else { return nil }
                return SourceSetting(key: k, label: d["label"] as? String ?? k, kind: d["kind"] as? String ?? "text", placeholder: d["placeholder"] as? String ?? "")
            }
            func str(_ k: String) -> String? { let v = s.objectForKeyedSubscript(k); return (v?.isString ?? false) ? v?.toString() : nil }
            func isFn(_ k: String) -> Bool { s.objectForKeyedSubscript(k).map { $0.isObject && !$0.isUndefined } ?? false }
            let fixed = (s.objectForKeyedSubscript("allowedHosts")?.toArray() as? [String]) ?? []
            let languages = ((s.objectForKeyedSubscript("languages")?.toArray() as? [String]) ?? [])
                .compactMap { $0 == "*" ? "*" : BookLanguage.code($0) }
            guard let id = str("id"), let name = str("name") else { throw ExtensionError(message: "The extension needs an id and a name.") }
            return SourceManifest(
                id: id, name: name, description: str("description") ?? "", version: str("version") ?? "1",
                syncIntervalHours: s.objectForKeyedSubscript("syncIntervalHours")?.toNumber()?.doubleValue ?? 12,
                settings: settings, canSearch: isFn("search"), canSync: isFn("sync"),
                canPrepareDownload: isFn("prepareDownload"), fixedHosts: fixed,
                languages: Array(Set(languages)).sorted(),
                kind: str("kind") ?? "source"
            )
        }
    }

    /// Calls `source.<name>(args…)` in isolation and hands back plain values.
    func invoke(_ name: String, _ args: [Any], onEvent: @escaping (SourceEvent) -> Void = { _ in }) async throws -> Any? {
        try await run { ctx in
            let prior = self.activeReporter
            self.activeReporter = onEvent
            defer { self.activeReporter = prior }
            self.lastException = nil
            let argsJSON = String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8) ?? "[]"
            let r = ctx.evaluateScript("(function(){ var a = \(argsJSON); return source.\(name).apply(source, a); })()")
            if let e = self.lastException { throw ExtensionError(message: e) }
            return r?.toObject()
        }
    }

    var recentLogs: [String] { queue.sync { logs } }

    /// Finish a job's source runtime after all queued JavaScript calls. This
    /// first interrupts active network/JS WebKit waits (without needing the
    /// busy JS queue), then waits for its own queue to release its JSContext.
    /// This also removes the isolated iOS offscreen UIView from its window.
    func close() async {
        lock.lock(); stopping = true; lock.unlock()
        // URLSession retains its RedirectGuard delegate until it reports
        // invalidation. Wait for that handoff before this ephemeral runtime
        // can release its delegate/URLSession; otherwise Foundation callbacks
        // may race ARC release on the main actor after a job finishes.
        await guard_.invalidateAndWait(session)
        await browser.shutdown()
        await withCheckedContinuation { continuation in
            queue.async {
                guard !self.closed else { continuation.resume(); return }
                self.closed = true
                self.context = nil
                self.activeReporter = nil
                self.logs.removeAll(keepingCapacity: false)
                continuation.resume()
            }
        }
    }

    private func run<T>(_ body: @escaping (JSContext) throws -> T) async throws -> T {
        let scheduled = SourceQueuePayload(value: body)
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    guard !self.closed else {
                        throw ExtensionError(message: "This download job's source session has already closed.")
                    }
                    try self.setUp()
                    cont.resume(returning: try scheduled.value(self.context!))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }
}

/// Stops a request from being redirected to a server the extension isn't allowed to reach.
/// File downloads only: follow redirects to any HTTPS host, never to plain
/// HTTP, and never carry cookies or credentials to a different origin.
final class FileRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = FileRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme?.lowercased() == "https" else { return completionHandler(nil) }
        completionHandler(RedirectGuard.stripped(request, from: response.url))
    }
}

/// Streams one book file to disk and reports its progress.
///
/// The source runtime's session caps a whole request at 45 seconds, which
/// suits pages but cut slow partner file hosts off midway through an EPUB
/// ("The request timed out" about 45 s into every transfer). A file gets its
/// own in-app session instead: it fails only after 60 s with no data at all,
/// may take up to 30 minutes overall, and picks up where it stopped when the
/// connection drops ("The network connection was lost").
final class FileTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var finished: (URL, URLResponse)?
    private var moveError: Error?
    private var lastReport = Date.distantPast
    private var lastPercent = -1
    private let report: (Int64, Int64) -> Void
    /// Bytes per second below which a transfer is abandoned (0: never).
    private let minimumRate: Double
    private var firstByteAt: Date?
    private var tooSlow = false

    private init(report: @escaping (Int64, Int64) -> Void, minimumRate: Double) {
        self.report = report
        self.minimumRate = minimumRate
    }

    static let idleTimeout: TimeInterval = 60
    static let totalTimeout: TimeInterval = 30 * 60

    /// The host is sending, but so slowly that another copy will be faster.
    struct TooSlow: LocalizedError {
        let bytesPerSecond: Double
        var errorDescription: String? {
            "Too slow (\(Int(bytesPerSecond / 1024)) KB/s)"
        }
    }

    /// Downloads `request`, retrying after a dropped or stalled connection
    /// and resuming from the bytes already received when the server allows it.
    ///
    /// With `hasAlternative` (another copy or mirror is waiting), a bad host is
    /// given up on quickly: 20 s without data counts as a stall, one retry
    /// only, and a transfer averaging under 16 KB/s after 20 s with minutes
    /// still to go is dropped so the next link can start. The last link keeps
    /// the patient settings: 60 s idle, two retries, no speed floor.
    static func download(_ request: URLRequest, hasAlternative: Bool = false,
                         progress: @escaping (Int64, Int64) -> Void,
                         onRetry: @escaping (String) -> Void = { _ in }) async throws -> (URL, URLResponse) {
        var resumeData: Data?
        var attempt = 0
        let retries = hasAlternative ? 1 : 2
        let idle: TimeInterval = hasAlternative ? 20 : idleTimeout
        while true {
            do {
                return try await FileTransfer(report: progress, minimumRate: hasAlternative ? 16 * 1024 : 0)
                    .run(request, resumeData: resumeData, idle: idle)
            } catch let error as URLError where attempt < retries && retryable(error.code) {
                attempt += 1
                resumeData = error.downloadTaskResumeData
                onRetry("\(error.localizedDescription) Retrying (\(attempt) of \(retries))" +
                        (resumeData == nil ? " from the start." : " from where it stopped."))
                try await Task.sleep(for: .seconds(2 * attempt))
            }
        }
    }

    private static func retryable(_ code: URLError.Code) -> Bool {
        [.networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost,
         .dnsLookupFailed, .cannotFindHost, .secureConnectionFailed].contains(code)
    }

    private func run(_ request: URLRequest, resumeData: Data?, idle: TimeInterval) async throws -> (URL, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = idle
        configuration.timeoutIntervalForResource = Self.totalTimeout
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = request
        request.timeoutInterval = idle
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // File links often redirect to a CDN or mirror: follow any HTTPS one.
        guard let url = request.url, url.scheme?.lowercased() == "https" else { return completionHandler(nil) }
        completionHandler(RedirectGuard.stripped(request, from: response.url))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : -1
        let percent = expected > 0 ? Int(totalBytesWritten * 100 / expected) : -1
        let now = Date()
        lock.lock()
        // At most a few updates a second, and only when the number shown changes.
        let due = now.timeIntervalSince(lastReport) >= 0.25 && (percent != lastPercent || expected < 0)
        if due { lastReport = now; lastPercent = percent }
        if firstByteAt == nil { firstByteAt = now }
        var giveUp = false
        if minimumRate > 0, !tooSlow, let start = firstByteAt {
            let elapsed = now.timeIntervalSince(start)
            let rate = Double(totalBytesWritten) / max(elapsed, 0.001)
            let remaining = expected > 0 ? Double(expected - totalBytesWritten) / max(rate, 1) : .infinity
            if elapsed >= 20, rate < minimumRate, remaining > 120 {
                tooSlow = true
                giveUp = true
            }
        }
        lock.unlock()
        if due { report(totalBytesWritten, expected) }
        if giveUp { downloadTask.cancel() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this returns: keep the file first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("folio-transfer-\(UUID().uuidString)")
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            if let response = downloadTask.response { finished = (kept, response) }
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let result = finished, moveError = moveError, slow = tooSlow
        let written = task.countOfBytesReceived
        let elapsed = firstByteAt.map { Date().timeIntervalSince($0) } ?? 1
        lock.unlock()
        guard let continuation else { return }
        if slow { return continuation.resume(throwing: TooSlow(bytesPerSecond: Double(written) / max(elapsed, 1))) }
        if let error { return continuation.resume(throwing: error) }
        if let moveError { return continuation.resume(throwing: moveError) }
        if let result { return continuation.resume(returning: result) }
        continuation.resume(throwing: URLError(.badServerResponse))
    }
}

final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let allow: (URL) -> Bool
    private let invalidationLock = NSLock()
    private var invalidationWaiter: CheckedContinuation<Void, Never>?
    private var invalidated = false
    init(_ allow: @escaping (URL) -> Bool) { self.allow = allow }

    /// A bounded wait for URLSession's own delegate-release notification.
    /// Cancels outstanding requests immediately, rather than waiting for their
    /// original 120-second network timeout. The timeout also covers a broken
    /// URLSession implementation that never delivers its invalidation event.
    func invalidateAndWait(_ session: URLSession) async {
        await withCheckedContinuation { continuation in
            invalidationLock.lock()
            if invalidated {
                invalidationLock.unlock()
                continuation.resume()
                return
            }
            invalidationWaiter = continuation
            invalidationLock.unlock()
            session.invalidateAndCancel()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.completeInvalidation()
            }
        }
    }

    private func completeInvalidation() {
        invalidationLock.lock()
        invalidated = true
        let waiter = invalidationWaiter
        invalidationWaiter = nil
        invalidationLock.unlock()
        waiter?.resume()
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        completeInvalidation()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, allow(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(Self.stripped(request, from: response.url))
    }

    /// A source may explicitly allow more than one HTTPS origin for its
    /// catalogue and partner pages. Never transfer browser-state or
    /// referring-page data across separate origins.
    static func stripped(_ request: URLRequest, from previous: URL?) -> URLRequest {
        var next = request
        if let previous, let url = request.url, SourceRuntime.hostKey(previous) != SourceRuntime.hostKey(url) {
            for header in ["Cookie", "Authorization", "Proxy-Authorization", "Referer", "Origin"] {
                next.setValue(nil, forHTTPHeaderField: header)
            }
        }
        return next
    }
}

// MARK: - Installed extensions

@Observable
@MainActor
final class ExtensionStore {
    static let shared = ExtensionStore()

    private struct UpdateManifest: Decodable {
        var extensions: [UpdateEntry]
    }

    private struct UpdateEntry: Decodable {
        var id: String
        var version: String
        var url: URL
        var sha256: String
    }

    struct Saved: Codable {
        var file: String
        var enabled = true
        var builtIn = false
        var config: [String: [String]] = [:]
        var syncState: String?
        var lastSync: Date?
        var seenNew: Int?
    }

    struct Installed: Identifiable {
        var id: String { manifest.id }
        var manifest: SourceManifest
        var runtime: SourceRuntime
        var saved: Saved
    }

    var installed: [Installed] = []
    var lastError: String?

    private var dir: URL { LibraryStore.shared.baseDir.appendingPathComponent("Extensions", isDirectory: true) }
    private var savedURL: URL { dir.appendingPathComponent("extensions.json") }
    private var savedByID: [String: Saved] = [:]
    private static let updateManifestURL = URL(string:
        "https://raw.githubusercontent.com/Alehaaaa/Folio/main/extensions/versions.json")!
    private static let updateCheckKey = "folio.extensions.lastUpdateCheck"
    private static let updateCheckInterval: TimeInterval = 6 * 60 * 60

    /// Enabled download sources (metadata sources never take part in finding
    /// copies), in the reader's preferred order.
    var enabled: [Installed] {
        installed.filter { $0.saved.enabled && !$0.manifest.isMetadata }.sorted(by: inSourceOrder)
    }

    /// Every download source, enabled or not, in the reader's preferred order.
    var downloadSources: [Installed] {
        installed.filter { !$0.manifest.isMetadata }.sorted(by: inSourceOrder)
    }

    static let sourceOrderKey = "folio.sources.order"

    /// Observed, so every list of sources redraws as soon as the order changes.
    private(set) var sourceOrder: [String] = UserDefaults.standard.stringArray(forKey: ExtensionStore.sourceOrderKey) ?? []

    private func inSourceOrder(_ a: Installed, _ b: Installed) -> Bool {
        (sourceOrder.firstIndex(of: a.id) ?? Int.max, a.manifest.name) < (sourceOrder.firstIndex(of: b.id) ?? Int.max, b.manifest.name)
    }

    func setSourceOrder(_ ids: [String]) {
        sourceOrder = ids
        UserDefaults.standard.set(ids, forKey: Self.sourceOrderKey)
    }

    /// Which source to prefer when two offer equally good copies: a source
    /// made for the requested language first ("Spanish books" for Spanish),
    /// then the reader's order. Lower is preferred.
    func priority(_ id: String, for language: String?) -> Int {
        let order = downloadSources.map(\.id)
        let base = order.firstIndex(of: id) ?? order.count
        guard let source = ext(id), let code = BookLanguage.code(language),
              source.manifest.restrictedLanguageLabel != nil,
              source.manifest.supportsLanguage(code) else { return base }
        return base - 1_000
    }

    /// Every metadata source, in the reader's priority order.
    var metadataSources: [Installed] {
        let order = UserDefaults.standard.stringArray(forKey: Self.metadataOrderKey) ?? []
        return installed.filter(\.manifest.isMetadata).sorted {
            (order.firstIndex(of: $0.id) ?? Int.max, $0.manifest.name) < (order.firstIndex(of: $1.id) ?? Int.max, $1.manifest.name)
        }
    }

    static let metadataOrderKey = "folio.metadataSources.extensionOrder"

    func setMetadataOrder(_ ids: [String]) {
        UserDefaults.standard.set(ids, forKey: Self.metadataOrderKey)
    }

    /// Runs one metadata source for a book and returns its raw records.
    func metadata(_ e: Installed, for input: [String: Any]) async throws -> [[String: Any]] {
        let r = try await e.runtime.invoke("metadata", [input])
        return (r as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }

    func ext(_ id: String) -> Installed? { installed.first { $0.id == id } }

    private init() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let d = try? Data(contentsOf: savedURL), let s = try? JSONDecoder().decode([String: Saved].self, from: d) { savedByID = s }
        // Built-in sources are always refreshed from the app itself.
        for (id, script) in DefaultSources.builtIn {
            try? script.write(to: dir.appendingPathComponent("\(id).js"), atomically: true, encoding: .utf8)
            if savedByID[id] == nil { savedByID[id] = Saved(file: "\(id).js", builtIn: true) }
            savedByID[id]?.builtIn = true
        }
        // Extensions bundled with the app: every extensions/*.js on iOS, the
        // metadata extensions on the Mac (see build-macos.command). They are
        // refreshed with each app build; the user's per-extension configuration
        // and enabled state are retained.
        let idPattern = try? NSRegularExpression(pattern: #"\bid\s*:\s*["']([A-Za-z0-9_-]+)["']"#)
        for url in (Bundle.main.urls(forResourcesWithExtension: "js", subdirectory: nil) ?? []).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let script = try? String(contentsOf: url, encoding: .utf8),
                  let match = idPattern?.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
                  let range = Range(match.range(at: 1), in: script) else { continue }
            let id = String(script[range])
            guard !DefaultSources.builtIn.contains(where: { $0.id == id }) else { continue }
            let file = id + ".js"
            let destination = dir.appendingPathComponent(file)
            let installedScript = try? String(contentsOf: destination, encoding: .utf8)
            let installedVersion = installedScript.flatMap(Self.declaredVersion)
            let bundledVersion = Self.declaredVersion(in: script)
            // Never downgrade a remotely updated managed extension to the
            // older copy embedded in an app build on the next launch.
            if installedScript == nil || installedVersion == nil || bundledVersion == nil ||
                Self.version(bundledVersion!, isNewerThan: installedVersion!) {
                try? script.write(to: destination, atomically: true, encoding: .utf8)
            }
            if savedByID[id] == nil { savedByID[id] = Saved(file: file, enabled: id != "libgen", builtIn: true) }
            savedByID[id]?.file = file
            savedByID[id]?.builtIn = true
        }
        Task { await loadAll() }
    }

    private func persist() {
        for i in installed { savedByID[i.id] = i.saved }
        if let d = try? JSONEncoder().encode(savedByID) { try? d.write(to: savedURL, options: .atomic) }
    }

    /// True once the extensions have been read at least once.
    private(set) var loaded = false
    @ObservationIgnored private var loading: Task<Void, Never>?

    /// Reads every extension and replaces the runtimes. Calls made while a
    /// load is running wait for that load instead of starting another one, so
    /// screens and the download queue never swap runtimes out from under each other.
    func loadAll() async {
        if let loading { return await loading.value }
        let task = Task { await self.buildRuntimes() }
        loading = task
        await task.value
        loading = nil
    }

    /// Loads the extensions only if nothing has loaded them yet.
    func ensureLoaded() async {
        if !loaded { await loadAll() }
    }

    private func buildRuntimes() async {
        var out: [Installed] = []
        for (id, saved) in savedByID.sorted(by: { ($0.value.builtIn ? 0 : 1, $0.key) < ($1.value.builtIn ? 0 : 1, $1.key) }) {
            guard let script = try? String(contentsOf: dir.appendingPathComponent(saved.file), encoding: .utf8) else { continue }
            let rt = SourceRuntime(script: script, label: id)
            if id == "metadata-hardcover", saved.builtIn { rt.hardcoverBridge = Self.hardcoverQuery }
            rt.configure(saved.config)
            do {
                let m = try await rt.manifest()
                out.append(Installed(manifest: m, runtime: rt, saved: saved))
            } catch {
                lastError = "\(saved.file): \(error.localizedDescription)"
            }
        }
        let previous = installed
        installed = out
        loaded = true
        // Old runtimes each hold a JavaScript context and a hidden WebKit
        // page; release them instead of leaking one set per reload.
        for item in previous { Task { await item.runtime.close() } }
    }

    /// At launch, refresh Folio-managed JavaScript extensions at most once per
    /// interval. The remote manifest is only an index: every downloaded script
    /// must match its SHA-256 and declare the advertised id/version before it
    /// can replace the local atomic file. User-installed extensions are never
    /// overwritten.
    func checkForExtensionUpdates(force: Bool = false) async {
        let defaults = UserDefaults.standard
        if !force, let last = defaults.object(forKey: Self.updateCheckKey) as? Date,
           Date().timeIntervalSince(last) < Self.updateCheckInterval { return }

        var request = URLRequest(url: Self.updateManifestURL,
                                 cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                 timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let manifest: UpdateManifest
        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }
            manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
            defaults.set(Date(), forKey: Self.updateCheckKey)
        } catch {
            // Launch must remain quiet and fully usable while offline. A failed
            // check is not timestamped, so a later launch can try again.
            return
        }

        var changed = false
        for entry in manifest.extensions {
            let safeID = entry.id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            guard safeID == entry.id, entry.url.scheme == "https",
                  entry.url.host == "raw.githubusercontent.com",
                  entry.sha256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else { continue }

            if let saved = savedByID[entry.id], !saved.builtIn { continue }
            if let local = ext(entry.id), !Self.version(entry.version, isNewerThan: local.manifest.version) { continue }

            do {
                var scriptRequest = URLRequest(url: entry.url,
                                               cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                               timeoutInterval: 30)
                scriptRequest.setValue("text/javascript", forHTTPHeaderField: "Accept")
                let configuration = URLSessionConfiguration.ephemeral
                configuration.waitsForConnectivity = true
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = 45
                let session = URLSession(configuration: configuration)
                defer { session.finishTasksAndInvalidate() }
                let (data, response) = try await session.data(for: scriptRequest)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      data.count <= 2_000_000 else { continue }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard digest == entry.sha256,
                      let script = String(data: data, encoding: .utf8) else { continue }

                let validator = SourceRuntime(script: script, label: "update.\(entry.id)")
                let candidate: SourceManifest
                do { candidate = try await validator.manifest() }
                catch { await validator.close(); continue }
                await validator.close()
                guard candidate.id == entry.id, candidate.version == entry.version else { continue }

                let file = entry.id + ".js"
                try data.write(to: dir.appendingPathComponent(file), options: .atomic)
                var saved = savedByID[entry.id] ?? Saved(file: file, enabled: entry.id != "libgen", builtIn: true)
                saved.file = file
                saved.builtIn = true
                savedByID[entry.id] = saved
                changed = true
            } catch {
                continue
            }
        }

        guard changed else { return }
        persist()
        await loadAll()
    }

    private static func version(_ candidate: String, isNewerThan current: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            value.split(separator: ".").map { Int($0) ?? 0 }
        }
        let left = parts(candidate), right = parts(current)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func declaredVersion(in script: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: #"\bversion\s*:\s*["']([^"']+)["']"#),
              let match = expression.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
              let range = Range(match.range(at: 1), in: script) else { return nil }
        return String(script[range])
    }

    /// Installs a JavaScript source extension the person picked.
    func install(from url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let script = try String(contentsOf: url, encoding: .utf8)
            let rt = SourceRuntime(script: script, label: "install")
            let m = try await rt.manifest()
            if DefaultSources.builtIn.contains(where: { $0.id == m.id }) { throw ExtensionError(message: "That id belongs to a built-in source.") }
            let file = m.id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } + ".js"
            try script.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
            var saved = savedByID[m.id] ?? Saved(file: file)
            saved.file = file
            savedByID[m.id] = saved
            persist()
            await loadAll()
            lastError = nil
        } catch {
            lastError = "Couldn't install \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Runs a Hardcover query for the bundled Hardcover metadata source, from its JavaScript
    /// queue (never the main thread), through the app's rate-limited client.
    nonisolated static func hardcoverQuery(_ query: String, _ variablesJSON: String) -> String? {
        final class Box: @unchecked Sendable { var text: String? }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        let variables = SourceQueuePayload(value: (try? JSONSerialization.jsonObject(with: Data(variablesJSON.utf8))) as? [String: Any] ?? [:])
        Task { @MainActor in
            defer { sem.signal() }
            guard HardcoverClient.shared.isConnected,
                  let data = try? await HardcoverClient.shared.query(query, variables.value),
                  let json = try? JSONSerialization.data(withJSONObject: data.anyValue, options: [.fragmentsAllowed]) else { return }
            box.text = String(data: json, encoding: .utf8)
        }
        _ = sem.wait(timeout: .now() + 90)
        return box.text
    }

    func remove(_ id: String) {
        guard let i = ext(id), !i.saved.builtIn else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(i.saved.file))
        savedByID[id] = nil
        installed.removeAll { $0.id == id }
        persist()
    }

    func update(_ id: String, _ change: (inout Saved) -> Void) {
        guard let idx = installed.firstIndex(where: { $0.id == id }) else { return }
        change(&installed[idx].saved)
        installed[idx].runtime.configure(installed[idx].saved.config)
        persist()
    }

    // MARK: Calls

    func search(_ id: String, query: String, page: Int = 0,
                expectedLanguage: String? = nil,
                expectedTitle: String? = nil, expectedAuthor: String? = nil,
                using jobSession: JobSession? = nil,
                onEvent: @escaping (SourceEvent) -> Void = { _ in }) async throws -> [SourceResult] {
        guard let e = jobSession == nil ? ext(id) : jobSession?.source(id) else { return [] }
        guard e.manifest.supportsLanguage(expectedLanguage) else { return [] }
        let r = try await e.runtime.invoke(query.isEmpty ? "recent" : "search",
                                           query.isEmpty ? [page] : [query, page, expectedLanguage ?? "",
                                                                        expectedTitle ?? "", expectedAuthor ?? ""], onEvent: onEvent)
        return (r as? [Any] ?? []).compactMap(SourceResult.from)
    }

    /// Every server an extension may reach: its declared hosts plus the ones the person added.
    func reach(_ e: Installed) -> Set<String> {
        SourceRuntime.allowed(from: e.saved.config).union(SourceRuntime.keys(e.manifest.fixedHosts))
    }

    struct Copy: Identifiable {
        var id: String { sourceID + "|" + result.id }
        var sourceID: String
        var sourceName: String
        var result: SourceResult
        var exact: Bool
    }

    /// Source runtimes are isolated per provider/job, and their immutable
    /// search results can return in any order without sharing mutable JS state.
    private struct SourceSearchBatch: @unchecked Sendable {
        let index: Int
        let sourceID: String
        let sourceName: String
        let results: [SourceResult]
        let failure: String?
    }

    /// One download job's independent source environment. Every enabled extension
    /// has its own JavaScript heap, serial execution queue, URLSession and private
    /// WebKit browser *for this job only*. Retain this object across findCopies
    /// and download: a free-partner countdown, browser verification cookies,
    /// preferred mirror and failed-host state belong to the same job.
    ///
    /// The normal ExtensionStore search/download API still uses the shared
    /// runtimes for manual browsing and remains backward compatible.
    @MainActor
    final class JobSession {
        private let store: ExtensionStore
        fileprivate let sources: [Installed]
        private var closed = false

        fileprivate init(store: ExtensionStore, sources: [Installed]) {
            self.store = store
            self.sources = sources
        }

        fileprivate func source(_ id: String) -> Installed? {
            sources.first { $0.id == id }
        }

        func search(_ id: String, query: String, page: Int = 0,
                    expectedLanguage: String? = nil,
                    expectedTitle: String? = nil, expectedAuthor: String? = nil,
                    onEvent: @escaping (SourceEvent) -> Void = { _ in }) async throws -> [SourceResult] {
            guard !closed else { throw ExtensionError(message: "This download job's source session has already closed.") }
            return try await store.search(id, query: query, page: page, expectedLanguage: expectedLanguage,
                                          expectedTitle: expectedTitle, expectedAuthor: expectedAuthor,
                                          using: self, onEvent: onEvent)
        }

        func findCopies(title: String, author: String,
                        expectedLanguage: String? = nil,
                        progress: @escaping (String) -> Void = { _ in },
                        onEvent: @escaping (String, SourceEvent) -> Void = { _, _ in }) async
            -> (copies: [Copy], problems: [String]) {
            guard !closed else { return ([], ["This download job's source session has already closed."]) }
            return await store.findCopies(title: title, author: author, expectedLanguage: expectedLanguage,
                                          using: self, progress: progress, onEvent: onEvent)
        }

        @discardableResult
        func download(_ result: SourceResult, from id: String, into library: LibraryStore,
                      onEvent: @escaping (SourceEvent) -> Void = { _ in }) async throws -> UUID {
            guard !closed else { throw ExtensionError(message: "This download job's source session has already closed.") }
            return try await store.download(result, from: id, into: library, using: self, onEvent: onEvent)
        }

        /// Call once after the job finishes, fails, or is cancelled. Closes all
        /// per-source WebKit pages and their iOS offscreen UI hosts; no user
        /// library data or shared/manual source runtime is affected.
        func close() async {
            guard !closed else { return }
            closed = true
            await withTaskGroup(of: Void.self) { group in
                for source in sources {
                    let runtime = source.runtime
                    group.addTask { await runtime.close() }
                }
            }
        }
    }

    /// Snapshot currently enabled sources and their saved settings at job start.
    /// A new runtime is created once per source per job (not once per book copy),
    /// so jobs execute concurrently without sharing JavaScript or browser state.
    func makeJobSession() -> JobSession {
        let token = UUID().uuidString
        let sources = enabled.map { source -> Installed in
            let runtime = SourceRuntime(script: source.runtime.script,
                                        label: "\(source.id).job.\(token)")
            runtime.configure(source.saved.config)
            return Installed(manifest: source.manifest, runtime: runtime, saved: source.saved)
        }
        return JobSession(store: self, sources: sources)
    }

    /// Asks every enabled source for a readable copy of a book, best matches first.
    func findCopies(title: String, author: String,
                    expectedLanguage: String? = nil,
                    using jobSession: JobSession? = nil,
                    progress: @escaping (String) -> Void = { _ in },
                    onEvent: @escaping (String, SourceEvent) -> Void = { _, _ in }) async -> (copies: [Copy], problems: [String]) {
        var copies: [Copy] = []
        var problems: [String] = []
        let wanted = BookMatch.key(author: author, title: title)
        let wantedTitle = Self.simpleTitle(title)
        let lastName = Names.split(author).first?.split(separator: " ").last.map { String($0).lowercased() } ?? ""
        let sources = jobSession?.sources ?? enabled
        var eligible: [(Int, String, String)] = []
        for (index, e) in sources.enumerated() {
            guard e.manifest.supportsLanguage(expectedLanguage) else {
                onEvent(e.manifest.name, .log("Skipped: source languages \(e.manifest.languageLabel) do not include \(expectedLanguage ?? "unknown")."))
                continue
            }
            if e.manifest.settings.contains(where: { $0.kind == "list" }) && SourceRuntime.allowed(from: e.saved.config).isEmpty { continue }
            eligible.append((index, e.id, e.manifest.name))
        }

        // Each source has its own JS heap, URLSession and WebKit instance. A
        // stalled Gutenberg request must not delay starting Lectulandia's
        // search. Gather all outcomes before ranking to retain fallbacks if
        // the first edition's final file transfer fails.
        let shortTitle = title.components(separatedBy: ":").first ?? title
        let query = "\(shortTitle) \(lastName)".trimmingCharacters(in: .whitespaces)
        //
        // A job's automatic search stops waiting once one source has a
        // verified exact EPUB (same title, author and language): the others
        // get a short grace period, then Folio moves on and their remaining
        // events are muted. Manual searches (no job) still wait for everyone,
        // because the person is choosing from the full list.
        let muted = SearchMute()
        let (stream, feed) = AsyncStream<SourceSearchBatch?>.makeStream()
        for (index, id, name) in eligible {
            Task { [self] in
                progress(name)
                let report: (SourceEvent) -> Void = { event in
                    if !muted.isMuted(name) { onEvent(name, event) }
                }
                do {
                    let results = try await self.search(id, query: query,
                                                        expectedLanguage: expectedLanguage,
                                                        expectedTitle: title, expectedAuthor: author,
                                                        using: jobSession, onEvent: report)
                    feed.yield(SourceSearchBatch(index: index, sourceID: id, sourceName: name,
                                                 results: results, failure: nil))
                } catch {
                    feed.yield(SourceSearchBatch(index: index, sourceID: id, sourceName: name,
                                                 results: [], failure: Self.readableFailure(error.localizedDescription)))
                }
            }
        }
        var batches: [SourceSearchBatch] = []
        var graceTimer: Task<Void, Never>?
        if !eligible.isEmpty {
            for await item in stream {
                guard let batch = item else { break }  // grace period over
                batches.append(batch)
                if batches.count == eligible.count { break }
                if jobSession != nil, graceTimer == nil,
                   batch.results.contains(where: { Self.verifiedExact($0, title: title, author: author,
                                                                     language: expectedLanguage) }) {
                    onEvent(batch.sourceName, .log("Exact EPUB found; giving the other sources \(Int(Self.exactMatchGrace)) more seconds"))
                    graceTimer = Task {
                        try? await Task.sleep(for: .seconds(Self.exactMatchGrace))
                        feed.yield(nil)
                    }
                }
            }
        }
        graceTimer?.cancel()
        feed.finish()
        let finished = Set(batches.map(\.index))
        let pending = eligible.filter { !finished.contains($0.0) }.map { $0.2 }
        if !pending.isEmpty {
            pending.forEach(muted.mute)
            // The job's runtimes keep their own queues; closing the job
            // session afterwards cancels whatever they are still waiting on.
            onEvent(pending.joined(separator: ", "), .log("Not waiting any longer: an exact EPUB was already found"))
        }
        // Deterministic catalog ordering regardless of network completion
        // order; the existing edition ranking still decides which EPUB wins.
        for batch in batches.sorted(by: { $0.index < $1.index }) {
            if let failure = batch.failure {
                problems.append("\(batch.sourceName): \(failure)")
                onEvent(batch.sourceName, .log("Search failed: \(failure)"))
                continue
            }
            for r in batch.results where r.preferred != nil {
                let exact = BookMatch.key(author: r.author, title: r.title) == wanted
                let close = Self.simpleTitle(r.title).hasPrefix(wantedTitle) || wantedTitle.hasPrefix(Self.simpleTitle(r.title))
                let authorOK = lastName.isEmpty || r.author.lowercased().contains(lastName)
                if exact || (close && authorOK) {
                    copies.append(Copy(sourceID: batch.sourceID, sourceName: batch.sourceName,
                                       result: r, exact: exact))
                }
            }
        }
        let rank = ["epub": 0, "pdf": 1, "cbz": 2, "txt": 3]
        copies.sort { a, b in
            if a.exact != b.exact { return a.exact }
            let aFormat = rank[a.result.preferred?.format ?? ""] ?? 9
            let bFormat = rank[b.result.preferred?.format ?? ""] ?? 9
            if aFormat != bFormat { return aFormat < bFormat }
            // Download popularity is meaningful only when the provider supplies
            // comparable real counts for both results. Otherwise maintain a
            // stable ordering; 16 partner URLs does not mean 16 downloads.
            if a.sourceID == b.sourceID,
               let aCount = a.result.downloadCount,
               let bCount = b.result.downloadCount,
               aCount != bCount { return aCount > bCount }
            if a.sourceID != b.sourceID {
                return priority(a.sourceID, for: expectedLanguage) < priority(b.sourceID, for: expectedLanguage)
            }
            return a.result.id < b.result.id
        }
        return (copies, problems)
    }

    /// How long other sources may still answer once one has an exact EPUB.
    static let exactMatchGrace: Double = 4

    /// An EPUB whose title, author and listed language all match the request.
    static func verifiedExact(_ r: SourceResult, title: String, author: String, language: String?) -> Bool {
        guard r.preferred?.format == "epub",
              BookMatch.key(author: r.author, title: r.title) == BookMatch.key(author: author, title: title)
        else { return false }
        guard let language else { return true }
        return BookLanguage.matches(r.language, expected: language) == true
    }

    /// "Error: Error: Timed out" from a JavaScript exception reads as
    /// "Timed out" in the activity log.
    static func readableFailure(_ message: String) -> String {
        var text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("Error: ") { text.removeFirst("Error: ".count) }
        return text.replacingOccurrences(of: ": Error: ", with: ": ")
    }

    static func simpleTitle(_ t: String) -> String {
        let base = (t.components(separatedBy: ":").first ?? t).components(separatedBy: ";").first ?? t
        return base.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0.isNumber }
    }

    func nextSyncAllowed(_ id: String) -> Date? {
        guard let e = ext(id), let last = e.saved.lastSync else { return nil }
        let next = last.addingTimeInterval(e.manifest.syncIntervalHours * 3600)
        return next > Date() ? next : nil
    }

    /// demeter's scrape: new books since the last check, at most once per the source's interval.
    func checkForNew(_ id: String) async throws -> [SourceResult] {
        guard let e = ext(id) else { return [] }
        if let next = nextSyncAllowed(id) {
            throw ExtensionError(message: "This source was checked recently. To go easy on the servers, try again \(next.formatted(.relative(presentation: .named))).")
        }
        let state: Any = e.saved.syncState.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } ?? [String: Any]()
        let r = try await e.runtime.invoke("sync", [state]) as? [String: Any] ?? [:]
        let books = (r["books"] as? [Any] ?? []).compactMap(SourceResult.from)
        let newState = r["state"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) }
        update(id) { s in
            s.syncState = newState
            s.lastSync = Date()
            s.seenNew = books.count
        }
        return books
    }

    /// Downloads a result's file (only from the source's own servers) and adds it to the library.
    @discardableResult
    func download(_ result: SourceResult, from id: String, into store: LibraryStore,
                  using jobSession: JobSession? = nil,
                  onEvent: @escaping (SourceEvent) -> Void = { _ in }) async throws -> UUID {
        guard let e = jobSession == nil ? ext(id) : jobSession?.source(id), let d = result.preferred else {
            throw ExtensionError(message: "No format Folio can read or source isn't enabled for this job.")
        }
        guard let key = SourceRuntime.hostKey(d.url), reach(e).contains(key) else { throw ExtensionError(message: "Blocked: that file isn't on one of this source's servers.") }
        // Try every link the source gave for this format, in order (e.g. a mirror, then the main site).
        let candidates = result.downloads.filter { $0.format == d.format }
        var lastError: Error = ExtensionError(message: "No download link.")
        var fetched: URL?
        for (index, c) in candidates.enumerated() {
            try Task.checkCancellation()
            guard let k = SourceRuntime.hostKey(c.url), reach(e).contains(k) else {
                lastError = ExtensionError(message: "Blocked: that file isn't on one of this source's servers."); continue
            }
            do {
                var actual = c.url
                if e.manifest.canPrepareDownload {
                    onEvent(.status("Preparing free download · link \(index + 1) of \(candidates.count)"))
                    guard let response = try await e.runtime.invoke("prepareDownload", [c.url.absoluteString], onEvent: onEvent)
                        as? String, let resolved = URL(string: response),
                          resolved.user == nil, resolved.password == nil else {
                        throw ExtensionError(message: "The extension could not resolve this landing page into a file URL.")
                    }
                    // The file itself may live on any HTTPS host the partner page
                    // sends it to (partners rotate file hosts). Only the file is
                    // fetched there: no browser cookies, and it must be a real EPUB.
                    guard resolved.scheme?.lowercased() == "https", resolved.host != nil else {
                        throw ExtensionError(message: "Free partner resolved to a non-HTTPS file link.")
                    }
                    if let key = SourceRuntime.hostKey(resolved), !reach(e).contains(key) {
                        onEvent(.log("Link \(index + 1): file is on \(resolved.host ?? "another host"), outside the source's own servers; downloading the file only."))
                    }
                    actual = resolved
                }
                try Task.checkCancellation()
                onEvent(.status("Downloading EPUB from \(actual.host ?? "approved source")…"))
                var req = URLRequest(url: actual)
                req.setValue("Folio / demeter-compatible", forHTTPHeaderField: "User-Agent")
                // A separate cookie-less URLSession would lose the browser's
                // ephemeral verification cookies. Share only the approved host.
                for (header, value) in await e.runtime.browserDownloadHeaders(for: actual) {
                    req.setValue(value, forHTTPHeaderField: header)
                }
                // The file gets its own long-lived transfer (see FileTransfer),
                // still in-app, so encrypted DNS covers it.
                let host = actual.host ?? "the file host"
                let (tmp, resp) = try await FileTransfer.download(req, hasAlternative: index + 1 < candidates.count,
                    progress: { received, expected in onEvent(.transfer(received: received, expected: expected)) },
                    onRetry: { note in
                        onEvent(.log("\(host) link \(index + 1): \(note)"))
                        onEvent(.status("Connection dropped; resuming the EPUB from \(host)…"))
                    })
                try Task.checkCancellation()
                if let http = resp as? HTTPURLResponse, http.statusCode >= 300 {
                    lastError = ExtensionError(message: (300..<400).contains(http.statusCode)
                        ? "Blocked: the download redirected to a non-HTTPS link."
                        : (http.statusCode == 503 ? "\(actual.host ?? "The server") is busy (503). Try again later." : "\(actual.host ?? "The server") answered \(http.statusCode)."))
                    onEvent(.log("\(actual.host ?? "Source") link \(index + 1): \(lastError.localizedDescription)"))
                    continue
                }
                if !["html", "htm", "txt", "md", "rtf"].contains(d.format),
                   let mime = resp.mimeType?.lowercased(), mime.contains("text/html") {
                    lastError = ExtensionError(message: "The source returned a web page instead of a \(d.format.uppercased()) file. A free partner countdown or browser verification may still be required.")
                    if let bytes = try? Data(contentsOf: tmp),
                       let text = String(data: bytes.prefix(500_000), encoding: .utf8) {
                        let pattern = #"\bwaitSeconds\s*=\s*(\d{1,5})"#
                        if let match = text.range(of: pattern, options: .regularExpression),
                           let seconds = Int(String(text[match]).components(separatedBy: "=").last?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") {
                            onEvent(.status("Free partner requests about \(seconds)s of waiting; no EPUB file yet"))
                            onEvent(.log("Partner HTML countdown: \(seconds) seconds (unverified availability)"))
                        }
                    }
                    onEvent(.log("\(actual.host ?? "Source") link \(index + 1): \(lastError.localizedDescription)"))
                    continue
                }
                if ["epub", "cbz", "pdf"].contains(d.format) {
                    let stream = try FileHandle(forReadingFrom: tmp)
                    let header = try stream.read(upToCount: 8) ?? Data()
                    try stream.close()
                    let valid = d.format == "pdf" ? header.starts(with: Array("%PDF".utf8))
                        : header.starts(with: [0x50, 0x4b, 0x03, 0x04])
                    guard valid else {
                        lastError = ExtensionError(message: "The source did not provide a real \(d.format.uppercased()) file (invalid file signature).")
                        onEvent(.log("\(actual.host ?? "Source") link \(index + 1): \(lastError.localizedDescription)"))
                        continue
                    }
                }
                onEvent(.status("Downloaded \(d.format.uppercased()) · preparing to import"))
                fetched = tmp
                break
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                lastError = error
                let next = index + 1 < candidates.count ? "; trying link \(index + 2)" : ""
                onEvent(.log("\(c.url.host ?? "Source") link \(index + 1): \(Self.readableFailure(error.localizedDescription))\(next)"))
            }
        }
        guard let tmp = fetched else { throw lastError }
        let safe = String(result.title.map { "/:\\".contains($0) ? "-" : $0 }.prefix(80))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FolioDownloads/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent("\(safe).\(d.format)")
        try FileManager.default.moveItem(at: tmp, to: dest)
        onEvent(.status("Importing \(d.format.uppercased()) into the library"))
        return try await store.importBook(dest, author: result.author)
    }
}

// MARK: - Matching (demeter's hashBook: author's last name + simplified title)

enum BookMatch {
    /// Keys already worked out. Lists ask for the same books on every redraw
    /// (read filters, library checks), and each key runs several regular
    /// expressions, which made scrolling those lists stutter.
    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 20_000
        return cache
    }()

    static func key(author: String, title: String) -> String {
        let cacheKey = (author + "\u{1F}" + title) as NSString
        if let hit = cache.object(forKey: cacheKey) { return hit as String }
        let value = computeKey(author: author, title: title)
        cache.setObject(value as NSString, forKey: cacheKey)
        return value
    }

    private static func computeKey(author: String, title: String) -> String {
        var a = author.lowercased().replacingOccurrences(of: "-", with: " ")
        if a.contains(",") {
            let parts = a.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { a = parts[1] + " " + parts[0] }
        }
        let last = a.split(separator: " ").last.map(String.init) ?? ""
        var t = title.lowercased()
        if !a.isEmpty { t = t.replacingOccurrences(of: a, with: "") }
        if !last.isEmpty { t = t.replacingOccurrences(of: last, with: "") }
        t = t.replacingOccurrences(of: "^ *[0-9]+", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\(.*\\)", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[.*\\]", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: ": a novel", with: " ")
        let combined = (last + " " + t).folding(options: .diacriticInsensitive, locale: nil)
        return combined.filter { $0.isLetter || $0.isNumber }
    }
}

/// One request's outcome, handed from URLSession's queue to the waiting
/// extension queue.
private final class FetchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<String, Error>?
    func set(_ result: Result<String, Error>) { lock.lock(); value = result; lock.unlock() }
    func get() -> Result<String, Error>? { lock.lock(); defer { lock.unlock() }; return value }
}

/// Collects a mirror race: the first success wins; the waiter is woken by that
/// success or once every request has failed.
private final class FetchRace: @unchecked Sendable {
    private let lock = NSLock()
    private let count: Int
    private var errors: [Int: Error] = [:]
    private var won: (Int, String)?
    private var signalled = false

    init(count: Int) { self.count = count }

    /// Records an outcome; true exactly once, when the waiter should wake.
    func finish(_ index: Int, _ result: Result<String, Error>) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !signalled else { return false }
        switch result {
        case .success(let text):
            won = (index, text)
            signalled = true
        case .failure(let error):
            errors[index] = error
            signalled = errors.count == count
        }
        return signalled
    }

    var winner: (Int, String)? { lock.lock(); defer { lock.unlock() }; return won }
    func error(_ index: Int) -> Error? { lock.lock(); defer { lock.unlock() }; return errors[index] }
}

/// Sources whose search Folio stopped waiting for; their late events are dropped.
private final class SearchMute: @unchecked Sendable {
    private let lock = NSLock()
    private var names: Set<String> = []
    func mute(_ name: String) { lock.lock(); names.insert(name); lock.unlock() }
    func isMuted(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return names.contains(name) }
}

/// Process-wide notes that sources keep across their per-job runtimes.
final class SourceMemo: @unchecked Sendable {
    static let shared = SourceMemo()
    private let lock = NSLock()
    private var notes: [String: (value: String, until: Date)] = [:]

    func set(_ key: String, _ value: String, seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        if seconds <= 0 { notes[key] = nil; return }
        notes[key] = (value, Date().addingTimeInterval(min(seconds, 86_400)))
        if notes.count > 200 { notes = notes.filter { $0.value.until > Date() } }
    }

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let note = notes[key] else { return nil }
        if note.until <= Date() { notes[key] = nil; return nil }
        return note.value
    }
}
