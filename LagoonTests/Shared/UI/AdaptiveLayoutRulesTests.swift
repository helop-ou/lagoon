import Foundation
import Testing

/// Layout rules held as source scans. An iPhone Duo changes size classes and
/// moves the bars to the side as it folds, so a layout chosen by idiom or a
/// toolbar button with no symbol looks fine on every other device.
@Suite("Adaptive layout rules")
struct AdaptiveLayoutRulesTests {
    private static let appRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Lagoon")

    /// Device facts for diagnostics, not layout.
    private static let idiomAllowed: Set<String> = ["Shared/Diagnostics/DiagnosticContext.swift"]

    /// The count is in the title, which a symbol would hide in a bottom bar.
    /// A closed Duo shows the text as it is.
    private static let textToolbarButtonsAllowed: Set<String> = ["seerr.seasons.submit"]

    /// A full-screen cover has room for its toolbar. A sheet does not.
    private static let tvToolbarsAllowed: Set<String> = ["Features/Accounts/AddAccountView.swift"]

    private func sources() throws -> [(path: String, text: String)] {
        let enumerator = try #require(FileManager.default.enumerator(atPath: Self.appRoot.path))
        var files: [(String, String)] = []
        for case let relative as String in enumerator where relative.hasSuffix(".swift") {
            files.append((relative, try String(contentsOf: Self.appRoot.appending(path: relative), encoding: .utf8)))
        }
        return files
    }

    /// The body of each `ToolbarItem` and `ToolbarItemGroup`, up to its
    /// closing brace.
    private func toolbarItems(in text: String) -> [Substring] {
        var items: [Substring] = []
        var searchStart = text.startIndex
        while let match = text.range(of: #"ToolbarItem(Group)?\("#, options: .regularExpression, range: searchStart..<text.endIndex) {
            searchStart = match.upperBound
            guard let open = text[match.upperBound...].firstIndex(of: "{") else { break }
            var depth = 0
            var index = open
            while index < text.endIndex {
                if text[index] == "{" { depth += 1 }
                if text[index] == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                index = text.index(after: index)
            }
            items.append(text[open..<min(index, text.endIndex)])
        }
        return items
    }

    /// Whether each line compiles for tvOS, from the `#if os(...)` blocks
    /// around it. Any other condition counts as compiled.
    private func tvOSLines(in text: String) -> [(line: Int, text: Substring, onTV: Bool)] {
        func compilesForTV(_ condition: Substring) -> Bool {
            if condition.contains("!os(tvOS)") { return false }
            if condition.contains("os(tvOS)") || condition.contains("!os(iOS)") { return true }
            return !condition.contains("os(iOS)")
        }
        // Each open block: whether this branch compiles, and whether an
        // earlier branch did.
        var blocks: [(active: Bool, taken: Bool)] = []
        var lines: [(Int, Substring, Bool)] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("#if ") {
                let active = compilesForTV(trimmed.dropFirst(4))
                blocks.append((active, active))
            } else if trimmed.hasPrefix("#elseif "), let block = blocks.popLast() {
                let active = !block.taken && compilesForTV(trimmed.dropFirst(8))
                blocks.append((active, block.taken || active))
            } else if trimmed.hasPrefix("#else"), let block = blocks.popLast() {
                blocks.append((!block.taken, true))
            } else if trimmed.hasPrefix("#endif") {
                _ = blocks.popLast()
            }
            lines.append((index + 1, line, blocks.allSatisfy(\.active)))
        }
        return lines
    }

    @Test func theScanSeesTheToolbars() throws {
        let items = try sources().flatMap { toolbarItems(in: $0.text) }
        #expect(items.count > 10)
        #expect(items.contains { $0.contains("account.setup.cancel") })
    }

    /// Size classes, not idiom: an open Duo is an iPhone with an iPad's room.
    @Test func noLayoutReadsTheDeviceIdiom() throws {
        for file in try sources() where !Self.idiomAllowed.contains(file.path) {
            #expect(!file.text.contains("userInterfaceIdiom"), "\(file.path) reads the device idiom")
        }
    }

    /// In a vertical bar a button shows only its symbol, so one without a
    /// symbol has nothing to show.
    @Test func everyToolbarButtonHasASymbol() throws {
        for file in try sources() {
            for item in toolbarItems(in: file.text) where item.contains("Button") {
                let exempt = Self.textToolbarButtonsAllowed.contains { item.contains("\"\($0)\"") }
                let hasSymbol = item.contains("systemImage:") || item.contains("Image(")
                #expect(exempt || hasSymbol, "\(file.path) has a toolbar button without a symbol: \(item.prefix(120))")
            }
        }
    }

    /// A tvOS sheet squeezes a toolbar's buttons into "C…el", so tvOS modals
    /// are `TVModalPanel`s with their actions inside.
    @Test func tvOSKeepsToolbarsOutOfSheets() throws {
        for file in try sources() where !Self.tvToolbarsAllowed.contains(file.path) {
            for line in tvOSLines(in: file.text) where line.onTV && line.text.contains(".toolbar {") {
                Issue.record("\(file.path):\(line.line) has a toolbar on tvOS. Use TVModalPanel.")
            }
        }
    }

    @Test func theTVScanFollowsPlatformBlocks() {
        let source = """
        a
        #if os(tvOS)
        b
        #elseif DEBUG
        c
        #else
        d
        #endif
        #if !os(tvOS)
        e
        #if DEBUG
        f
        #endif
        #else
        g
        #endif
        """
        let onTV = tvOSLines(in: source).filter { $0.onTV && !$0.text.hasPrefix("#") }.map { String($0.text) }
        #expect(onTV == ["a", "b", "g"])
    }
}
