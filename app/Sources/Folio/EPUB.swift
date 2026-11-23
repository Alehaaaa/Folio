import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
import ZIPFoundation
#endif
import PDFKit

#if os(macOS)
typealias FolioNativeImage = NSImage
#elseif os(iOS)
typealias FolioNativeImage = UIImage
#endif

enum FolioImageLoader {
    static func load(_ url: URL) -> FolioNativeImage? {
        #if os(macOS)
        NSImage(contentsOf: url)
        #else
        UIImage(contentsOfFile: url.path)
        #endif
    }

    static func decode(_ data: Data) -> FolioNativeImage? {
        #if os(macOS)
        NSImage(data: data)
        #else
        UIImage(data: data)
        #endif
    }
}

struct TOCEntry: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var level: Int
    var chapter: Int
    var fragment: String?
}

/// What the web reader needs: a folder it may read, the chapters in order and a table of contents.
struct WebContent {
    var root: URL
    var chapters: [URL]
    var chapterSizes: [Double]
    var toc: [TOCEntry]
    var isComic: Bool
    var rtl: Bool
}

enum Unzip {
    /// Finder and Apple Books sometimes expose an EPUB as an expanded folder.
    /// Repackage it so the library always stores a portable, conventional EPUB file.
    static func packageEPUBFolder(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let mime = source.appendingPathComponent("mimetype")
        let container = source.appendingPathComponent("META-INF/container.xml")
        guard (try? Data(contentsOf: mime)) == Data("application/epub+zip".utf8),
              fm.fileExists(atPath: container.path) else {
            throw NSError(domain: "Folio", code: 7, userInfo: [NSLocalizedDescriptionKey: "This EPUB folder is missing its mimetype or package information."])
        }

        #if os(iOS)
        // EPUB requires the first ZIP entry to be the uncompressed "mimetype".
        // ZIPFoundation's generic directory helper doesn't guarantee its order.
        let archive = try Archive(url: destination, accessMode: .create)
        try archive.addEntry(with: "mimetype", relativeTo: source, compressionMethod: .none)
        // Ask the enumerator for paths relative to the folder. Cutting a URL enumerator's
        // absolute paths by the folder's length breaks on iOS, where the app container can
        // be reported as /var/... for the folder and /private/var/... for its contents,
        // which produced entries such as "ded/META-INF" that don't exist.
        var entries: [String] = []
        if let enumerator = fm.enumerator(atPath: source.path) {
            while let relative = enumerator.nextObject() as? String {
                let parts = relative.split(separator: "/")
                guard relative != "mimetype", !relative.isEmpty,
                      !parts.contains(where: { $0.hasPrefix(".") }) else { continue }
                entries.append(relative)
            }
        }
        for entry in entries.sorted() {
            let isDirectory = (try? source.appendingPathComponent(entry)
                .resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            // ZIP readers create parent folders from file entries; explicit folder
            // entries add nothing and are where path mismatches surfaced.
            if isDirectory { continue }
            try archive.addEntry(with: entry, relativeTo: source, compressionMethod: .deflate)
        }
        #else
        let entries = try fm.contentsOfDirectory(atPath: source.path).filter { $0 != "mimetype" }.sorted()
        // The EPUB specification requires "mimetype" to be the first, uncompressed ZIP entry.
        try zip(["-q", "-X", "-0", destination.path, "mimetype"], in: source)
        if !entries.isEmpty {
            try zip(["-q", "-X", "-r", "-9", destination.path] + entries.map { "./" + $0 }, in: source)
        }
        #endif
    }

    /// An expanded CBZ is a folder of comic pages. Store it as a real CBZ ZIP file.
    static func packageComicFolder(_ source: URL, to destination: URL) throws {
        guard !Converters.images(in: source).isEmpty else {
            throw NSError(domain: "Folio", code: 4, userInfo: [NSLocalizedDescriptionKey: "No image pages found in this comic folder."])
        }
        #if os(iOS)
        try FileManager.default.zipItem(at: source, to: destination, shouldKeepParent: false)
        #else
        let entries = try FileManager.default.contentsOfDirectory(atPath: source.path).sorted()
        try zip(["-q", "-X", "-r", "-9", destination.path] + entries.map { "./" + $0 }, in: source)
        #endif
    }

    #if os(macOS)
    private static func zip(_ arguments: [String], in source: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = source
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Folio", code: 8, userInfo: [NSLocalizedDescriptionKey: "Couldn't package the expanded book folder."])
        }
    }
    #endif

