// Read-only Apple URLSession network probe, suitable for macOS or iOS Simulator.
// Makes HEAD requests to site roots, never searches or downloads book files.
import Foundation

@main
struct FolioNetworkProbe {
    static let hosts = [
        "annas-archive.gl", "annas-archive.gd", "annas-archive.pk",
        "www.gutenberg.org", "www.apple.com", "raw.githubusercontent.com"
    ]

    static func main() async {
        print("Folio URLSession diagnostic · \(Date().formatted(.iso8601))")
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 7
        settings.timeoutIntervalForResource = 8
        settings.httpShouldSetCookies = false
        settings.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }

        await withTaskGroup(of: String.self) { group in
            for host in hosts {
                group.addTask {
                    guard let url = URL(string: "https://\(host)/") else { return "\(host): bad URL" }
                    var request = URLRequest(url: url)
                    request.httpMethod = "HEAD"
                    request.timeoutInterval = 7
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    do {
                        let (_, response) = try await session.data(for: request)
                        if let http = response as? HTTPURLResponse {
                            return "\(host): SUCCESS HTTP \(http.statusCode) · final host \(http.url?.host ?? "unknown")"
                        }
                        return "\(host): SUCCESS, unexpected response class \(type(of: response))"
                    } catch {
                        let ns = error as NSError
                        var facts = ["\(host): ERROR \(ns.domain) \(ns.code) · \(ns.localizedDescription)"]
                        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                            facts.append("underlying \(underlying.domain) \(underlying.code) · \(underlying.localizedDescription)")
                        }
                        if let stream = ns.userInfo["_kCFStreamErrorCodeKey"] as? Int {
                            facts.append("CFStream code \(stream)")
                        }
                        return facts.joined(separator: " | ")
                    }
                }
            }
            for await result in group { print(result) }
        }
    }
}
