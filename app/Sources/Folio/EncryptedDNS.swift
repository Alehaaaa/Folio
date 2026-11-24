import Foundation
import Network
import Observation

/// Optional encrypted DNS for everything Folio fetches itself: Cloudflare's
/// DNS over HTTPS (1.1.1.1), set through the system's own privacy context, so
/// URLSession requests resolve names over HTTPS instead of plain DNS. Pages
/// inside the in-app browser (WebKit) keep the device's DNS.
///
/// Folio only turns it on after reaching Cloudflare by IP address; when that
/// fails it stays on the network's own DNS instead of breaking every request.
@Observable
@MainActor
final class FolioEncryptedDNS {
    static let shared = FolioEncryptedDNS()
    static let key = "folio.network.encryptedDNS"

    enum Status: Equatable {
        case off, checking, active
        /// Cloudflare couldn't be reached; Folio uses the network's DNS.
        case unavailable
    }

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.key)
            Task { await apply() }
        }
    }
    private(set) var status: Status = .off

    private static let resolver = NWParameters.PrivacyContext.ResolverConfiguration.https(
        URL(string: "https://cloudflare-dns.com/dns-query")!,
        serverAddresses: [.hostPort(host: "1.1.1.1", port: 443), .hostPort(host: "1.0.0.1", port: 443),
                          .hostPort(host: "2606:4700:4700::1111", port: 443)]
    )

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.key)
    }

    /// The setting as it was when Folio started. Connections made before a
    /// change keep the old resolver, so a change takes full effect on relaunch.
    private(set) var appliedAtLaunch = false

    /// Call once at launch, before the first request. The resolver is set
    /// right away so no connection is made with plain DNS first; the
    /// Cloudflare check follows and turns it back off if Cloudflare can't be reached.
    func start() {
        appliedAtLaunch = enabled
        if enabled {
            NWParameters.PrivacyContext.default.requireEncryptedNameResolution(true, fallbackResolver: Self.resolver)
            status = .checking
        }
        Task { await apply() }
    }

    /// True when the switch was changed since launch and Folio should restart.
    var needsRelaunch: Bool { enabled != appliedAtLaunch }

    func apply() async {
        let context = NWParameters.PrivacyContext.default
        guard enabled else {
            context.requireEncryptedNameResolution(false, fallbackResolver: nil)
            status = .off
            return
        }
        status = .checking
        if await Self.cloudflareReachable() {
            guard enabled else { return }
            context.requireEncryptedNameResolution(true, fallbackResolver: Self.resolver)
            status = .active
        } else {
            context.requireEncryptedNameResolution(false, fallbackResolver: nil)
            status = .unavailable
        }
    }

    /// Cloudflare's resolver answers over HTTPS at its IP address, so this
    /// needs no DNS at all.
    nonisolated static func cloudflareReachable() async -> Bool {
        // Testing aid: FOLIO_DNS_PROBE_URL points the check somewhere else.
        let probe = ProcessInfo.processInfo.environment["FOLIO_DNS_PROBE_URL"]
            ?? "https://1.1.1.1/dns-query?name=openlibrary.org&type=A"
        var request = URLRequest(url: URL(string: probe)!)
        request.timeoutInterval = 5
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["Status"] as? Int == 0 else { return false }
        return true
    }
}