    /// Extracts a ZIP container (EPUB, CBZ) with the system's ditto tool.
    static func extract(_ src: URL, to dest: URL) throws {
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.unzipItem(at: src, to: dest)
        #else
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", src.path, dest.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(domain: "Folio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't open the archive."])
        }
        #endif
    }
}

private extension XMLNode {
    func all(_ xpath: String) -> [XMLNode] { (try? nodes(forXPath: xpath)) ?? [] }
    func first(_ xpath: String) -> XMLNode? { all(xpath).first }
    func attr(_ name: String) -> String? {
        (self as? XMLElement)?.attributes?.first(where: { $0.localName == name || $0.name == name })?.stringValue
    }
}

struct EPUBPackage {
    var title: String
    var author: String
    var isbn: String? = nil
    /// OPF dc:language as declared by the EPUB. Nil means absent or conflicting,
    /// never a presumed default such as English.
    var language: String? = nil
    var series: String? = nil
    var seriesIndex: Double? = nil
    var coverURL: URL?
    var content: WebContent
    var summary: String? = nil
    var publisher: String? = nil
    var publishedYear: Int? = nil

    static func xml(_ url: URL) -> XMLDocument? {
        if let d = try? XMLDocument(contentsOf: url, options: []) { return d }
        return try? XMLDocument(contentsOf: url, options: [.documentTidyHTML])
    }

    static func resolve(_ href: String, base: URL) -> (URL, String?) {
        var h = href
        var frag: String?
        if let i = h.firstIndex(of: "#") {
            frag = String(h[h.index(after: i)...])
            h = String(h[..<i])
        }
        let decoded = h.removingPercentEncoding ?? h
        let url = decoded.isEmpty ? base : base.appendingPathComponent(decoded).standardizedFileURL
        return (url, frag)
    }

