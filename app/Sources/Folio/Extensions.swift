import Foundation
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
    /// "source" finds books to download; "metadata" answers Edit Details with book records.
    var kind: String = "source"

    var isMetadata: Bool { kind == "metadata" }
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
        queue = DispatchQueue(label: "folio.extension.\(label)", qos: .userInitiated)
        guard_ = RedirectGuard { [weak self] url in self?.isAllowed(url) ?? false }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
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
            do { return try self.blockingFetch(urlString, headers: headers) } catch {
                JSContext.current()?.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: JSContext.current())
                return nil
            }
        }
        folio.setObject(fetchWith, forKeyedSubscript: "fetchWith" as NSString)
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

    /// Runs on the extension's own queue, so this blocking request never touches the app's main thread.
    private func blockingFetch(_ urlString: String, headers: [String: String] = [:]) throws -> String {
        guard let url = URL(string: urlString) else { throw ExtensionError(message: "Bad address: \(urlString)") }
        guard let key = Self.hostKey(url), allowedHosts.contains(key) else {
            throw ExtensionError(message: "Blocked: this extension may only reach the servers in its settings (\(url.host ?? urlString)).")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("Folio / demeter-compatible", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { req.setValue(value, forHTTPHeaderField: name) }
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<String, Error> = .failure(ExtensionError(message: "Timed out"))
        session.dataTask(with: req) { data, resp, err in
            if let err { result = .failure(err) }
            else if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                result = .failure(ExtensionError(message: "\(url.host ?? "server") answered \(http.statusCode)"))
            } else if let data, data.count <= 20_000_000 {
                result = .success(String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self))
            } else {
                result = .failure(ExtensionError(message: "Answer too large"))
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 35)
        return try result.get()
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
            guard let id = str("id"), let name = str("name") else { throw ExtensionError(message: "The extension needs an id and a name.") }
            return SourceManifest(
                id: id, name: name, description: str("description") ?? "", version: str("version") ?? "1",
                syncIntervalHours: s.objectForKeyedSubscript("syncIntervalHours")?.toNumber()?.doubleValue ?? 12,
                settings: settings, canSearch: isFn("search"), canSync: isFn("sync"),
                canPrepareDownload: isFn("prepareDownload"), fixedHosts: fixed,
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
        var next = request
        if let previous = response.url, SourceRuntime.hostKey(previous) != SourceRuntime.hostKey(url) {
            // Never send WebKit session cookies to another allowed host.
            next.setValue(nil, forHTTPHeaderField: "Cookie")
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
    }
}

// MARK: - Installed extensions

@Observable
@MainActor
final class ExtensionStore {
    static let shared = ExtensionStore()

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

    /// Enabled download sources (metadata sources never take part in finding copies).
    var enabled: [Installed] { installed.filter { $0.saved.enabled && !$0.manifest.isMetadata } }

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
        #if os(iOS)
        // Ship the same external JavaScript source extensions as the macOS
        // distribution. Bundled sources are refreshed with each iOS app build;
        // the user's per-source configuration and enabled state are retained.
        let idPattern = try? NSRegularExpression(pattern: #"\bid\s*:\s*["']([A-Za-z0-9_-]+)["']"#)
        for url in (Bundle.main.urls(forResourcesWithExtension: "js", subdirectory: nil) ?? []).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let script = try? String(contentsOf: url, encoding: .utf8),
                  let match = idPattern?.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
                  let range = Range(match.range(at: 1), in: script) else { continue }
            let id = String(script[range])
            guard !DefaultSources.builtIn.contains(where: { $0.id == id }) else { continue }
            let file = id + ".js"
            try? script.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
            if savedByID[id] == nil { savedByID[id] = Saved(file: file, builtIn: true) }
            savedByID[id]?.file = file
            savedByID[id]?.builtIn = true
        }
        #endif
        Task { await loadAll() }
    }

    private func persist() {
        for i in installed { savedByID[i.id] = i.saved }
        if let d = try? JSONEncoder().encode(savedByID) { try? d.write(to: savedURL, options: .atomic) }
    }

    func loadAll() async {
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
        installed = out
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
        for e in jobSession?.sources ?? enabled {
            if e.manifest.settings.contains(where: { $0.kind == "list" }) && SourceRuntime.allowed(from: e.saved.config).isEmpty { continue }
            progress(e.manifest.name)
            do {
                let shortTitle = title.components(separatedBy: ":").first ?? title
                let results = try await search(e.id, query: "\(shortTitle) \(lastName)".trimmingCharacters(in: .whitespaces),
                                               expectedLanguage: expectedLanguage, expectedTitle: title,
                                               expectedAuthor: author,
                                               using: jobSession,
                                               onEvent: { event in onEvent(e.manifest.name, event) })
                for r in results where r.preferred != nil {
                    let exact = BookMatch.key(author: r.author, title: r.title) == wanted
                    let close = Self.simpleTitle(r.title).hasPrefix(wantedTitle) || wantedTitle.hasPrefix(Self.simpleTitle(r.title))
                    let authorOK = lastName.isEmpty || r.author.lowercased().contains(lastName)
                    if exact || (close && authorOK) {
                        copies.append(Copy(sourceID: e.id, sourceName: e.manifest.name, result: r, exact: exact))
                    }
                }
            } catch {
                let message = "\(e.manifest.name): \(error.localizedDescription)"
                problems.append(message)
                onEvent(e.manifest.name, .log("Search failed: \(error.localizedDescription)"))
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
            if a.sourceID != b.sourceID { return a.sourceID < b.sourceID }
            return a.result.id < b.result.id
        }
        return (copies, problems)
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
                    guard let key = SourceRuntime.hostKey(resolved), reach(e).contains(key) else {
                        throw ExtensionError(message: "Free partner resolved to an unapproved file host: \(resolved.host ?? "unknown"). Enable only a trusted provider domain in the extension settings.")
                    }
                    actual = resolved
                }
                try Task.checkCancellation()
                onEvent(.status("Downloading EPUB from \(actual.host ?? "approved source")…"))
                var req = URLRequest(url: actual)
                req.timeoutInterval = 120
                req.setValue("Folio / demeter-compatible", forHTTPHeaderField: "User-Agent")
                // A separate cookie-less URLSession would lose the browser's
                // ephemeral verification cookies. Share only the approved host.
                for (header, value) in await e.runtime.browserDownloadHeaders(for: actual) {
                    req.setValue(value, forHTTPHeaderField: header)
                }
                let (tmp, resp) = try await e.runtime.session.download(for: req)
                try Task.checkCancellation()
                if let http = resp as? HTTPURLResponse, http.statusCode >= 300 {
                    lastError = ExtensionError(message: (300..<400).contains(http.statusCode)
                        ? "Blocked: the download tried to move to another server."
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
                onEvent(.log("\(c.url.host ?? "Source") link \(index + 1): \(error.localizedDescription)"))
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
    static func key(author: String, title: String) -> String {
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
