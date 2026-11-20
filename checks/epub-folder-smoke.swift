import Foundation

@main
struct EPUBFolderSmoke {
    static func main() throws {
        guard (3...4).contains(CommandLine.arguments.count) else {
            fatalError("Usage: epub-folder-smoke <expanded.epub folder> <new output.epub> [expected ISBN]")
        }
        let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        guard !FileManager.default.fileExists(atPath: output.path) else {
            fatalError("Refusing to overwrite existing EPUB: \(output.path)")
        }
        let unpacked = FileManager.default.temporaryDirectory.appendingPathComponent("folio-epub-smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: unpacked) }

        let original = try EPUBPackage.load(root: source)
        if CommandLine.arguments.count == 4 {
            assert(original.isbn == CommandLine.arguments[3], "Incorrect EPUB ISBN extraction")
        }
        try Unzip.packageEPUBFolder(source, to: output)
        try Unzip.extract(output, to: unpacked)
        let package = try EPUBPackage.load(root: unpacked)
        assert(package.isbn == original.isbn, "Packaging changed EPUB identifiers")
        assert(package.title == original.title, "Packaging changed EPUB title")
        guard !package.content.chapters.isEmpty else {
            throw NSError(domain: "FolioTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "EPUB has no readable chapters"])
        }
        print("PASS: packaged, extracted, and parsed EPUB with \(package.content.chapters.count) readable chapters")
        print("Output: \(output.path)")
    }
}
