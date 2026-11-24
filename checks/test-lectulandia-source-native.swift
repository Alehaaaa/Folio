// Run via checks/test-lectulandia-source-native.sh.
// Uses the actual Folio SourceRuntime/URLSession and JavaScriptCore on macOS.
// Public-domain Don Quijote catalogue probes only, no EPUB file transfers.
import Foundation

enum BookLanguage {
    static func code(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return String(raw.trimmingCharacters(in: .whitespaces).lowercased().prefix(2))
    }
    static func displayName(_ code: String) -> String { code == "es" ? "Spanish" : code }
}

@MainActor
final class HardcoverClient {
    static let shared = HardcoverClient()
    var isConnected: Bool { false }
    struct DummyQuery { let anyValue: [String: Any] = [:] }
    func query(_ query: String, _ variables: [String: Any]) async throws -> DummyQuery? { nil }
}

@MainActor
final class LibraryStore {
    static let shared = LibraryStore()
    let baseDir = FileManager.default.temporaryDirectory.appendingPathComponent(
        "folio-lectulandia-native-\(UUID().uuidString)", isDirectory: true)
    func importBook(_ file: URL, author: String? = nil) async throws -> UUID {
        throw ExtensionError(message: "Native source smoke never imports library books")
    }
}

enum Names {
    static func split(_ value: String) -> [String] { [value] }
}

enum DefaultSources {
    static let builtIn: [(id: String, script: String)] = []
}

@main
struct LectulandiaNativeTest {
    static func main() async throws {
        guard CommandLine.arguments.count >= 2 else {
            fatalError("Missing Lectulandia source script file")
        }
        let sourceScript = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let main = "https://ww3.lectulandia.com"
        let other = "https://ww3.lectulandia.co"
        let runtime = SourceRuntime(script: sourceScript, label: "lectulandia.native")
        let manifest = try await runtime.manifest()
        guard manifest.id == "lectulandia", manifest.canSearch, manifest.canPrepareDownload,
              manifest.languages == ["es"],
              manifest.fixedHosts.contains("https://assets.lectulandia.co"),
              runtime.isAllowed(URL(string: "\(main)/book/don-quijote-de-la-mancha/")!),
              runtime.isAllowed(URL(string: "\(other)/book/don-quijote-de-la-mancha/")!),
              !runtime.isAllowed(URL(string: "https://untrusted.invalid/book/")!) else {
            fatalError("Lectulandia native manifest, Spanish routing or host restrictions failed")
        }
        let rejected = try await runtime.invoke("search", ["Don Quijote de la Mancha", 0, "en", "", ""])
        guard let skipped = rejected as? [Any], skipped.isEmpty else {
            fatalError("Native runtime contacted Spanish-only source for English request")
        }
        print("PASS native JavaScriptCore manifest, approved hosts and Spanish language routing")

        let started = Date()
        var events: [String] = []
        let payload = try await runtime.invoke("search", ["Don Quijote de la Mancha cervantes", 0,
                                        "es", "Don Quijote de la Mancha", "Miguel de Cervantes"],
                                        onEvent: { event in
            switch event {
            case let .status(value), let .log(value): events.append(value)
            }
        })
        let books = (payload as? [Any] ?? []).compactMap(SourceResult.from)
        guard !books.isEmpty,
              books.contains(where: { $0.title == "Don Quijote de la Mancha" && $0.author.contains("Cervantes") }),
              books.allSatisfy({ $0.language == "es" && $0.title.contains("Don Quijote de la Mancha")
                  && $0.author.contains("Cervantes") && $0.cover?.scheme == "https"
                  && $0.preferred?.format == "epub" && $0.downloads.count == 4
                  && $0.downloads.allSatisfy { $0.url.absoluteString.hasPrefix(main + "/") ||
                                               $0.url.absoluteString.hasPrefix(other + "/") } }) else {
            fatalError("Native real catalogue metadata mismatch: \(books.map(\.title)); events=\(events)")
        }
        print("PASS native JavaScriptCore: exact Don Quijote selected among \(books.count) editions (\(books.map(\.title))); matching author, covers, Spanish EPUB and verified mirror links; \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        await runtime.close()
    }
}
