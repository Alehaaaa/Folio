import Foundation
import Network
import Observation

/// Optional encrypted DNS for everything Folio fetches itself (book details,
/// covers, sources and downloads), through a DNS over HTTPS provider set on
/// the system's own privacy context, so URLSession requests resolve names over
/// HTTPS instead of plain DNS. Pages inside the in-app browser (WebKit) keep
/// the device's DNS.
///
/// Folio only keeps it on after the provider answers a test lookup; when that
/// fails it goes back to the network's own DNS instead of breaking every request.
@Observable
@MainActor
final class FolioEncryptedDNS {
    static let shared = FolioEncryptedDNS()
    static let key = "folio.network.encryptedDNS"
    static let providerKey = "folio.network.encryptedDNS.provider"
    static let nextDNSKey = "folio.network.encryptedDNS.nextdnsID"
    static let customKey = "folio.network.encryptedDNS.customURL"

    enum Provider: String, CaseIterable, Identifiable, Sendable {
        case cloudflare, google, quad9, adguard, mullvad, nextdns, custom
        var id: String { rawValue }

        var label: String {
            switch self {
            case .cloudflare: "Cloudflare"
            case .google: "Google"
            case .quad9: "Quad9"
            case .adguard: "AdGuard"
            case .mullvad: "Mullvad"
            case .nextdns: "NextDNS"
            case .custom: "Custom"
            }
        }

        /// Fixed DoH endpoint; NextDNS and Custom are built from user input.
        fileprivate var fixedURL: String? {
            switch self {
            case .cloudflare: "https://cloudflare-dns.com/dns-query"
            case .google: "https://dns.google/dns-query"
            case .quad9: "https://dns.quad9.net/dns-query"
            case .adguard: "https://dns.adguard-dns.com/dns-query"
            case .mullvad: "https://dns.mullvad.net/dns-query"
            case .nextdns, .custom: nil
            }
        }

        /// The provider's own addresses, so its name never needs plain DNS.
        fileprivate var serverAddresses: [String] {
            switch self {
            case .cloudflare: ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"]
            case .google: ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"]
            case .quad9: ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"]
            case .adguard: ["94.140.14.14", "94.140.15.15", "2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff"]
            case .mullvad: ["194.242.2.2", "2a07:e340::2"]
            case .nextdns: ["45.90.28.0", "45.90.30.0", "2a07:a8c0::", "2a07:a8c1::"]
            case .custom: []
            }
        }
    }

    enum Status: Equatable {
        case off, checking, active
        /// The provider couldn't be reached; Folio uses the network's DNS.
        case unavailable
        /// NextDNS without a configuration ID, or a custom address that isn't https.
        case needsSetup
    }

