import Foundation
import Testing

/// The decoding rules in docs/jellyfin-api.md, held as source scans: a DTO
/// that stores a `Date`, spells out casing keys or compares by id alone
/// fails quietly at runtime, so they fail here instead.
@Suite("Jellyfin model rules")
struct JellyfinModelRulesTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func swiftFiles(under directory: String) throws -> [(path: String, text: String)] {
        let root = Self.repoRoot.appendingPathComponent(directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        return try names.filter { $0.hasSuffix(".swift") }.sorted().map { name in
            ("\(directory)/\(name)", try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8))
        }
    }

    /// The files whose types decode Jellyfin JSON.
    private func jellyfinFiles() throws -> [(path: String, text: String)] {
        let models = try source("Lagoon/Shared/Models/JellyfinModels.swift")
        let clients = try swiftFiles(under: "Lagoon/Shared/Networking")
            .filter { $0.path.contains("/JellyfinClient") }
        return [("Lagoon/Shared/Models/JellyfinModels.swift", models)] + clients
    }

    private func matches(_ pattern: String, in text: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    @Test func theScansSeeTheFilesTheyGuard() throws {
        let files = try jellyfinFiles()
        #expect(files.count > 3)
        #expect(files.contains { $0.text.contains("struct MediaItem") })
        #expect(files.contains { $0.text.contains("JellyfinClient") })
    }

    @Test func noJellyfinTypeStoresADate() throws {
        for file in try jellyfinFiles() {
            let stored = try matches(#"^\s*(let|var)\s+\w+\s*:\s*\[?Date\]?\??\s*(=.*)?$"#, in: file.text)
            #expect(stored.isEmpty, "\(file.path) stores a Date: \(stored)")
        }
    }

    @Test func noJellyfinTypeDeclaresCodingKeysForCasing() throws {
        for file in try jellyfinFiles() {
            let declared = try matches(#"enum\s+(?!AnyCodingKey)\w*\s*:\s*[^{]*CodingKey"#, in: file.text)
            #expect(declared.isEmpty, "\(file.path) declares coding keys: \(declared)")
        }
    }

    @Test func mediaTypesCompareByValueNeverByIDAlone() throws {
        let types = "MediaItem|MediaSource|MediaStream"
        let models = try source("Lagoon/Shared/Models/JellyfinModels.swift")
        #expect(try matches(#"static func =="#, in: models).isEmpty)
        let root = Self.repoRoot.appendingPathComponent("Lagoon")
        let enumerator = try #require(FileManager.default.enumerator(atPath: root.path))
        var scanned = 0
        for case let relative as String in enumerator where relative.hasSuffix(".swift") {
            let text = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            scanned += 1
            let custom = try matches(#"static func ==\s*\([^)]*\b(\#(types))\b"#, in: text)
            #expect(custom.isEmpty, "\(relative) compares a media type by hand: \(custom)")
        }
        #expect(scanned > 100)
    }
}
