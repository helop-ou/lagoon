import Testing
@testable import Lagoon

@Suite("Ticks")
struct TicksTests {
    @Test func aTickIsOneHundredNanoseconds() {
        #expect(Ticks.perSecond == 10_000_000)
        #expect(Ticks.ticks(1.5) == 15_000_000)
        #expect(Ticks.seconds(15_000_000) == 1.5)
        #expect(Ticks.ticks(0) == 0)
    }
}
