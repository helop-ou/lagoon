import Foundation
import Testing
import LagoonEngine
@testable import Lagoon

/// The playback controller owns the engine. SwiftUI keeps copies of view
/// values and their closures past an episode handoff, so a player view that
/// held the engine strongly would pin the outgoing one.
@Suite("Player engine ownership")
@MainActor
struct PlayerEngineOwnershipTests {
    @Test func aVideoSurfaceKeptPastItsEngineDoesNotKeepItAlive() async throws {
        weak var probe: SampleBufferPlayerEngine?
        var surface: SampleBufferVideoSurface

        do {
            let engine = SampleBufferPlayerEngine()
            probe = engine
            surface = SampleBufferVideoSurface(engine: engine)
            engine.shutdown()
        }

        // Shutdown finishes on the engine's own tasks before the last
        // reference goes.
        try await Polling.untilMainActor(timeout: .seconds(2), pollInterval: .milliseconds(10)) {
            probe == nil
        }
        #expect(probe == nil)
        #expect(surface.engine == nil)
    }

    /// Every stored engine in a player view goes through `PlayerEngineRef` or
    /// is `weak`. Reads the sources, so a new view cannot opt out unnoticed.
    @Test func playerViewsNeverStoreTheEngineStrongly() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Lagoon/Features/Playback/Views")
        let files = try FileManager.default.contentsOfDirectory(at: views, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)

        let storedEngine = #/^\s*(?:@\w+\s+)*(?:private\s+|fileprivate\s+)?(?:weak\s+)?(?:let|var)\s+\w*[eE]ngine\w*\s*:\s*\(?\s*(?:any\s+)?(?:PlayerEngine|SampleBufferPlayerEngine)\b/#
        var strong: [String] = []
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines)
            for (number, line) in lines.enumerated() where line.contains(storedEngine) {
                if line.contains("weak ") || line.contains("@PlayerEngineRef") { continue }
                strong.append("\(file.lastPathComponent):\(number + 1)")
            }
        }
        #expect(strong.isEmpty, "player views store the engine strongly: \(strong)")
    }
}
