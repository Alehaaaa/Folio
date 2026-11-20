import Foundation
import AppKit

// Small isolated fixture runner. Compile it with the real EPUB parser and writer;
// never open or modify the user's Folio library.
struct HCBook {
    var id: Int
    var title: String
    var authors: String
    var description: String?
    var year: Int?
}

extension String {
    var plainText: String { self }
}

@main
struct Check {
    static func main() throws {
        let fm = FileManager.default
        let examples = CommandLine.arguments.dropFirst()
        guard !examples.isEmpty else { fatalError("Supply EPUB test fixtures") }

        let image = NSImage(size: NSSize(width: 120, height: 180))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: 120, height: 180).fill()
        image.unlockFocus()
        guard let png = CoverMaker.pngData(image) else { fatalError("Cannot generate sample cover") }

        for path in examples {
            let temp = fm.temporaryDirectory.appendingPathComponent("folio-epub-check-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: temp) }
            let extracted = temp.appendingPathComponent("Extracted")
            let archived = temp.appendingPathComponent("updated.epub")
            let checked = temp.appendingPathComponent("Checked")
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            try Unzip.extract(URL(fileURLWithPath: path), to: extracted)
            let previous = try EPUBPackage.load(root: extracted)
            let details = HCBook(id: 117, title: "Test & <new> \"title\"", authors: "Author & Co.",
                                 description: "A new description with <escaped> elements & symbols", year: 2026)
            try EPUBHardcoverEnricher.apply(in: extracted, book: details, coverData: png)
            try EPUBHardcoverEnricher.apply(in: extracted, book: details, coverData: png)
            try Unzip.packageEPUBFolder(extracted, to: archived)
            try Unzip.extract(archived, to: checked)
            let actual = try EPUBPackage.load(root: checked)
            guard actual.title == details.title, actual.author == details.authors,
                  actual.content.chapters.count == previous.content.chapters.count,
                  let imagePath = actual.coverURL, NSImage(contentsOf: imagePath) != nil else {
                fatalError("Enriched EPUB validation failed for \(path)")
            }
            print("PASS \(URL(fileURLWithPath: path).lastPathComponent): \(actual.title), \(actual.content.chapters.count) chapters, embedded cover")
        }
    }
}
