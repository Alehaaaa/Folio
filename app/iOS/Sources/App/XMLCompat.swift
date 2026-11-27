#if os(iOS)
import Foundation

/// Lightweight EPUB XML DOM for the XMLDocument calls shared with macOS.
/// Foundation's macOS XMLDocument and XPath implementation are unavailable on iOS.
class XMLNode {
    let name: String?
    weak var parent: XMLNode?
    var children: [XMLNode] = []
    var attributes: [XMLNode]?
    var namespaces: [XMLNode]? { attributes?.filter { $0.name?.hasPrefix("xmlns:") == true } }
    private var text = ""

    init(name: String? = nil, text: String = "") {
        self.name = name
        self.text = text
    }

    var localName: String? { name?.split(separator: ":").last.map(String.init) }
    /// Resolve the in-scope XML namespace for prefixed and default elements.
    /// Shared EPUBPackage uses this to accept only genuine Dublin Core
    /// dc:language metadata, rather than a similarly named vendor tag.
    var uri: String? {
        guard let name, !name.isEmpty else { return nil }
        let pieces = name.split(separator: ":", maxSplits: 1).map(String.init)
        let attribute = pieces.count == 2 ? "xmlns:" + pieces[0] : "xmlns"
        var node: XMLNode? = self
        while let current = node {
            if let namespace = current.attributes?.first(where: { $0.name == attribute })?.stringValue {
                return namespace
            }
            node = current.parent
        }
        return nil
    }
    var stringValue: String? {
        get {
            let value = text + children.compactMap(\.stringValue).joined()
            return value.isEmpty ? nil : value
        }
        set {
            text = newValue ?? ""
            children.removeAll()
        }
    }

    func append(_ node: XMLNode) {
        node.parent = self
        children.append(node)
    }

    func appendText(_ value: String) { text += value }

    func attribute(forName name: String) -> XMLNode? {
        attributes?.first(where: { $0.name == name })
    }

    func addAttribute(_ attribute: XMLNode) {
        if let index = attributes?.firstIndex(where: { $0.name == attribute.name }) {
            attributes?[index] = attribute
        } else {
            if attributes == nil { attributes = [] }
            attributes?.append(attribute)
        }
    }

    func removeAttribute(forName name: String) {
        attributes?.removeAll { $0.name == name }
    }

    func setAttributesWith(_ values: [String: String]) {
        for (name, value) in values { addAttribute(XMLNode(name: name, text: value)) }
    }

    func addNamespace(_ namespace: XMLNode) {
        guard let prefix = namespace.name, let uri = namespace.stringValue else { return }
        addAttribute(XMLNode(name: "xmlns:" + prefix, text: uri))
    }

    static func namespace(withName name: String, stringValue: String) -> XMLNode {
        XMLNode(name: name, text: stringValue)
    }

    static func attribute(withName name: String, stringValue: String) -> XMLNode {
        XMLNode(name: name, text: stringValue)
    }

    func addChild(_ child: XMLNode) { append(child) }

    func detach() {
        parent?.children.removeAll { $0 === self }
        parent = nil
    }

    fileprivate static func escape(_ text: String, attribute: Bool = false) -> String {
        var encoded = text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if attribute { encoded = encoded.replacingOccurrences(of: "\"", with: "&quot;") }
        return encoded
    }

    fileprivate func serialize() -> String {
        guard let name else { return children.map { $0.serialize() }.joined() }
        let attrs = (attributes ?? []).map {
            " \($0.name ?? "")=\"\(Self.escape($0.stringValue ?? "", attribute: true))\""
        }.joined()
        if children.isEmpty && text.isEmpty { return "<\(name)\(attrs)/>" }
        return "<\(name)\(attrs)>\(Self.escape(text))\(children.map { $0.serialize() }.joined())</\(name)>"
    }

    private func descendants() -> [XMLNode] {
        children.flatMap { [$0] + $0.descendants() }
    }

    /// The EPUB shared code uses XPath's local-name selectors with optional
    /// attribute equality predicates. Match those exact XPath constructs.
    func nodes(forXPath expression: String) throws -> [XMLNode] {
        let pattern = #"\*\[local-name\(\)='([^']+)'\]((?:\[@[^\]]+\])*)"#
        let regex = try NSRegularExpression(pattern: pattern)
        let source = expression as NSString
        let matches = regex.matches(in: expression, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return [] }
        let predicate = try NSRegularExpression(pattern: #"\[@([^=\]]+)='([^']*)'\]"#)
        var nodes: [XMLNode] = [self]
        var precedingEnd = 0

        for match in matches {
            let before = source.substring(with: NSRange(location: precedingEnd, length: match.range.location - precedingEnd))
            let recursive = before.hasSuffix("//")
            let soughtName = source.substring(with: match.range(at: 1))
            let filterRange = match.range(at: 2)
            let filters = predicate.matches(in: expression, range: filterRange).map { condition in
                (source.substring(with: condition.range(at: 1)), source.substring(with: condition.range(at: 2)))
            }
            var next: [XMLNode] = []
            for node in nodes {
                for child in recursive ? node.descendants() : node.children {
                    guard child.localName == soughtName else { continue }
                    let passes = filters.allSatisfy { key, value in
                        child.attributes?.contains(where: { $0.name == key && $0.stringValue == value }) == true
                    }
                    if passes { next.append(child) }
                }
            }
            nodes = next
            precedingEnd = match.range.location + match.range.length
        }
        return nodes
    }
}

final class XMLElement: XMLNode {
    convenience init(name: String, stringValue: String) {
        self.init(name: name, text: stringValue)
    }
}

final class XMLDocument: XMLNode {
    enum Option { case documentTidyHTML }

    init(contentsOf file: URL, options: [Option]) throws {
        super.init()
        let data = try Data(contentsOf: file)
        let builder = MobileXMLTreeBuilder(root: self)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse() else {
            throw parser.parserError ?? NSError(domain: "FolioXML", code: 1,
                                               userInfo: [NSLocalizedDescriptionKey: "Invalid XML document"])
        }
    }

    func rootElement() -> XMLElement? { children.first as? XMLElement }

    func xmlData(options: [Option]) -> Data {
        Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" + serialize()).utf8)
    }
}

private final class MobileXMLTreeBuilder: NSObject, XMLParserDelegate {
    private var stack: [XMLNode]

    init(root: XMLNode) { stack = [root] }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let node = XMLElement(name: elementName)
        node.attributes = attributes.map { XMLNode(name: $0.key, text: $0.value) }
        stack.last?.append(node)
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.appendText(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.appendText(String(decoding: CDATABlock, as: UTF8.self))
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if stack.count > 1 { stack.removeLast() }
    }
}
#endif
