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
    var origin: String
    var downloads: [SourceDownload]

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
            origin: (d["origin"] as? String) ?? "",
            downloads: downloads
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
    /// Servers the source always needs (declared as `allowedHosts`), shown to the person.
    var fixedHosts: [String] = []
}

struct ExtensionError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
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
    private let lock = NSLock()
    private var configHosts: Set<String> = []
    private var fixedHosts: Set<String> = []
    private var config: [String: Any] = [:]
    private var guard_: RedirectGuard!
    /// On-demand offscreen WebKit, per extension; no windows or user-facing tabs.
    private lazy var browser = ExtensionBrowser(permitted: { [weak self] in self?.allowedHosts ?? [] })
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

    func configure(_ config: [String: Any]) {
        lock.lock(); configHosts = Self.allowed(from: config); lock.unlock()
        queue.async {
            self.config = config
            self.context?.objectForKeyedSubscript("folio")?.setObject(config, forKeyedSubscript: "config" as NSString)
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
        folio.setObject(fetchText, forKeyedSubscript: "fetchText" as NSString)
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
    private func blockingFetch(_ urlString: String) throws -> String {
        guard let url = URL(string: urlString) else { throw ExtensionError(message: "Bad address: \(urlString)") }
        guard let key = Self.hostKey(url), allowedHosts.contains(key) else {
            throw ExtensionError(message: "Blocked: this extension may only reach the servers in its settings (\(url.host ?? urlString)).")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("Folio / demeter-compatible", forHTTPHeaderField: "User-Agent")
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
                settings: settings, canSearch: isFn("search"), canSync: isFn("sync"), fixedHosts: fixed
            )
        }
    }

    /// Calls `source.<name>(args…)` in isolation and hands back plain values.
    func invoke(_ name: String, _ args: [Any]) async throws -> Any? {
        try await run { ctx in
            self.lastException = nil
            let argsJSON = String(data: try JSONSerialization.data(withJSONObject: args), encoding: .utf8) ?? "[]"
            let r = ctx.evaluateScript("(function(){ var a = \(argsJSON); return source.\(name).apply(source, a); })()")
            if let e = self.lastException { throw ExtensionError(message: e) }
            return r?.toObject()
        }
    }

    var recentLogs: [String] { queue.sync { logs } }

    private func run<T>(_ body: @escaping (JSContext) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                do {
                    try self.setUp()
                    cont.resume(returning: try body(self.context!))
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
    init(_ allow: @escaping (URL) -> Bool) { self.allow = allow }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(allow) == true ? request : nil)
    }
}

