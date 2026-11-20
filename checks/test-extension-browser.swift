// Compile with the app's ExtensionBrowser.swift. A local test HTTP server must
// respond to /page with a JS-enabled HTML document and /redirect with a 302.
// This probe deliberately creates NO windows, tabs or navigation panels.
import Foundation
import AppKit

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

@main
struct BrowserProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let port = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "8765"
        let origin = "http://127.0.0.1:\(port)"
        let browser = ExtensionBrowser(permitted: { ["\(origin)"] })
        Task.detached {
            do {
                let html = try browser.perform(.open, argument: "\(origin)/page")
                guard html.contains("JS executed"), html.contains("data-ad-slot") else {
                    throw ExtensionError(message: "Rendered DOM did not include the script-generated content.")
                }
                guard try browser.perform(.url) == "\(origin)/page" else {
                    throw ExtensionError(message: "Browser did not retain its current address.")
                }
                let text = try browser.perform(.evaluate, argument: "document.querySelector('#dynamic').textContent")
                guard text == "JS executed" else { throw ExtensionError(message: "WebKit JavaScript evaluation failed: \(text)") }
                let protected = URL(string: "\(origin)/protected-book.epub")!
                let headers = await browser.requestHeaders(for: protected)
                guard headers["Cookie"]?.contains("folio_browser_check=passed") == true else {
                    throw ExtensionError(message: "Browser verification cookie was not made available to the approved download")
                }
                let unverified = try await URLSession.shared.data(from: protected)
                guard (unverified.1 as? HTTPURLResponse)?.statusCode == 403 else {
                    throw ExtensionError(message: "The test EPUB was not protected before cookie sharing")
                }
                var verified = URLRequest(url: protected)
                headers.forEach { verified.setValue($0.value, forHTTPHeaderField: $0.key) }
                let fetched = try await URLSession.shared.data(for: verified)
                guard (fetched.1 as? HTTPURLResponse)?.statusCode == 200,
                      fetched.0.starts(with: [0x50, 0x4b]), fetched.0.count > 300 else {
                    throw ExtensionError(message: "A verified browser session did not fetch the test EPUB")
                }
                guard try browser.perform(.waitFor, argument: "#dynamic") == "true" else {
                    throw ExtensionError(message: "Browser waitFor failed")
                }
                let css = try browser.perform(.evaluate, argument: "getComputedStyle(document.querySelector('[data-ad-slot]')).display")
                guard css == "none" else { throw ExtensionError(message: "Native WebKit ad hiding is missing: \(css)") }
                let redirected = try browser.perform(.open, argument: "\(origin)/same-host-redirect")
                guard redirected.contains("JS executed"), try browser.perform(.url) == "\(origin)/page" else {
                    throw ExtensionError(message: "Same-host browser redirects failed")
                }
                do {
                    _ = try browser.perform(.open, argument: "https://example.invalid/not-approved")
                    throw ExtensionError(message: "The browser permitted an undeclared host.")
                } catch let error as ExtensionError where error.message.contains("unapproved") {
                    // Expected: the extension's declared hosts are enforced.
                }
                do {
                    _ = try browser.perform(.open, argument: "\(origin)/redirect")
                    throw ExtensionError(message: "The browser followed an unauthorized redirect.")
                } catch let error as ExtensionError where error.message.contains("unapproved") {
                    // Expected: even navigation responses cannot leave the allowlist.
                }
                let windowCount = await MainActor.run { NSApplication.shared.windows.filter(\.isVisible).count }
                guard windowCount == 0 else { throw ExtensionError(message: "A browser window became visible.") }
                _ = try browser.perform(.close)
                print("PASS: offscreen WebKit JavaScript, rendered HTML, privacy CSS blocker, host allowlist, redirect guard, and zero windows")
                fflush(stdout)
                exit(0)
            } catch {
                fputs("FAIL: \(error)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }
}
