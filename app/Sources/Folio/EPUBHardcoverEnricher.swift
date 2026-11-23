import Foundation

/// Writes a selected Hardcover catalogue record into an extracted EPUB's OPF package.
/// The caller supplies a normalized PNG and repackages/verifies the EPUB before replacing it.
/// Fields beyond the Hardcover record that the metadata editor can write.
struct EPUBMetadataExtras: Sendable, Hashable {
    var publisher: String? = nil
    var language: String? = nil
    var series: String? = nil
    var seriesIndex: Double? = nil
    /// Replace the publication date with the record's year (the editor's choice),
    /// rather than only adding one when the file has none.
    var replaceYear = false
}

enum EPUBHardcoverEnricher {
    private static let dublinCore = "http://purl.org/dc/elements/1.1/"

    static func apply(in extractedRoot: URL, book: HCBook, coverData: Data?, extras: EPUBMetadataExtras = .init()) throws {
        let fileManager = FileManager.default
        guard let container = EPUBPackage.xml(extractedRoot.appendingPathComponent("META-INF/container.xml")),
              let packagePath = first(container, "//*[local-name()='rootfile']")?.attribute(forName: "full-path")?.stringValue,
              !packagePath.isEmpty else {
            throw failure("The EPUB has no valid package manifest.")
        }
        let root = extractedRoot.standardizedFileURL
        let opfURL = root.appendingPathComponent(packagePath).standardizedFileURL
        guard opfURL.path.hasPrefix(root.path + "/"),
              opfURL.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
              let doc = EPUBPackage.xml(opfURL),
              let package = doc.rootElement(), package.localName == "package",
              let metadata = first(doc, "//*[local-name()='package']/*[local-name()='metadata']"),
              let manifest = first(doc, "//*[local-name()='package']/*[local-name()='manifest']") else {
            throw failure("The EPUB's package metadata cannot be edited safely.")
        }

        // Declare a Dublin Core prefix for new nodes without changing existing namespaces.
        let hasDCNamespace = metadata.namespaces?.contains(where: { $0.name == "dc" && $0.stringValue == dublinCore }) == true
        if !hasDCNamespace {
            metadata.addNamespace(XMLNode.namespace(withName: "dc", stringValue: dublinCore) as! XMLNode)
        }

        if !book.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            setText(book.title, localName: "title", metadata: metadata)
        }
        if !book.authors.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A single creator string preserves author ordering and avoids guessing whether
            // a comma separates contributors or a surname-first personal name.
            setText(book.authors, localName: "creator", metadata: metadata)
            let creators = all(metadata, "./*[local-name()='creator']")
            for duplicate in creators.dropFirst() {
                if let oldID = duplicate.attribute(forName: "id")?.stringValue {
                    for refinement in all(metadata, "./*[local-name()='meta']")
                    where refinement.attribute(forName: "refines")?.stringValue == "#\(oldID)" {
                        refinement.detach()
                    }
                }
                duplicate.detach()
            }
        }
        if let description = book.description?.plainText.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            setText(description, localName: "description", metadata: metadata)
        }
        if let year = book.year, (1000...3000).contains(year),
           extras.replaceYear || first(metadata, "./*[local-name()='date']") == nil {
            setText(String(year), localName: "date", metadata: metadata)
        }
        if let publisher = extras.publisher?.trimmingCharacters(in: .whitespacesAndNewlines), !publisher.isEmpty {
            setText(publisher, localName: "publisher", metadata: metadata)
        }
        if let language = extras.language?.trimmingCharacters(in: .whitespacesAndNewlines), !language.isEmpty {
            setText(language, localName: "language", metadata: metadata)
        }
        if let series = extras.series?.trimmingCharacters(in: .whitespacesAndNewlines), !series.isEmpty {
            setMeta("calibre:series", series, metadata: metadata)
            if let index = extras.seriesIndex {
                setMeta("calibre:series_index", index == index.rounded() ? String(Int(index)) : String(index), metadata: metadata)
            }
        }

        if let coverData {
            // The caller normalizes the image to PNG; confirm its signature before writing it
            // into the manifest as image/png. A failed image never produces a broken EPUB.
            guard coverData.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
                throw failure("The Hardcover cover is not a valid PNG.")
            }
            let name = "folio-hardcover-\(book.id)-cover.png"
            let coverURL = opfURL.deletingLastPathComponent().appendingPathComponent(name)
            try coverData.write(to: coverURL, options: .atomic)

            let newID = "folio-hardcover-cover-\(book.id)"
            let epub3 = (package.attribute(forName: "version")?.stringValue ?? "2").hasPrefix("3")
            let items = all(manifest, "./*[local-name()='item']")
            for item in items {
                let properties = (item.attribute(forName: "properties")?.stringValue ?? "")
                    .split(whereSeparator: \.isWhitespace).map(String.init)
                if properties.contains("cover-image") {
                    let remaining = properties.filter { $0 != "cover-image" }
                    if remaining.isEmpty { item.removeAttribute(forName: "properties") }
                    else { item.setAttributesWith(["properties": remaining.joined(separator: " ")]) }
                }
            }

            let coverItem: XMLElement
            if let existing = items.first(where: { $0.attribute(forName: "id")?.stringValue == newID }) {
                coverItem = existing
            } else {
                coverItem = XMLElement(name: "item")
                manifest.addChild(coverItem)
            }
            coverItem.addAttribute(XMLNode.attribute(withName: "id", stringValue: newID) as! XMLNode)
            coverItem.addAttribute(XMLNode.attribute(withName: "href", stringValue: name) as! XMLNode)
            coverItem.addAttribute(XMLNode.attribute(withName: "media-type", stringValue: "image/png") as! XMLNode)
            if epub3 {
                coverItem.addAttribute(XMLNode.attribute(withName: "properties", stringValue: "cover-image") as! XMLNode)
            }

            if let meta = all(metadata, "./*[local-name()='meta']").first(where: {
                $0.attribute(forName: "name")?.stringValue?.lowercased() == "cover"
            }) {
                meta.addAttribute(XMLNode.attribute(withName: "content", stringValue: newID) as! XMLNode)
            } else if !epub3 {
                let meta = XMLElement(name: "meta")
                meta.addAttribute(XMLNode.attribute(withName: "name", stringValue: "cover") as! XMLNode)
                meta.addAttribute(XMLNode.attribute(withName: "content", stringValue: newID) as! XMLNode)
                metadata.addChild(meta)
            }
        }

        try doc.xmlData(options: []).write(to: opfURL, options: .atomic)

        // Parsing the modified package catches broken paths, malformed OPF and lost spine links.
        let checked = try EPUBPackage.load(root: root)
        guard !checked.content.chapters.isEmpty else { throw failure("The updated EPUB has no readable chapters.") }
        if coverData != nil {
            guard let cover = checked.coverURL, fileManager.fileExists(atPath: cover.path) else {
                throw failure("The updated EPUB cannot find its cover image.")
            }
        }
    }

    private static func setText(_ text: String, localName: String, metadata: XMLElement) {
        if let existing = first(metadata, "./*[local-name()='\(localName)']") {
            existing.stringValue = text
        } else {
            metadata.addChild(XMLElement(name: "dc:\(localName)", stringValue: text))
        }
    }

    /// Calibre-style <meta name="…" content="…"/>, which readers and Calibre both understand.
    private static func setMeta(_ name: String, _ content: String, metadata: XMLElement) {
        if let existing = all(metadata, "./*[local-name()='meta']").first(where: {
            $0.attribute(forName: "name")?.stringValue == name
        }) {
            existing.addAttribute(XMLNode.attribute(withName: "content", stringValue: content) as! XMLNode)
        } else {
            let meta = XMLElement(name: "meta")
            meta.addAttribute(XMLNode.attribute(withName: "name", stringValue: name) as! XMLNode)
            meta.addAttribute(XMLNode.attribute(withName: "content", stringValue: content) as! XMLNode)
            metadata.addChild(meta)
        }
    }

    private static func first(_ node: XMLNode, _ xpath: String) -> XMLElement? {
        (try? node.nodes(forXPath: xpath))?.first as? XMLElement
    }

    private static func all(_ node: XMLNode, _ xpath: String) -> [XMLElement] {
        ((try? node.nodes(forXPath: xpath)) ?? []).compactMap { $0 as? XMLElement }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Folio", code: 46, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
