import Foundation

// Shared author-name parsing lives in the macOS navigation view, which is
// excluded from iOS. Extensions.findCopies uses the same matching semantics.
enum Names {
    static func split(_ s: String) -> [String] {
        s.replacingOccurrences(of: " & ", with: ", ")
            .replacingOccurrences(of: "; ", with: ", ")
            .components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func matches(_ line: String, _ name: String) -> Bool {
        let normalized = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        return split(line).contains {
            $0.lowercased().folding(options: .diacriticInsensitive, locale: nil) == normalized
        } || line.localizedCaseInsensitiveContains(name)
    }
}
