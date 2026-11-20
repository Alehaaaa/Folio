// Standalone EPUBPackage language regression probe. It compiles the app's actual
// EPUB.swift + BookAutoMatch.swift without building or launching Folio.
//
// From /books:
//   swiftc app/Sources/Folio/EPUB.swift app/Sources/Folio/BookAutoMatch.swift \
//     checks/test-epub-language.swift -o /tmp/folio-language-probe
//   /tmp/folio-language-probe
//
// An optional first argument is a pre-extracted, existing EPUB directory to
// inspect read-only; no file in that directory is created or modified.

import Foundation

@main
struct EPUBLanguageChecks {
    private static func verify(_ actual: String?, expected: String?, label: String) {
        guard actual == expected else {
            fatalError("\(label): expected \(expected ?? "nil"), got \(actual ?? "nil")")
        }
        print("PASS \(label): \(actual ?? "nil")")
    }

    private static func synthetic(_ languages: String, in temp: URL, name: String) throws -> EPUBPackage {
        let root = temp.appendingPathComponent(name, isDirectory: true)
        let meta = root.appendingPathComponent("META-INF", isDirectory: true)
        let ops = root.appendingPathComponent("OPS", isDirectory: true)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ops, withIntermediateDirectories: true)
        let container = """
        <?xml version="1.0" encoding="utf-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """
        let opf = """
        <?xml version="1.0" encoding="utf-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:custom="urn:other:metadata" version="3.0">
          <metadata>
            <dc:title>Synthetic EPUB</dc:title>
            <dc:creator>Example Author</dc:creator>
            \(languages)
          </metadata>
          <manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
          <spine><itemref idref="chapter"/></spine>
        </package>
        """
        try container.write(to: meta.appendingPathComponent("container.xml"), atomically: true, encoding: .utf8)
        try opf.write(to: ops.appendingPathComponent("package.opf"), atomically: true, encoding: .utf8)
        try "<html><body>Sample</body></html>".write(to: ops.appendingPathComponent("chapter.xhtml"), atomically: true, encoding: .utf8)
        return try EPUBPackage.load(root: root)
    }

    static func main() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("folio-language-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        verify(try synthetic("<dc:language>en</dc:language>", in: temp, name: "english").language,
               expected: "en", label: "English declaration")
        verify(try synthetic("<dc:language>de</dc:language>", in: temp, name: "german").language,
               expected: "de", label: "German declaration")
        verify(try synthetic("<dc:language> zh-Hant-TW </dc:language>", in: temp, name: "bcp47").language,
               expected: "zh-Hant-TW", label: "Raw BCP-47 tag with whitespace")
        verify(try synthetic("", in: temp, name: "absent").language,
               expected: nil, label: "Absent means unknown, never English")
        verify(try synthetic("<dc:language>  </dc:language>", in: temp, name: "blank").language,
               expected: nil, label: "Blank means unknown")
        verify(try synthetic("<dc:language>de</dc:language><dc:language>DE</dc:language>", in: temp, name: "same").language,
               expected: "de", label: "Repeated same language")
        verify(try synthetic("<dc:language>de</dc:language><dc:language>en</dc:language>", in: temp, name: "conflicting").language,
               expected: nil, label: "Conflicting languages remain unknown")
        verify(try synthetic("<custom:language>en</custom:language><dc:language>de</dc:language>", in: temp, name: "namespace").language,
               expected: "de", label: "Only Dublin Core language is accepted")
        verify(try synthetic("<dc:language>und</dc:language>", in: temp, name: "undefined").language,
               expected: "und", label: "Unknown language tag stays raw for later policy")

        // Legacy call sites still initialize EPUBPackage without a language argument.
        let content = WebContent(root: temp, chapters: [], chapterSizes: [], toc: [], isComic: false, rtl: false)
        let legacy = EPUBPackage(title: "Compatibility", author: "Someone", coverURL: nil, content: content)
        verify(legacy.language, expected: nil, label: "Defaulted memberwise initializer remains compatible")

        if CommandLine.arguments.count > 1 {
            let realRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let real = try EPUBPackage.load(root: realRoot)
            verify(real.language, expected: "de", label: "Read-only installed Red Rising OPF")
            print("Read-only source: \(realRoot.path)")
        }
    }
}
