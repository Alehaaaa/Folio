// Compiled alongside the UNMODIFIED production DownloadQueue.swift.
// All network traffic uses a Python localhost fixture; store is an isolated temp directory.
import Foundation

enum SourceEvent { case status(String), log(String) }

enum BookLanguage {
    static func code(_ raw: String?) -> String? { raw?.lowercased() == "es" ? "es" : nil }
    static var preferred: String { "es" }
    static func matches(_ raw: String?, expected: String) -> Bool? {
        guard let raw else { return nil }
        return raw == expected
    }
}

enum BookMatch {
    static func key(author: String, title: String) -> String { author.lowercased() + "|" + title.lowercased() }
}
enum BookAutoMatch {
    static func words(_ value: String) -> [String] {
        value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
    static func sameTitle(_ expected: String, _ actual: String) -> Bool {
        expected.localizedCaseInsensitiveCompare(actual) == .orderedSame
    }
    static func sameEditionAuthor(_ expected: String, _ actual: String) -> Bool {
        expected.localizedCaseInsensitiveCompare(actual) == .orderedSame
    }
}

@MainActor final class HardcoverClient {
    static let shared = HardcoverClient()
    struct Edition { let title: String? }
    func edition(bookID: Int, language code: String) async throws -> Edition? {
        code == "es" && bookID == 42 ? Edition(title: "Aleación de ley") : nil
    }
}

enum AutomaticEPUBChoice {
    static func sameTitle(_ a: String, _ b: String) -> Bool { a == b }
    static func sameAuthor(_ a: String, _ b: String) -> Bool { a == b }
    static func ranked(_ copies: [ExtensionStore.Copy], title: String, author: String,
                       expectedLanguage: String) -> [ExtensionStore.Copy] {
        copies.filter { sameTitle($0.result.title, title) && sameAuthor($0.result.author, author) &&
            BookLanguage.matches($0.result.language, expected: expectedLanguage) != false }
    }
}

struct SourceDownload { let format: String; let url: URL }
struct SourceResult {
    let id: String
    let title: String
    let author: String
    let language: String?
    let downloadCount: Int?
    let preferred: SourceDownload?
}
struct TestBook {
    let id: UUID
    let title: String
    let author: String
    let format: TestFormat
    var language: String?
    var hardcoverBookID: Int? = nil
    var hardcoverPages: Int? = nil
}
enum TestFormat { case epub }

@MainActor final class LibraryStore {
    static let shared = LibraryStore()
    let baseDir: URL
    var books: [TestBook] = []
    private init() {
        let path = ProcessInfo.processInfo.environment["FOLIO_DATA_DIR"]!
        baseDir = URL(fileURLWithPath: path, isDirectory: true)
        try! FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }
    func extractedURL(_ book: TestBook) -> URL { baseDir.appendingPathComponent(book.id.uuidString) }
    func book(_ id: UUID) -> TestBook? { books.first { $0.id == id } }
    func remove(_ id: UUID) { books.removeAll { $0.id == id } }
    func update(_ id: UUID, _ work: (inout TestBook) -> Void) {
        if let i = books.firstIndex(where: { $0.id == id }) { work(&books[i]) }
    }
}
struct EPUBPackage {
    let title: String
    let author: String
    let language: String?
    static func load(root: URL) throws -> EPUBPackage {
        let file = root.appendingPathComponent("metadata.txt")
        let values = try String(contentsOf: file, encoding: .utf8).split(separator: "|")
        return EPUBPackage(title: String(values[0]), author: String(values[1]), language: String(values[2]))
    }
}

@MainActor final class ExtensionStore {
    static let shared = ExtensionStore()
    struct Copy {
        let sourceID: String
        let sourceName: String
        let result: SourceResult
        var id: String { sourceID + "|" + result.id }
    }
    var servedURL: URL!
    func loadAll() async {}
    func makeJobSession() -> JobSession { JobSession(owner: self) }

