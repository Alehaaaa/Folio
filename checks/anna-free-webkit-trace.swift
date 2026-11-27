// Read-only live diagnostic for Anna's Archive free, public-domain book pages.
// Compile together with app/Core/ExtensionBrowser.swift:
// swiftc -parse-as-library checks/anna-free-webkit-trace.swift app/Core/ExtensionBrowser.swift -o checks/anna-free-webkit-trace
// Run checks/anna-free-webkit-trace [inspect|watch] [serverIndex]
// This creates no app state, supplies no credentials, and never clicks challenges.
import AppKit
import CryptoKit
import Foundation
import JavaScriptCore

struct ExtensionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum SourceRuntime {
    static func hostKey(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased() else { return nil }
        return "\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
    }
}

private enum Trace {
    static let hash = "dba7a9943ea918a5afd2b170527fca13"
    static let hosts = ["annas-archive.gl", "annas-archive.pk", "annas-archive.gd"]
    static let allowed = Set(hosts.map { "https://\($0):443" })

    static func say(_ text: String) {
        print(text)
        fflush(stdout)
    }

    static func browser() -> ExtensionBrowser {
        ExtensionBrowser(permitted: { allowed })
    }

    static let inspectionScript = #"""
    (() => {
      const timing = performance.getEntriesByType('navigation')[0] || null;
      const links = Array.from(document.querySelectorAll('a[href]'))
        .filter(a => /download|epub|partner|wait/i.test((a.textContent || '') + ' ' + a.href))
        .slice(0, 24)
        .map(a => {
          try {
            const u = new URL(a.href, document.baseURI);
            return {label:(a.textContent || '').trim().slice(0,90),
              host:u.hostname, path:u.pathname, query:!!u.search};
          } catch(e) { return {label:'invalid URL'} }
        });
      let seconds = null;
      try { if (typeof waitSeconds === 'number') seconds = waitSeconds; } catch (e) {}
      return JSON.stringify({
        title:document.title,
        readyState:document.readyState,
        navResponseStatus: timing ? (timing.responseStatus || null) : null,
        pathname:location.pathname,
        countdown:document.querySelector('.js-partner-countdown')?.textContent?.trim() || null,
        waitSeconds:seconds,
        completeLinkCount:links.length,
        links:links
      });
    })()
    """#

    static func inspect(_ browser: ExtensionBrowser, stage: String, html: String) {
        do {
            let u = try browser.perform(.url)
            let details = try browser.perform(.evaluate, argument: inspectionScript)
            let md5 = html.contains("/md5/\(hash)")
            let slow = html.contains("/slow_download/\(hash)")
            let zip = html.hasPrefix("PK\u{03}\u{04}")
            say("WEBKIT \(stage) url=\(u) bytes=\(html.utf8.count) containsTargetMD5=\(md5) hasSlowPath=\(slow) isZipText=\(zip)")
            say("DOM \(stage) \(details)")
        } catch {
            say("WEBKIT \(stage) inspection-error=\(error.localizedDescription)")
        }
    }

    static func publishedFileURL(_ html: String) -> String? {
        // Test the *current distributable source function* on REAL rendered
        // WebKit HTML. This does not edit or install the extension.
        guard let source = try? String(contentsOfFile: "extensions/annas-archive.js", encoding: .utf8),
              let context = JSContext(virtualMachine: JSVirtualMachine()) else { return nil }
        context.setObject(JSValue(newObjectIn: context), forKeyedSubscript: "folio" as NSString)
        context.evaluateScript(source)
        context.setObject(html, forKeyedSubscript: "diagnosticReadyHTML" as NSString)
        let value = context.evaluateScript("source.publishedFileURL(diagnosticReadyHTML)")
        return value?.isString == true ? value?.toString() : nil
    }

    static func inspectDirectFile(_ browser: ExtensionBrowser, html: String) async {
        do {
            guard let raw = publishedFileURL(html) else {
                say("FINAL LINK parser did not find a published HTTPS URL in real rendered HTML")
                return
            }
            guard let url = URL(string: raw), url.scheme == "https", url.user == nil,
                  url.password == nil, let host = url.host?.lowercased(),
                  !host.isEmpty, !host.contains("annas-archive.is") else {
                say("FINAL LINK parser returned an invalid/untrusted URL")
                return
            }
            say("FINAL LINK EXTENSION PARSER MATCH=TRUE host=\(host) pathExtension=\(url.pathExtension) queryPresent=\(url.query != nil) sameOfficialHost=\(hosts.contains(host))")

            // Request only the public-domain sample linked by the official page;
            // no keys, cookies, challenge solving, or unsolicited redirects.
            let cfg = URLSessionConfiguration.ephemeral
            cfg.httpCookieStorage = nil
            cfg.timeoutIntervalForRequest = 25
            cfg.timeoutIntervalForResource = 35
            let session = URLSession(configuration: cfg, delegate: SameHostRedirects(host: host), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            var request = URLRequest(url: url)
            request.timeoutInterval = 25
            request.setValue("bytes=0-524287", forHTTPHeaderField: "Range")
            // If the destination is the official same-origin page, carry the
            // normal WebKit session headers just like Folio's downloader.
            if hosts.contains(host) {
                for (name, value) in await browser.requestHeaders(for: url) { request.setValue(value, forHTTPHeaderField: name) }
            }
            do {
                let (bytes, response) = try await session.data(for: request)
                let http = response as? HTTPURLResponse
                let magic = bytes.prefix(8).map { String(format: "%02x", $0) }.joined()
                let zip = bytes.starts(with: [0x50, 0x4b, 0x03, 0x04])
                let md5 = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                say("FINAL GET http=\(http?.statusCode ?? -1) mime=\(response.mimeType ?? "none") bytes=\(bytes.count) range=\(http?.value(forHTTPHeaderField: "Content-Range") ?? "none") magic=\(magic) isZIP=\(zip) md5=\(md5) expectedMD5=\(hash)")
            } catch {
                say("FINAL GET failed=\(error.localizedDescription)")
            }
        } catch {
            say("FINAL LINK probe failed=\(error.localizedDescription)")
        }
    }

    static func open(_ browser: ExtensionBrowser, _ url: String, stage: String) {
        say("NAVIGATE \(stage) request=\(url)")
        do {
            let html = try browser.perform(.open, argument: url)
            inspect(browser, stage: stage, html: html)
        } catch {
            say("ERROR \(stage) \(error.localizedDescription)")
            if let last = try? browser.perform(.url) { say("ERROR \(stage) currentURL=\(last)") }
        }
    }

    static func run(mode: String, selected: Int) async {
        let b = browser()
        let q = "Pride%20and%20Prejudice%20Jane%20Austen"
        if mode == "one" {
            let server = min(max(selected, 0), 3)
            let host = "annas-archive.gl"
            open(b, "https://\(host)/search?q=\(q)&display=table&ext=epub&page=1", stage: "search \(host)")
            open(b, "https://\(host)/md5/\(hash)", stage: "record \(host)")
            open(b, "https://\(host)/slow_download/\(hash)/0/\(server)", stage: "slow \(host) server=\(server)")
            if let html = try? b.perform(.html), publishedFileURL(html) != nil {
                await inspectDirectFile(b, html: html)
            }
        } else if mode == "inspect" {
            for host in hosts {
                open(b, "https://\(host)/search?q=\(q)&display=table&ext=epub&page=1", stage: "search \(host)")
                open(b, "https://\(host)/md5/\(hash)", stage: "record \(host)")
                for server in 0..<4 {
                    open(b, "https://\(host)/slow_download/\(hash)/0/\(server)", stage: "slow \(host) server=\(server)")
                }
            }
        } else {
            let server = min(max(selected, 0), 3)
            let url = "https://annas-archive.gl/slow_download/\(hash)/0/\(server)"
            open(b, url, stage: "wait start server=\(server)")
            let initial = (try? b.perform(.html)) ?? ""
            var linked = publishedFileURL(initial) != nil
            if linked { await inspectDirectFile(b, html: initial) }
            for n in 1...10 {
                if linked { break }
                try? await Task.sleep(for: .seconds(10))
                do {
                    let current = try b.perform(.url)
                    let html = try b.perform(.html)
                    inspect(b, stage: "wait t=\(n * 10)s current=\(current)", html: html)
                    linked = publishedFileURL(html) != nil
                    if linked {
                        await inspectDirectFile(b, html: html)
                        break
                    }
                    if !current.contains("annas-archive.gl/slow_download/") {
                        say("WAIT Navigation reached new path; final transfer not yet verified.")
                        break
                    }
                } catch {
                    say("WAIT t=\(n * 10)s error=\(error.localizedDescription)")
                    break
                }
            }
        }
        _ = try? b.perform(.close)
        say("DONE mode=\(mode)")
    }
}

private final class SameHostRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let host: String
    init(host: String) { self.host = host }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let next = request.url, next.scheme == "https", next.host?.lowercased() == host else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

@main
struct AnnaFreeWebKitTrace {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let mode = CommandLine.arguments.dropFirst().first ?? "inspect"
        let index = CommandLine.arguments.dropFirst(2).first.flatMap(Int.init) ?? 0
        Task.detached {
            await Trace.run(mode: mode, selected: index)
            exit(0)
        }
        app.run()
    }
}
