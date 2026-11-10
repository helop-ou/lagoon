import Testing
@testable import Lagoon

/// An offset fixes a subtitle file, so it stays with the item: a fallback
/// rung, an episode coming back round or a reopened player starts in step.
@Suite("Subtitle offset memory")
struct SubtitleOffsetMemoryTests {
    @Test func anOffsetStaysWithItsItem() {
        var memory = SubtitleOffsetMemory()
        memory.remember(1.5, for: "item-a")
        memory.remember(-0.3, for: "item-b")
        #expect(memory.offset(for: "item-a") == 1.5)
        #expect(memory.offset(for: "item-b") == -0.3)
        #expect(memory.offset(for: "item-c") == 0)
    }

    @Test func settingItBackToZeroForgetsIt() {
        var memory = SubtitleOffsetMemory()
        memory.remember(2, for: "item-a")
        memory.remember(0, for: "item-a")
        #expect(memory.offset(for: "item-a") == 0)
    }

    @Test func anUnknownItemIsNeverRemembered() {
        var memory = SubtitleOffsetMemory()
        memory.remember(2, for: "")
        #expect(memory.offset(for: "") == 0)
    }
}