    var enabled: Bool {
        didSet { changed(enabled != oldValue, key: Self.key, value: enabled) }
    }
    var provider: Provider {
        didSet { changed(provider != oldValue, key: Self.providerKey, value: provider.rawValue) }
    }
    var nextDNSID: String {
        didSet { changed(nextDNSID != oldValue, key: Self.nextDNSKey, value: nextDNSID) }
    }
    var customURL: String {
        didSet { changed(customURL != oldValue, key: Self.customKey, value: customURL) }
    }
    private(set) var status: Status = .off

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: Self.key)
        provider = Provider(rawValue: defaults.string(forKey: Self.providerKey) ?? "") ?? .cloudflare
        nextDNSID = defaults.string(forKey: Self.nextDNSKey) ?? ""
        customURL = defaults.string(forKey: Self.customKey) ?? ""
    }

    /// One activity-log line saying how source lookups resolve names.
    var logNote: String {
        switch (enabled, status) {
        case (false, _): "Encrypted DNS: off (network DNS)"
        case (true, .active): "Encrypted DNS: \(provider.label), active"
        case (true, .unavailable): "Encrypted DNS: \(provider.label) unreachable; using network DNS"
        case (true, .needsSetup): "Encrypted DNS: \(provider.label) needs setup; using network DNS"
        case (true, _): "Encrypted DNS: \(provider.label), still checking"
        }
    }

    private var pending: Task<Void, Never>?

    private func changed(_ didChange: Bool, key: String, value: Any) {
        guard didChange else { return }
        UserDefaults.standard.set(value, forKey: key)
        // Typing an ID or address changes this on every keystroke; check once it settles.
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await apply()
        }
    }

    /// The DoH endpoint for the current choice, or nil until it is set up.
    var endpoint: URL? { Self.endpoint(provider, nextDNSID: nextDNSID, customURL: customURL) }

    nonisolated static func endpoint(_ provider: Provider, nextDNSID: String, customURL: String) -> URL? {
        switch provider {
        case .nextdns:
            let id = nextDNSID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
            return URL(string: "https://dns.nextdns.io/\(id.lowercased())")
        case .custom:
            var text = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, !text.contains("://") { text = "https://" + text }
            guard let url = URL(string: text), url.scheme?.lowercased() == "https",
                  let host = url.host, !host.isEmpty else { return nil }
            return url
        default:
            return provider.fixedURL.flatMap(URL.init(string:))
        }
    }

    private var resolver: NWParameters.PrivacyContext.ResolverConfiguration? {
        guard let url = endpoint else { return nil }
        return .https(url, serverAddresses: provider.serverAddresses.map { .hostPort(host: .init($0), port: 443) })
    }

    /// The configuration in use since launch. Connections made before a change
    /// keep the old resolver, so a change takes full effect on relaunch.
    private var appliedAtLaunch: String = ""
    private var configuration: String { enabled ? (endpoint?.absoluteString ?? "unset") : "" }

    /// Call once at launch, before the first request. The resolver is set
    /// right away so no connection is made with plain DNS first; the provider
    /// check follows and turns it back off if the provider can't be reached.
    func start() {
        appliedAtLaunch = configuration
        if enabled, let resolver {
            NWParameters.PrivacyContext.default.requireEncryptedNameResolution(true, fallbackResolver: resolver)
            status = .checking
        }
        Task { await apply() }
    }

    /// True when the setting was changed since launch and Folio should restart.
    var needsRelaunch: Bool { configuration != appliedAtLaunch }

    func apply() async {
        let context = NWParameters.PrivacyContext.default
        guard enabled else {
            context.requireEncryptedNameResolution(false, fallbackResolver: nil)
            status = .off
            return
        }
        guard let url = endpoint, let resolver else {
            context.requireEncryptedNameResolution(false, fallbackResolver: nil)
            status = .needsSetup
            return
        }
        let wanted = configuration
        status = .checking
        let reachable = await Self.providerAnswers(url)
        guard enabled, configuration == wanted else { return } // changed meanwhile; a newer check runs
        if reachable {
            context.requireEncryptedNameResolution(true, fallbackResolver: resolver)
            status = .active
        } else {
            context.requireEncryptedNameResolution(false, fallbackResolver: nil)
            status = .unavailable
        }
    }

    /// Sends one real DNS over HTTPS query (RFC 8484 wire format, which every
    /// provider supports) and checks that a proper answer comes back.
    nonisolated static func providerAnswers(_ endpoint: URL) async -> Bool {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return false }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "dns", value: probeQuery)]
        guard let url = components.url else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return isAnswer(data)
    }

    /// An A query for openlibrary.org with ID 0, base64url without padding.
    nonisolated static var probeQuery: String {
        var bytes: [UInt8] = [0, 0, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in ["openlibrary", "org"] {
            bytes.append(UInt8(label.utf8.count))
            bytes.append(contentsOf: label.utf8)
        }
        bytes += [0, 0, 1, 0, 1]
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// A DNS response (QR set), no error, and at least one answer record.
    nonisolated static func isAnswer(_ data: Data) -> Bool {
        let b = [UInt8](data)
        guard b.count >= 12, b[2] & 0x80 != 0, b[3] & 0x0F == 0 else { return false }
        return (UInt16(b[6]) << 8 | UInt16(b[7])) > 0
    }
}
