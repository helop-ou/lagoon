#if os(iOS)
import Testing
@testable import Lagoon

/// iOS double-tap seek: another double-tap on the same side while the glyph
/// is up adds a step; the other side starts over.
@Suite("Touch seek policy")
struct TouchSeekPolicyTests {
    @Test func firstTapIsOneStep() {
        #expect(TouchSeekPolicy.accumulated(previous: nil, sameDirection: false) == 10)
        #expect(TouchSeekPolicy.accumulated(previous: nil, sameDirection: true) == 10)
    }

    @Test func sameDirectionStacks() {
        #expect(TouchSeekPolicy.accumulated(previous: 10, sameDirection: true) == 20)
        #expect(TouchSeekPolicy.accumulated(previous: 20, sameDirection: true) == 30)
    }

    @Test func oppositeDirectionStartsOver() {
        #expect(TouchSeekPolicy.accumulated(previous: 30, sameDirection: false) == 10)
    }
}
#endif