    static func load(root: URL) throws -> EPUBPackage {
        guard let container = xml(root.appendingPathComponent("META-INF/container.xml")),
              let opfPath = container.first("//*[local-name()='rootfile']")?.attr("full-path"),
              let opf = xml(root.appendingPathComponent(opfPath))
        else { throw NSError(domain: "Folio", code: 2, userInfo: [NSLocalizedDescriptionKey: "This EPUB has no readable package file."]) }

        let opfURL = root.appendingPathComponent(opfPath).standardizedFileURL
        let opfDir = opfURL.deletingLastPathComponent()

        let title = opf.first("//*[local-name()='metadata']/*[local-name()='title']")?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let authors = opf.all("//*[local-name()='metadata']/*[local-name()='creator']")
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // Retain the publisher's original language tag for the caller to normalize.
        // A bilingual/mislabelled package must not be silently treated as one language.
        // Apple's XMLDocument does not reliably evaluate namespace-uri() in an XPath
        // predicate, so inspect each XMLNode.uri after selecting by local name.
        let languages = opf.all("//*[local-name()='metadata']/*[local-name()='language']")
            .filter { $0.uri == "http://purl.org/dc/elements/1.1/" }
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let language = languages.first.flatMap { first in
            languages.allSatisfy { $0.caseInsensitiveCompare(first) == .orderedSame } ? first : nil
        }
        let isbnValues = Set(opf.all("//*[local-name()='metadata']/*[local-name()='identifier']").compactMap { node -> String? in
            guard let raw = node.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            let isLabelled = [node.attr("id"), node.attr("scheme"), node.attr("opf:scheme"), raw]
                .compactMap { $0?.lowercased() }.contains { $0.contains("isbn") }
            let isBareNumber = raw.range(of: "^[0-9Xx\\s-]+$", options: .regularExpression) != nil
            guard isLabelled || isBareNumber else { return nil }
            return BookAutoMatch.isbn(in: raw)
        })
        let isbn = isbnValues.count == 1 ? isbnValues.first : nil

        struct Item { var id: String; var href: String; var type: String; var props: String }
        var items: [String: Item] = [:]
        var itemList: [Item] = []
        for n in opf.all("//*[local-name()='manifest']/*[local-name()='item']") {
            let it = Item(id: n.attr("id") ?? "", href: n.attr("href") ?? "", type: n.attr("media-type") ?? "", props: n.attr("properties") ?? "")
            items[it.id] = it
            itemList.append(it)
        }

        var spine: [URL] = []
        for n in opf.all("//*[local-name()='spine']/*[local-name()='itemref']") {
            if n.attr("linear") == "no" { continue }
            if let it = items[n.attr("idref") ?? ""] {
                spine.append(resolve(it.href, base: opfDir).0)
            }
        }
        if spine.isEmpty {
            spine = itemList.filter { $0.type.contains("html") }.map { resolve($0.href, base: opfDir).0 }
        }
        let rtl = opf.first("//*[local-name()='spine']")?.attr("page-progression-direction") == "rtl"

        // Cover image
        var cover: URL?
        if let it = itemList.first(where: { $0.props.split(separator: " ").contains("cover-image") }) {
            cover = resolve(it.href, base: opfDir).0
        } else if let coverID = opf.first("//*[local-name()='meta'][@name='cover']")?.attr("content"),
                  let it = items[coverID], it.type.hasPrefix("image") {
            cover = resolve(it.href, base: opfDir).0
        } else if let it = itemList.first(where: { $0.type.hasPrefix("image") && ($0.id.lowercased().contains("cover") || $0.href.lowercased().contains("cover")) }) {
            cover = resolve(it.href, base: opfDir).0
        }

        // Table of contents: EPUB 3 nav document, else EPUB 2 NCX
        func chapterIndex(_ u: URL) -> Int? {
            let path = u.standardizedFileURL.path
            return spine.firstIndex { $0.standardizedFileURL.path == path }
        }
        var toc: [TOCEntry] = []
        if let nav = itemList.first(where: { $0.props.split(separator: " ").contains("nav") }) {
            let navURL = resolve(nav.href, base: opfDir).0
            if let doc = xml(navURL) {
                let navs = doc.all("//*[local-name()='nav']")
                let tocNav = navs.first(where: { ($0.attr("type") ?? "").contains("toc") }) ?? navs.first
                for a in tocNav?.all(".//*[local-name()='a']") ?? [] {
                    guard let href = a.attr("href") else { continue }
                    let (u, frag) = resolve(href, base: navURL.deletingLastPathComponent())
                    guard let ch = chapterIndex(u) else { continue }
                    var level = 0
                    var p = a.parent
                    while let node = p { if node.localName == "ol" { level += 1 }; p = node.parent }
                    let text = (a.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { toc.append(TOCEntry(title: text, level: max(0, level - 1), chapter: ch, fragment: frag)) }
                }
            }
        }
        if toc.isEmpty, let ncxItem = itemList.first(where: { $0.type == "application/x-dtbncx+xml" }) {
            let ncxURL = resolve(ncxItem.href, base: opfDir).0
            if let doc = xml(ncxURL) {
                for np in doc.all("//*[local-name()='navPoint']") {
                    guard let src = np.first("./*[local-name()='content']")?.attr("src") else { continue }
                    let (u, frag) = resolve(src, base: ncxURL.deletingLastPathComponent())
                    guard let ch = chapterIndex(u) else { continue }
                    var level = 0
                    var p = np.parent
                    while let node = p { if node.localName == "navPoint" { level += 1 }; p = node.parent }
                    let text = (np.first("./*[local-name()='navLabel']")?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { toc.append(TOCEntry(title: text, level: level, chapter: ch, fragment: frag)) }
                }
            }
        }
        if toc.isEmpty {
            toc = spine.enumerated().map { TOCEntry(title: "Section \($0.offset + 1)", level: 0, chapter: $0.offset) }
        }

        let sizes = spine.map { u -> Double in
            let s = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? NSNumber)?.doubleValue ?? 1000
            return max(500, s)
        }

        // Series: Calibre's calibre:series metadata, else EPUB 3 belongs-to-collection.
        var series = opf.first("//*[local-name()='meta'][@name='calibre:series']")?.attr("content")
        var seriesIndex = opf.first("//*[local-name()='meta'][@name='calibre:series_index']")?.attr("content").flatMap(Double.init)
        if series == nil, let c = opf.first("//*[local-name()='meta'][@property='belongs-to-collection']") {
            series = c.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let cid = c.attr("id"),
               let pos = opf.first("//*[local-name()='meta'][@refines='#\(cid)'][@property='group-position']")?.stringValue {
                seriesIndex = Double(pos.trimmingCharacters(in: .whitespaces))
            }
        }
        if series?.isEmpty == true { series = nil }

        func metadataText(_ name: String) -> String? {
            let value = opf.first("//*[local-name()='metadata']/*[local-name()='\(name)']")?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        let publicationDate = opf.all("//*[local-name()='metadata']/*[local-name()='date']").first { node in
            let event = (node.attr("opf:event") ?? node.attr("event"))?.lowercased()
            return event == nil || event == "publication"
        }?.stringValue
        let publishedYear = publicationDate.flatMap { Int($0.trimmingCharacters(in: .whitespaces).prefix(4)) }

        return EPUBPackage(
            title: title,
            author: authors.joined(separator: ", "),
            isbn: isbn,
            language: language,
            series: series,
            seriesIndex: seriesIndex,
            coverURL: cover,
            content: WebContent(root: root, chapters: spine, chapterSizes: sizes, toc: toc, isComic: false, rtl: rtl),
            summary: metadataText("description"),
            publisher: metadataText("publisher"),
            publishedYear: publishedYear.flatMap { (1000...2100).contains($0) ? $0 : nil }
        )
    }
}

// MARK: - Turning other formats into something the reader can show

enum Converters {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func page(_ title: String, body: String) -> String {
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>\(escape(title))</title></head><body>\(body)</body></html>"
    }

    static func textToHTML(_ text: String, title: String) -> String {
        let paras = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { "<p>" + escape($0).replacingOccurrences(of: "\n", with: "<br>") + "</p>" }
            .joined(separator: "\n")
        return page(title, body: paras)
    }

    static func inlineMarkdown(_ s: String) -> String {
        var out = escape(s)
        let rules: [(String, String)] = [
            ("!\\[([^\\]]*)\\]\\(([^)]+)\\)", "<img alt=\"$1\" src=\"$2\">"),
            ("`([^`]+)`", "<code>$1</code>"),
            ("\\*\\*([^*]+)\\*\\*", "<strong>$1</strong>"),
            ("__([^_]+)__", "<strong>$1</strong>"),
            ("\\*([^*]+)\\*", "<em>$1</em>"),
            ("_([^_]+)_", "<em>$1</em>"),
            ("\\[([^\\]]+)\\]\\(([^)]+)\\)", "<a href=\"$2\">$1</a>"),
        ]
        for (pattern, template) in rules {
            out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return out
    }

    static func markdownToHTML(_ md: String, title: String) -> String {
        var html = ""
        var paragraph: [String] = []
        var inList = false
        var inCode = false
        func flush() {
            if !paragraph.isEmpty { html += "<p>" + inlineMarkdown(paragraph.joined(separator: " ")) + "</p>\n"; paragraph = [] }
        }
        func closeList() { if inList { html += "</ul>\n"; inList = false } }
        for raw in md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flush(); closeList()
                html += inCode ? "</code></pre>\n" : "<pre><code>"
                inCode.toggle()
                continue
            }
            if inCode { html += escape(raw) + "\n"; continue }
            if line.isEmpty { flush(); closeList(); continue }
            if let hashes = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#") {
                flush(); closeList()
                let level = min(6, line.distance(from: line.startIndex, to: hashes))
                html += "<h\(level)>\(inlineMarkdown(String(line[hashes...]).trimmingCharacters(in: .whitespaces)))</h\(level)>\n"
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                if !inList { html += "<ul>\n"; inList = true }
                html += "<li>\(inlineMarkdown(String(line.dropFirst(2))))</li>\n"
            } else if line.hasPrefix("> ") {
                flush(); closeList()
                html += "<blockquote>\(inlineMarkdown(String(line.dropFirst(2))))</blockquote>\n"
            } else {
                closeList()
                paragraph.append(line)
            }
        }
        flush(); closeList()
        return page(title, body: html)
    }

