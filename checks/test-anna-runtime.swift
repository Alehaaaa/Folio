// Executes Folio's unmodified SourceRuntime logic, compiled directly from
// app/Sources/Folio/Extensions.swift, against an installed-style JS extension.
// Use a public-domain title; never downloads arbitrary copyrighted content.
import Foundation
import AppKit

@main
struct AnnaRuntimeProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let scriptPath = root.appendingPathComponent("../extensions/annas-archive.js")
        Task.detached {
            do {
                let script = try String(contentsOf: scriptPath, encoding: .utf8) + """

                var originalSearchCards = source.searchCards;
                source.debugPage = function () {
                  return this.fetchPage('https://annas-archive.pk/search?q=Pride%20and%20Prejudice%20Jane%20Austen&display=table&ext=epub&page=1');
                };
                source.debugDownload = function (url) {
                  var content = folio.browser.open(url);
                  return JSON.stringify({ finalURL: folio.browser.url(), length: content.length,
                    title: (content.match(/<title[^>]*>([^<]*)<\\/title>/i) || [])[1] || '',
                    start: content.slice(0, 1200) });
                };
                source.debugRawDownload = function (url) { return folio.browser.open(url); };
                source.debugCurrentHTML = function () { return folio.browser.html(); };
                source.debugCurrentURL = function () { return folio.browser.url(); };
                source.debugServers = function () {
                  var root = 'https://annas-archive.gl/slow_download/dba7a9943ea918a5afd2b170527fca13/0/';
                  var outcomes = [];
                  for (var i = 0; i < 4; i++) {
                    try {
                      var content = folio.browser.open(root + i);
                      var wait = content.match(/waitSeconds\\s*=\\s*(\\d+)/i);
                      var countdown = content.match(/Please wait[^<]{0,180}/i);
                      outcomes.push({index: i, url: folio.browser.url(), length: content.length,
                        waitSeconds: wait ? Number(wait[1]) : null,
                        countdown: countdown ? countdown[0].slice(0, 120) : '',
                        hasDownloadLink: /href=["']https?:\\/\\/[^"']+\\.(?:epub|zip)/i.test(content)});
                    } catch(e) { outcomes.push({index:i,error:String(e)}) }
                  }
                  return JSON.stringify(outcomes);
                };
                source.maxResults = 4;
                source.searchCards = function (html) {
                  var h = String(html);
                  var title = h.match(/<title[^>]*>([^<]*)<\\/title>/i);
                  var first = h.indexOf('/md5/');
                  var summary = first < 0 ? h.replace(/<style[\\s\\S]*?<\\/style>/gi, '').slice(0, 1000) : h.slice(Math.max(0, first-350), first+1400);
                  folio.log('SEARCH HTML bytes=' + h.length + ' title=' + (title ? title[1] : 'none') + ' md5First=' + first + ' sample=' + summary);
                  return originalSearchCards.call(this, h);
                };
                """
                let runtime = SourceRuntime(script: script, label: "anna-live-integration")
                let manifest = try await runtime.manifest()
                guard manifest.id == "annas-archive-free" else { throw ExtensionError(message: "Wrong extension manifest") }
                guard manifest.fixedHosts.contains("https://annas-archive.gl") else { throw ExtensionError(message: "Missing official mirror") }
                if CommandLine.arguments.contains("--dump") {
                    let raw = try await runtime.invoke("debugPage", []) as? String ?? ""
                    let file = root.appendingPathComponent("checks/anna-live-pk.html")
                    try raw.write(to: file, atomically: true, encoding: .utf8)
                    print("BROWSER RENDERED SEARCH HTML: \(raw.utf8.count) bytes; \(file.path)")
                    fflush(stdout)
                    exit(0)
                }
                if CommandLine.arguments.contains("--dump-link") {
                    let slow = "https://annas-archive.gl/slow_download/dba7a9943ea918a5afd2b170527fca13/0/0"
                    let raw = try await runtime.invoke("debugRawDownload", [slow]) as? String ?? ""
                    let file = root.appendingPathComponent("checks/anna-slow-page.html")
                    try raw.write(to: file, atomically: true, encoding: .utf8)
                    print("BROWSER RENDERED SLOW PAGE: \(raw.utf8.count) bytes; \(file.path)")
                    fflush(stdout)
                    try await Task.sleep(for: .seconds(35))
                    let later = try await runtime.invoke("debugRawDownload", [slow]) as? String ?? ""
                    let current = try await runtime.invoke("debugCurrentURL", []) as? String ?? ""
                    let after = root.appendingPathComponent("checks/anna-slow-page-after.html")
                    try later.write(to: after, atomically: true, encoding: .utf8)
                    print("AFTER COUNTDOWN: \(later.utf8.count) bytes; URL=\(current); \(after.path)")
                    fflush(stdout)
                    exit(0)
                }
                if CommandLine.arguments.contains("--servers") {
                    let response = try await runtime.invoke("debugServers", []) as? String ?? ""
                    print("FREE SLOW SERVER OPTIONS: \(response)")
                    fflush(stdout)
                    exit(0)
                }
                let query = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Pride and Prejudice Jane Austen"
                let started = Date()
                do {
                    let raw = try await runtime.invoke("search", [query, 0])
                    let records = (raw as? [Any] ?? []).compactMap(SourceResult.from)
                    print("INTEGRATION SEARCH: \(records.count) readable EPUB candidates in \(Int(Date().timeIntervalSince(started))) seconds")
                    for r in records.prefix(3) {
                        print("Book: \(r.title) | \(r.author) | \(r.origin) | \(r.downloads.count) download options")
                    }
                    guard let result = records.first(where: {
                        $0.title.lowercased().contains("pride and prejudice") &&
                        $0.author.lowercased().contains("austen") && $0.preferred?.format == "epub"
                    }), let item = result.preferred else {
                        throw ExtensionError(message: "No public-domain test book with a live EPUB link was returned.")
                    }
                    guard runtime.isAllowed(item.url) else { throw ExtensionError(message: "The download URL is not allowlisted.") }
                    print("First published free links: \(result.downloads.prefix(5).map { $0.url.absoluteString }.joined(separator: " | "))")
                    fflush(stdout)
                    var request = URLRequest(url: item.url)
                    request.timeoutInterval = 90
                    request.setValue("Folio / demeter-compatible", forHTTPHeaderField: "User-Agent")
                    let (tmp, response) = try await runtime.session.download(for: request)
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if !(200..<300).contains(code) {
                        do {
                            let browser = try await runtime.invoke("debugDownload", [item.url.absoluteString]) as? String ?? ""
                            print("WebKit free link response: \(browser.prefix(2400))")
                        } catch { print("WebKit free link response error: \(error.localizedDescription)") }
                        throw ExtensionError(message: "Download server status \(code)")
                    }
                    let data = try Data(contentsOf: tmp)
                    guard data.count > 128, data.starts(with: [0x50, 0x4B]) else {
                        throw ExtensionError(message: "Response was not a ZIP/EPUB (\(data.count) bytes).")
                    }
                    print("PASS LIVE EPUB: \(data.count) bytes; public-domain sample; app-equivalent request and redirect guard")
                    fflush(stdout)
                    exit(0)
                } catch {
                    let elapsed = Int(Date().timeIntervalSince(started))
                    print("LIVE ANNA BLOCKED after \(elapsed) seconds: \(error.localizedDescription)")
                    let logs = runtime.recentLogs
                    for entry in logs.suffix(12) { print("  extension: \(entry)") }
                    fflush(stdout)
                    exit(2)
                }
            } catch {
                fputs("RUNTIME ERROR: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }
}
