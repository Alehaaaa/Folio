import SwiftUI
import UIKit
import Observation

/// Checks the AltStore source that CI publishes on every push to main. When a newer
/// build exists, its IPA downloads in the background; tapping Update opens the share
/// sheet with that file so it can be sent to LiveContainer (or AltStore/SideStore),
/// which offers to replace the installed Folio.
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
        var fileName: String { "Folio-\(version)-\(build).ipa" }
    }

    enum Status: Equatable {
        case idle, checking, upToDate, failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var latest: Release?
    /// The IPA of `latest`, once its background download finishes.
    private(set) var downloadedFile: URL?
    /// True while Update waits for the download before opening the share sheet.
    private(set) var preparing = false
    /// Set when a check finds a newer build; drives the update alert.
    var offered: Release?
    var notice: String?

    @ObservationIgnored private var download: Task<URL, Error>?
    @ObservationIgnored private var downloadID: String?

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
                startDownload(release)
                if manual || release.id != skippedID { offered = release }
            } else {
                status = .upToDate
                Self.removeDownloads()
            }
        } catch {
            status = .failed("Couldn't reach the update source.")
        }
    }

    func skip(_ release: Release) {
        skippedID = release.id
        offered = nil
    }

    /// Opens the share sheet with the downloaded IPA, waiting for the download if needed.
    func install(_ release: Release) {
        offered = nil
        preparing = true
        Task {
            defer { preparing = false }
            do {
                let file = try await startDownload(release).value
                // Let the update alert finish dismissing before presenting over it.
                try? await Task.sleep(for: .milliseconds(450))
                Self.presentShareSheet(for: file)
            } catch {
                show("Couldn't download Folio \(release.version). Check your connection and try again.")
            }
        }
    }

    @discardableResult
    private func startDownload(_ release: Release) -> Task<URL, Error> {
        if let download, downloadID == release.id { return download }
        let task = Task<URL, Error> {
            let destination = Self.downloadsFolder.appendingPathComponent(release.fileName)
            if FileManager.default.fileExists(atPath: destination.path) { return destination }
            let (temporary, response) = try await URLSession.shared.download(from: release.downloadURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            Self.removeDownloads()
            try FileManager.default.createDirectory(at: Self.downloadsFolder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        }
        download = task
        downloadID = release.id
        downloadedFile = nil
        Task {
            do {
                let file = try await task.value
                if downloadID == release.id { downloadedFile = file }
            } catch {
                // Forget the failed attempt so the next Update tap retries.
                if downloadID == release.id {
                    download = nil
                    downloadID = nil
                }
            }
        }
        return task
    }

    private func show(_ message: String) {
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            notice = message
        }
    }

    // MARK: Files

    private static var downloadsFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FolioUpdates", isDirectory: true)
    }

    private static func removeDownloads() {
        try? FileManager.default.removeItem(at: downloadsFolder)
    }

    private static func presentShareSheet(for file: URL) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first,
              var top = window.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(sheet, animated: true)
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
                Button("OK", role: .cancel) {}
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
                if updates.status == .checking || updates.preparing {
                    ProgressView()
                } else {
                    switch updates.status {
                    case .upToDate: Text("Up to date")
                    case .failed(let message): Text(message)
                    default:
                        if updates.updateAvailable, let latest = updates.latest {
                            Text(latest.version)
                        }
                    }
                }
            }
        }
        .disabled(updates.status == .checking || updates.preparing)
    }
}