    static func comicHTML(images: [URL], root: URL) -> String {
        let rootPath = root.path
        let body = images.map { u -> String in
            var rel = u.path
            if rel.hasPrefix(rootPath) { rel = String(rel.dropFirst(rootPath.count + 1)) }
            let enc = rel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? rel
            return "<div class=\"folio-comic-page\"><img src=\"\(enc)\"></div>"
        }.joined(separator: "\n")
        return page("Comic", body: body)
    }

    static func images(in dir: URL) -> [URL] {
        let exts: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp"]
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        for case let u as URL in en where exts.contains(u.pathExtension.lowercased()) && !u.path.contains("__MACOSX") {
            out.append(u)
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

// MARK: - Cover helpers

enum CoverMaker {
    static func pngData(_ image: FolioNativeImage, maxHeight: CGFloat = 600) -> Data? {
        let scale = min(1, maxHeight / max(image.size.height, 1))
        let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        #if os(iOS)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.pngData { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        #else
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
        #endif
    }

    static func pdfCover(_ doc: PDFDocument) -> Data? {
        guard let page = doc.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let h: CGFloat = 600
        let w = h * bounds.width / max(bounds.height, 1)
        return pngData(page.thumbnail(of: CGSize(width: w, height: h), for: .mediaBox))
    }
}
