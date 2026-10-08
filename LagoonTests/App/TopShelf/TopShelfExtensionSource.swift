import Foundation

/// `LagoonTopShelf/ContentProvider.swift` as text. The extension cannot
/// import the app module, so it repeats the app's names by hand; reading its
/// source is the only way to check both sides of that contract.
struct TopShelfExtensionSource {
    let text: String

    init() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TopShelf
            .deletingLastPathComponent() // App
            .deletingLastPathComponent() // LagoonTests
            .deletingLastPathComponent() // repository root
            .appending(path: "LagoonTopShelf/ContentProvider.swift")
        text = try String(contentsOf: file, encoding: .utf8)
    }

    /// The value of `private let <name> = "…"`, or nil when it is gone.
    func stringConstant(_ name: String) -> String? {
        firstCaptures(of: #"let \#(name) = "([^"]*)""#, in: text).first
    }

    /// The stored property names of a `private struct <name>` declaration.
    func propertyNames(ofStruct name: String) -> [String] {
        guard let start = text.range(of: "private struct \(name)"),
              let end = text.range(of: "\n}", range: start.upperBound..<text.endIndex) else { return [] }
        return firstCaptures(of: #"let (\w+):"#, in: String(text[start.upperBound..<end.lowerBound]))
    }

    /// Every first capture group of `pattern` in this file, in order.
    func captures(of pattern: String) -> [String] {
        firstCaptures(of: pattern, in: text)
    }

    private func firstCaptures(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
