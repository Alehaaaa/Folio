#if os(iOS)
import Foundation

/// Shared macOS String.plainText helper lives in Components.swift alongside
/// AppKit UI. Keep the same sanitization behavior in the iOS target.
extension String {
    var plainText: String {
        replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .decodingHTMLEntities
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
