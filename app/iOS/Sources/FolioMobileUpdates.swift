import SwiftUI
import UIKit
import Observation

/// Checks the AltStore source that CI publishes on every push to main and hands a
/// newer IPA to whatever installed Folio.
///
/// LiveContainer installs from `livecontainer://install?url=<ipa>`, but only while
/// its own UI is running:
/// - Multitask mode (Folio runs in a LiveProcess, `LP_HOME_PATH` is set): the URL
///   reaches the LiveContainer app, which downloads the IPA and offers to replace Folio.
/// - Classic mode (Folio occupies the LiveContainer process): LiveContainer answers
///   "Please restart LiveContainer to install apps", so Folio copies the IPA link and
///   switches back to LiveContainer's app list instead.
@MainActor
@Observable
final class FolioUpdateChecker {
    static let shared = FolioUpdateChecker()

    static let sourceURL = URL(string: "https://raw.githubusercontent.com/Alehaaaa/Folio/main/altstore.json")!
    static let bundleID = "app.folio.reader.ios"

    struct Release: Equatable, Identifiable {
        let version: String
        let build: String
        let notes: String
        let downloadURL: URL
        var id: String { "\(version)-\(build)" }
    }

    enum Host {
        /// LiveContainer running Folio in its own process (classic mode).
        case liveContainerClassic
        /// LiveContainer running Folio in a separate LiveProcess (multitask mode).
        case liveContainerMultitask
        /// Installed directly (AltStore, SideStore, Xcode).
        case standalone
    }

    enum Status: Equatable {
        case idle, checking, upToDate, failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var latest: Release?
    /// Set when a check finds a newer build; drives the launch alert.
    var offered: Release?
    var notice: String?

    private var lastCheck: Double {
        get { UserDefaults.standard.double(forKey: "folioIOS.updates.lastCheck") }
        set { UserDefaults.standard.set(newValue, forKey: "folioIOS.updates.lastCheck") }
    }
    private var skippedID: String {
        get { UserDefaults.standard.string(forKey: "folioIOS.updates.skipped") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "folioIOS.updates.skipped") }
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }
    static var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    static var host: Host {
        let env = ProcessInfo.processInfo.environment
        if env["LP_HOME_PATH"] != nil { return .liveContainerMultitask }
        if env["LC_HOME_PATH"] != nil { return .liveContainerClassic }
        return .standalone
    }

    var updateAvailable: Bool {
        guard let latest else { return false }
        return Self.isNewer(latest, thanVersion: Self.currentVersion, build: Self.currentBuild)
    }

    /// Launch check: at most every 6 hours, and never re-offers a skipped build.
    func checkOnLaunch() async {
        guard Date().timeIntervalSince1970 - lastCheck > 6 * 3600 else { return }
        await check(manual: false)
    }

    func check(manual: Bool) async {
        guard status != .checking else { return }
        status = .checking
        do {
            let release = try await Self.fetchLatest()
            lastCheck = Date().timeIntervalSince1970
            latest = release
            if updateAvailable, let release {
                status = .idle
                if manual || release.id != skippedID { offered = release }
            } else {
                status = .upToDate
            }
        } catch {
            status = .failed("Couldn't reach the update source.")
        }
    }

    func skip(_ release: Release) {
        skippedID = release.id
        offered = nil
    }

    func install(_ release: Release) {
        offered = nil
        switch Self.host {
        case .liveContainerMultitask:
            open(Self.liveContainerInstallURL(release.downloadURL)) { [weak self] ok in
                self?.show(ok
                    ? "LiveContainer is installing Folio \(release.version). Choose to replace the current Folio, then reopen it."
                    : "Couldn't open LiveContainer. The download link was copied.")
                if !ok { UIPasteboard.general.url = release.downloadURL }
            }
        case .liveContainerClassic:
            // LiveContainer refuses installs while a guest app owns its process, so
            // relaunch into its app list with the IPA link ready to paste.
            UIPasteboard.general.url = release.downloadURL
            show("The download link is copied. In LiveContainer tap +, choose Install from URL, paste it, and replace Folio.")
        case .standalone:
            var components = URLComponents(string: "altstore://install")!
            components.queryItems = [URLQueryItem(name: "url", value: release.downloadURL.absoluteString)]
            open(components.url!) { [weak self] ok in
                if !ok {
                    UIPasteboard.general.url = release.downloadURL
                    self?.show("The download link for Folio \(release.version) was copied.")
                }
            }
        }
    }

