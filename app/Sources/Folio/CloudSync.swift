import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

// MARK: - Engine

@Observable
@MainActor
final class FolioCloudSync {
    static let shared = FolioCloudSync()

    /// The deployed sync-worker. Settings can point at another one.
    static let defaultEndpoint = ""

    private static let enabledKey = "folio.cloudSync.enabled"
    private static let codeKey = "folio.cloudSync.code"
    private static let endpointKey = "folio.cloudSync.endpoint"

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { requestSync(after: 0) }
        }
    }
    private(set) var code: String
    var endpoint: String {
        didSet { UserDefaults.standard.set(endpoint, forKey: Self.endpointKey) }
    }

    private(set) var syncing = false
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    /// Other devices on this sync code, newest first.
    private(set) var peers: [(name: String, platform: String, savedAt: Date)] = []
    /// Books updated from another device in the last sync.
    private(set) var lastApplied = 0

    /// Books open in a reader: their position is the reader's until it closes.
    @ObservationIgnored var openBooks: Set<UUID> = []

    @ObservationIgnored private var state: CloudSyncState
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var lastPushed: CloudSyncDeviceDoc?
    @ObservationIgnored private var lastPushAt = Date.distantPast
    @ObservationIgnored private var started = false

    private var stateURL: URL { LibraryStore.shared.baseDir.appendingPathComponent("sync-state.json") }

    private init() {
        let env = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        endpoint = env["FOLIO_SYNC_ENDPOINT"] ?? defaults.string(forKey: Self.endpointKey) ?? Self.defaultEndpoint
        if let c = env["FOLIO_SYNC_CODE"].flatMap(CloudSyncMerge.normalizedCode) {
            code = c
        } else if let c = defaults.string(forKey: Self.codeKey), !c.isEmpty {
            code = c
        } else {
            let fresh = CloudSyncMerge.newCode()
            defaults.set(fresh, forKey: Self.codeKey)
            code = fresh
        }
        isEnabled = env["FOLIO_SYNC_CODE"] != nil || defaults.bool(forKey: Self.enabledKey)
        state = CloudSyncState()
        if let raw = try? Data(contentsOf: stateURL),
           let saved = try? JSONDecoder.folioSync.decode(CloudSyncState.self, from: raw) {
            state = saved
        } else {
            saveState()
        }
    }

    var deviceID: String { state.deviceID }

    /// Starts syncing for the life of the app: now, after library changes,
    /// and every minute while the app is in use.
    func start() {
        guard !started else { return }
        started = true
        LibraryStore.didSave = { [weak self] in self?.libraryChanged() }
        requestSync(after: 0)
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await self?.syncNow()
            }
        }
    }

    /// Joins another device's sync code; this device's books merge into it.
    func join(_ raw: String) -> Bool {
        guard let c = CloudSyncMerge.normalizedCode(raw) else { return false }
        code = c
        UserDefaults.standard.set(c, forKey: Self.codeKey)
        lastPushed = nil
        peers = []
        isEnabled = true
        requestSync(after: 0)
        return true
    }

    /// Leaves the shared code for a fresh one of this device's own.
    func resetCode() {
        code = CloudSyncMerge.newCode()
        UserDefaults.standard.set(code, forKey: Self.codeKey)
        lastPushed = nil
        peers = []
        requestSync(after: 0)
    }

    /// Reading saves every page turn: those changes go out at most every 20 seconds.
    private func libraryChanged() {
        guard isEnabled, pending == nil else { return }
        let wait = max(2, 20 - Date().timeIntervalSince(lastPushAt))
        requestSync(after: wait)
    }

    func requestSync(after seconds: Double) {
        pending?.cancel()
        pending = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            self?.pending = nil
            await self?.syncNow()
        }
    }

    func readerOpened(_ id: UUID) { openBooks.insert(id) }

    func readerClosed(_ id: UUID) {
        openBooks.remove(id)
        requestSync(after: 1)
    }

    // MARK: One round

    func syncNow() async {
        guard isEnabled, !syncing, let base = URL(string: endpoint), base.scheme?.hasPrefix("http") == true else { return }
        syncing = true
        defer { syncing = false }
        let store = LibraryStore.shared
        let url = base.appendingPathComponent("v1").appendingPathComponent(code)
        do {
            let channel = try await Self.fetch(url)
            let local = CloudSyncMerge.stamp(store.books.map { ($0.id, Self.record($0, store)) }, state: &state, now: Date())
            let peerDocs = channel.devices.filter { $0.key != state.deviceID }.map(\.value)
            let changes = CloudSyncMerge.incoming(local: local, peers: peerDocs, skipping: openBooks)
            var applied = 0
            for (id, change) in changes {
                apply(change, to: id, store: store)
                if change.record != nil { applied += 1 }
                if let b = store.book(id) {
                    // Record the applied state with the other device's time,
                    // so it isn't taken for a new change here.
                    let r = Self.record(b, store)
                    state.stamps[id] = .init(fingerprint: r.fingerprint, updatedAt: change.record?.updatedAt ?? state.stamps[id]?.updatedAt ?? CloudSyncMerge.wire(Date()))
                }
            }
            if !changes.isEmpty { store.save() }
            lastApplied = applied

            let mine = CloudSyncDeviceDoc(
                deviceName: Self.deviceName,
                platform: Self.platform,
                savedAt: CloudSyncMerge.wire(Date()),
                books: store.books.compactMap { b in
                    guard Self.worthSyncing(b), let stamp = state.stamps[b.id] else { return nil }
                    var r = Self.record(b, store)
                    r.updatedAt = stamp.updatedAt
                    return r
                }.sorted { $0.updatedAt > $1.updatedAt }
            )
            // Push when this device's entry on the server differs: after a
            // change here, or when another device's write replaced it.
            if !(channel.devices[state.deviceID].map { $0.sameContent(as: mine) } ?? false) {
                try await Self.put(mine, to: url.appendingPathComponent(state.deviceID))
                lastPushed = mine
                lastPushAt = Date()
            }
            peers = channel.devices.filter { $0.key != state.deviceID }
                .map { (name: $0.value.deviceName, platform: $0.value.platform, savedAt: $0.value.savedAt) }
                .sorted { $0.savedAt > $1.savedAt }
            saveState()
            lastSync = Date()
            lastError = nil
            if applied > 0 { FolioLog.log("Folio Sync: updated \(applied) book(s) from another device", "sync") }
        } catch {
            lastError = error.localizedDescription
            FolioLog.log("Folio Sync failed: \(error.localizedDescription)", "sync")
        }
    }

    private func apply(_ change: CloudSyncMerge.Incoming, to id: UUID, store: LibraryStore) {
        var collectionIDs: [String: UUID] = [:]
        if let r = change.record {
            for name in r.collections {
                if let c = store.data.collections.first(where: { $0.name == name }) {
                    collectionIDs[name] = c.id
                } else {
                    let c = BookCollection(name: name)
                    store.data.collections.append(c)
                    collectionIDs[name] = c.id
                }
            }
        }
        guard let i = store.data.books.firstIndex(where: { $0.id == id }) else { return }
        if let r = change.record {
            var b = store.data.books[i]
            b.progress = r.progress
            b.position = ReadingPosition(chapter: r.chapter, fraction: r.fraction, pdfPage: r.pdfPage)
            b.status = ReadingStatus(rawValue: r.status) ?? b.status
            b.finishedAt = r.finishedAt
            b.collections = Set(r.collections.compactMap { collectionIDs[$0] })
            if let opened = r.lastOpenedAt, opened > (b.lastOpenedAt ?? .distantPast) { b.lastOpenedAt = opened }
            store.data.books[i] = b
        }
        if let opened = change.lastOpenedAt, opened > (store.data.books[i].lastOpenedAt ?? .distantPast) {
            store.data.books[i].lastOpenedAt = opened
        }
    }

    // MARK: Books ↔ records

    static func worthSyncing(_ b: LocalBook) -> Bool {
        b.progress > 0 || b.status != .none || !b.collections.isEmpty || b.lastOpenedAt != nil
    }

    static func keys(_ b: LocalBook) -> [String] {
        var keys: [String] = []
        if let id = b.hardcoverBookID { keys.append("hc:\(id)") }
        if let isbn = b.isbn?.filter({ $0.isNumber || $0 == "X" }), !isbn.isEmpty { keys.append("isbn:\(isbn)") }
        let t = BookMatch.key(author: b.author, title: b.title)
        if !t.isEmpty { keys.append("t:\(t)") }
        return keys
    }

    static func record(_ b: LocalBook, _ store: LibraryStore) -> CloudSyncRecord {
        let names = store.data.collections.filter { b.collections.contains($0.id) }.map(\.name).sorted()
        return CloudSyncRecord(
            keys: keys(b), title: b.title, author: b.author,
            progress: b.progress, chapter: b.position.chapter, fraction: b.position.fraction, pdfPage: b.position.pdfPage,
            status: b.status.rawValue,
            finishedAt: b.finishedAt.map(CloudSyncMerge.wire),
            lastOpenedAt: b.lastOpenedAt.map(CloudSyncMerge.wire),
            collections: names, updatedAt: .distantPast
        )
    }

    private func saveState() {
        if let raw = try? JSONEncoder.folioSync.encode(state) { try? raw.write(to: stateURL, options: .atomic) }
    }

    // MARK: HTTP

    struct ServerError: LocalizedError {
        let status: Int
        var errorDescription: String? {
            status == 413 ? "The library is too large to sync." : "The sync server answered \(status)."
        }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    nonisolated static func fetch(_ url: URL) async throws -> CloudSyncChannel {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return CloudSyncChannel() }
        guard status == 200 else { throw ServerError(status: status) }
        return try JSONDecoder.folioSync.decode(CloudSyncChannel.self, from: data)
    }

    nonisolated static func put(_ doc: CloudSyncDeviceDoc, to url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder.folioSync.encode(doc)
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw ServerError(status: status) }
    }

    static var platform: String {
        #if os(macOS)
        "mac"
        #else
        ProcessInfo.processInfo.isiOSAppOnMac ? "mac" : (deviceModel.hasPrefix("iPad") ? "ipad" : "iphone")
        #endif
    }

    static var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        deviceModel
        #endif
    }

    #if os(iOS)
    static var deviceModel: String { UIDevice.current.model }
    #endif
}
