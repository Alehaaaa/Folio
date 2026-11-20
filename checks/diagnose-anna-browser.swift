import AppKit
import Foundation

struct ExtensionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
enum SourceRuntime {
    static func hostKey(_ u: URL) -> String? {
        guard let scheme = u.scheme?.lowercased(), ["http","https"].contains(scheme), let host = u.host else { return nil }
        return "\(scheme)://\(host):\(u.port ?? (scheme == "https" ? 443 : 80))"
    }
}

@main
struct AnnaBrowserDiagnostics {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task.detached {
            let browser = ExtensionBrowser(permitted: { ["https://annas-archive.gl:443", "https://annas-archive.pk:443"] })
            for host in ["annas-archive.gl", "annas-archive.pk"] {
                do {
                    let path = "/search?q=Pride%20and%20Prejudice%20Jane%20Austen&display=table&ext=epub&page=1"
                    let html = try browser.perform(.open, argument: "https://\(host)\(path)")
                    let url = try browser.perform(.url)
                    print("FIRST \(host) url=\(url) bytes=\(html.utf8.count) preview=\(html.prefix(700))")
                    fflush(stdout)
                    try await Task.sleep(for: .seconds(12))
                    let later = try browser.perform(.html)
                    let after = try browser.perform(.url)
                    print("AFTER \(host) url=\(after) bytes=\(later.utf8.count) preview=\(later.prefix(1000))")
                    fflush(stdout)
                } catch { print("ERROR \(host): \(error)"); fflush(stdout) }
            }
            exit(0)
        }
        app.run()
    }
}