    @MainActor final class JobSession {
        let owner: ExtensionStore
        init(owner: ExtensionStore) { self.owner = owner }
        func close() async {}
        func findCopies(title: String, author: String, expectedLanguage: String? = nil,
                        progress: @escaping (String) -> Void = { _ in },
                        onEvent: @escaping (String, SourceEvent) -> Void = { _,_ in }) async
                        -> (copies: [Copy], problems: [String]) {
            progress("Local test fixture")
            // The Spanish edition is only discoverable by its localized title;
            // searching the original English title must produce no matches.
            if title == "The Alloy of Law" { return ([], []) }
            let result = SourceResult(id: title, title: title, author: author, language: "es",
                                      downloadCount: nil, preferred: SourceDownload(format: "epub", url: owner.servedURL))
            return ([Copy(sourceID: "local", sourceName: "Local test fixture", result: result)], [])
        }
        func download(_ result: SourceResult, from id: String, into library: LibraryStore,
                      onEvent: @escaping (SourceEvent) -> Void = { _ in }) async throws -> UUID {
            let endpoint = owner.servedURL.appendingPathComponent(result.title == "Slow Cancel" ? "slow" : "flaky")
            onEvent(.status("Downloading from local HTTP fixture"))
            let (_, response) = try await URLSession.shared.data(from: endpoint)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw NSError(domain: "Local fixture HTTP 503", code: 503)
            }
            try Task.checkCancellation()
            let id = UUID()
            let folder = library.baseDir.appendingPathComponent(id.uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "\(result.title)|\(result.author)|es".write(to: folder.appendingPathComponent("metadata.txt"), atomically: true, encoding: .utf8)
            library.books.append(TestBook(id: id, title: result.title, author: result.author, format: .epub, language: "es"))
            return id
        }
    }
}

@main struct QueueActionsTest {
    @MainActor static func main() async throws {
        let root = LibraryStore.shared.baseDir
        let queue = DownloadQueue.shared
        let base = URL(string: ProcessInfo.processInfo.environment["FOLIO_FIXTURE_URL"]!)!
        ExtensionStore.shared.servedURL = base
        let slow = queue.enqueue(title: "Slow Cancel", author: "Autor clásico", expectedLanguage: "es")
        // The test server writes this marker upon receiving the request.
        let slowMarker = root.appendingPathComponent("slow-started")
        let start = Date()
        while !FileManager.default.fileExists(atPath: slowMarker.path) && Date().timeIntervalSince(start) < 12 {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard FileManager.default.fileExists(atPath: slowMarker.path) else { fatalError("Slow transfer did not start") }
        let cancelStart = Date()
        queue.cancel(slow)
        guard queue.jobs.first(where: { $0.id == slow })?.stage == .cancelled else { fatalError("cancel() did not mark stage cancelled") }
        let disconnected = root.appendingPathComponent("slow-disconnected")
        let disconnectStart = Date()
        while !FileManager.default.fileExists(atPath: disconnected.path) && Date().timeIntervalSince(disconnectStart) < 5 {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard FileManager.default.fileExists(atPath: disconnected.path) else {
            fatalError("Cancelled HTTP transfer did not disconnect from fixture server")
        }
        print(String(format: "METRIC: in-flight HTTP disconnect after cancel() %.2fs", Date().timeIntervalSince(cancelStart)))
        let failed = queue.enqueue(title: "Flaky Retry", author: "Autor clásico", expectedLanguage: "es")
        try await wait(queue: queue, id: failed, stage: .failed, timeout: 12)
        guard queue.jobs.first(where: { $0.id == failed })?.error != nil else { fatalError("First HTTP 503 did not fail") }
        queue.retry(failed)
        try await wait(queue: queue, id: failed, stage: .completed, timeout: 12)
        try await Task.sleep(for: .milliseconds(300))
        guard queue.jobs.first(where: { $0.id == slow })?.stage == .cancelled else { fatalError("Cancelled job resumed unexpectedly") }
        guard LibraryStore.shared.books.count == 1, LibraryStore.shared.books[0].title == "Flaky Retry" else {
            fatalError("Cancelled transfer imported a book or successful retry missing")
        }
        let retried = queue.jobs.first { $0.id == failed }!
        guard retried.detailLog.contains(where: { $0.contains("Retry requested") }) else { fatalError("Retry was not logged") }
        let translated = queue.enqueue(title: "The Alloy of Law", author: "Brandon Sanderson",
                                       hardcoverBookID: 42, expectedLanguage: "es")
        try await wait(queue: queue, id: translated, stage: .completed, timeout: 12)
        let translatedLog = queue.jobs.first { $0.id == translated }!.detailLog.joined(separator: "\n")
        guard translatedLog.contains("Edition title in es: Aleación de ley"),
              translatedLog.contains("skipping unrelated original-title search"),
              LibraryStore.shared.books.contains(where: { $0.title == "Aleación de ley" }) else {
            fatalError("Translated target title was not searched or imported")
        }
        let elapsed = Date().timeIntervalSince(cancelStart)
        print("PASS: cancelled real in-flight localhost HTTP transfer; no import; stage stayed cancelled")
        print("PASS: first HTTP 503 failed; retry() requeued and HTTP 200 completed verified import")
        print("PASS: translated Spanish edition found with its localized title, English-title search intentionally empty")
        print("PASS: 2 successful imports, 0 cancelled imports; retry log persisted")
        print(String(format: "METRIC: cancellation through successful retry and validation %.2fs", elapsed))
    }
    @MainActor static func wait(queue: DownloadQueue, id: UUID, stage: DownloadJob.Stage, timeout: TimeInterval) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if queue.jobs.first(where: { $0.id == id })?.stage == stage { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        fatalError("Timed out waiting for \(stage); current \(queue.jobs.first(where: { $0.id == id })?.stage.rawValue ?? "missing")")
    }
}
