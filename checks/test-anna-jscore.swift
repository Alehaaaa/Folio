import Foundation
import JavaScriptCore

// Runs the distributable extension through the same JavaScriptCore VM as Folio.
// No network or app data is touched. Run from /books:
// swift checks/test-anna-jscore.swift

func fixture(_ filename: String) throws -> String {
    try String(contentsOfFile: "checks/anna-fixtures/\(filename)", encoding: .utf8)
}

do {
    let search = try fixture("search.html")
    let detail = try fixture("detail.html")
    let script = try String(contentsOfFile: "extensions/annas-archive.js", encoding: .utf8)
    let hash = "51d2b22ca12a8b470b51f543298b34c9"
    guard let context = JSContext(virtualMachine: JSVirtualMachine()),
          let folio = JSValue(newObjectIn: context) else { fatalError("JavaScriptCore unavailable") }

    var javascriptError: String?
    var statuses: [String] = []
    var diagnostics: [String] = []
    var requested: [String] = []
    context.exceptionHandler = { _, error in javascriptError = error?.toString() }
    let fetch: @convention(block) (String) -> String? = { url in
        requested.append(url)
        if url.contains("raw.githubusercontent.com") {
            return "export const OFFICIAL_MIRRORS = [\"annas-archive.gl\", \"annas-archive.pk\", \"annas-archive.gd\"] as const;"
        }
        if url.hasPrefix("https://annas-archive.gl/") {
            let current = JSContext.current()!
            current.exception = JSValue(newErrorFromMessage: "403 browser verification", in: current)
            return nil
        }
        if url.hasPrefix("https://annas-archive.pk/search?") { return search }
        if url == "https://annas-archive.pk/md5/\(hash)" { return detail }
        return nil
    }
    let log: @convention(block) (String) -> Void = { diagnostics.append($0) }
    let status: @convention(block) (String) -> Void = { statuses.append($0) }
    folio.setObject(fetch, forKeyedSubscript: "fetchText" as NSString)
    folio.setObject(log, forKeyedSubscript: "log" as NSString)
    folio.setObject(status, forKeyedSubscript: "status" as NSString)
    folio.setObject([String: Any](), forKeyedSubscript: "config" as NSString)
    context.setObject(folio, forKeyedSubscript: "folio" as NSString)
    context.evaluateScript(script)
    guard javascriptError == nil, let source = context.objectForKeyedSubscript("source"), source.isObject,
          source.objectForKeyedSubscript("search")?.isObject == true,
          source.objectForKeyedSubscript("recent")?.isObject == true else {
        fatalError("Folio extension manifest invalid: \(javascriptError ?? "unknown")")
    }
    let values = context.evaluateScript("source.search('Pride and Prejudice Jane Austen', 0)")?.toArray() as? [[String: Any]] ?? []
    guard javascriptError == nil, values.count == 1,
          values[0]["id"] as? String == hash,
          let files = values[0]["downloads"] as? [[String: String]],
          files.count == 1,
          files[0]["url"] == "https://annas-archive.pk/slow_download/\(hash)/0/0",
          files[0]["format"] == "epub" else {
        fatalError("JavaScriptCore search/download result mismatch: \(javascriptError ?? "none")")
    }
    let initialStages = ["Refreshing official mirrors", "Searching free EPUB listings", "Loading book details", "Checking published free download options"]
    guard initialStages.allSatisfy({ stage in statuses.contains(where: { $0.contains(stage) }) }),
          statuses.last?.contains("EPUB download unverified") == true,
          diagnostics.contains(where: { $0.contains("403 browser verification") }) else {
        fatalError("JavaScriptCore progress/status stages missing: \(statuses)")
    }

    // The hidden browser returns a rendered page only; visiting the free partner
    // landing page once exposes a wait estimate but never an EPUB payload.
    let browser = JSValue(newObjectIn: context)!
    var browserURLs: [String] = []
    let open: @convention(block) (String) -> String = { url in
        browserURLs.append(url)
        if url.contains("/slow_download/") {
            return "<html><script>var waitSeconds = 125;</script><p>Please wait</p></html>"
        }
        if url.contains("/md5/") { return detail }
        return search
    }
    browser.setObject(open, forKeyedSubscript: "open" as NSString)
    folio.setObject(browser, forKeyedSubscript: "browser" as NSString)
    context.evaluateScript("source.preferredMirror = ''; source.mirrorCache = null;")
    let rendered = context.evaluateScript("source.search('Pride and Prejudice Jane Austen', 0)")?.toArray() as? [[String: Any]] ?? []
    guard javascriptError == nil, rendered.count == 1,
          rendered[0]["origin"] as? String == "annas-archive.gl",
          browserURLs.count == 3,
          browserURLs.last?.contains("/slow_download/\(hash)/0/0") == true,
          statuses.contains(where: { $0.contains("Checking mirror in background browser") }),
          statuses.contains(where: { $0.contains("Checking free partner wait estimate") }),
          statuses.contains(where: { $0.contains("about 3 min (estimate)") }),
          statuses.last?.contains("Free partner wait ~3 min; EPUB unverified") == true,
          diagnostics.contains(where: { $0.contains("125 seconds") }),
          requested.allSatisfy({ !$0.contains("fast_download") && !$0.contains("dyn/api") && !$0.contains("key=") }) else {
        fatalError("JavaScriptCore browser and wait-state behavior failed; statuses=\(statuses), opened=\(browserURLs), JS=\(javascriptError ?? "none")")
    }
    print("PASS: Folio JavaScriptCore extension, public-domain search, mirror fallback, live status/log stages, one free-partner wait estimate, and no paid API requests.")
} catch {
    fputs("FAIL: \(error)\n", stderr)
    exit(1)
}