    /// Waits for the update alert to finish dismissing before presenting the next one.
    private func show(_ message: String) {
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            notice = message
        }
    }

    /// Classic mode only: leaves Folio for LiveContainer's own app list.
    func openLiveContainer() {
        notice = nil
        open(URL(string: "livecontainer://livecontainer-launch?bundle-name=ui")!) { _ in }
    }

    private func open(_ url: URL, completion: @escaping (Bool) -> Void) {
        UIApplication.shared.open(url, options: [:]) { ok in
            Task { @MainActor in completion(ok) }
        }
    }

    static func liveContainerInstallURL(_ ipa: URL) -> URL {
        var components = URLComponents(string: "livecontainer://install")!
        components.queryItems = [URLQueryItem(name: "url", value: ipa.absoluteString)]
        return components.url!
    }

    // MARK: Source

    private struct Source: Decodable {
        struct App: Decodable {
            let bundleIdentifier: String
            let versions: [Version]?
        }
        struct Version: Decodable {
            let version: String
            let buildVersion: String?
            let localizedDescription: String?
            let downloadURL: URL
        }
        let apps: [App]
    }

    static func fetchLatest() async throws -> Release? {
        var request = URLRequest(url: sourceURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let source = try JSONDecoder().decode(Source.self, from: data)
        let releases = (source.apps.first { $0.bundleIdentifier == bundleID }?.versions ?? []).map {
            Release(version: $0.version, build: $0.buildVersion ?? "0",
                    notes: $0.localizedDescription ?? "", downloadURL: $0.downloadURL)
        }
        return releases.max { isNewer($1, thanVersion: $0.version, build: $0.build) }
    }

    static func isNewer(_ release: Release, thanVersion version: String, build: String) -> Bool {
        let order = compare(release.version, version)
        if order != .orderedSame { return order == .orderedDescending }
        return compare(release.build, build) == .orderedDescending
    }

    private static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let lhs = a.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

// MARK: - UI

private struct FolioUpdatePrompt: ViewModifier {
    @State private var updates = FolioUpdateChecker.shared

    func body(content: Content) -> some View {
        content
            .task { await updates.checkOnLaunch() }
            .alert(
                "Folio \(updates.offered?.version ?? "") is available",
                isPresented: Binding(
                    get: { updates.offered != nil },
                    set: { if !$0 { updates.offered = nil } }
                ),
                presenting: updates.offered
            ) { release in
                Button("Update") { updates.install(release) }
                Button("Skip This Version") { updates.skip(release) }
                Button("Later", role: .cancel) {}
            } message: { release in
                Text(release.notes)
            }
            .alert(
                "Update",
                isPresented: Binding(
                    get: { updates.notice != nil },
                    set: { if !$0 { updates.notice = nil } }
                )
            ) {
                if FolioUpdateChecker.host == .liveContainerClassic {
                    Button("Open LiveContainer") { updates.openLiveContainer() }
                    Button("Cancel", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: {
                Text(updates.notice ?? "")
            }
    }
}

extension View {
    /// Checks for a newer Folio build on launch and offers to install it.
    func folioUpdatePrompt() -> some View { modifier(FolioUpdatePrompt()) }
}

/// "Check for Updates" row for the About section.
struct FolioUpdateRow: View {
    @State private var updates = FolioUpdateChecker.shared

    var body: some View {
        Button {
            if updates.updateAvailable, let latest = updates.latest {
                updates.offered = latest
            } else {
                Task { await updates.check(manual: true) }
            }
        } label: {
            LabeledContent("Check for Updates") {
                switch updates.status {
                case .checking: ProgressView()
                case .upToDate: Text("Up to date")
                case .failed(let message): Text(message)
                case .idle:
                    if updates.updateAvailable, let latest = updates.latest {
                        Text(latest.version)
                    }
                }
            }
        }
        .disabled(updates.status == .checking)
    }
}
