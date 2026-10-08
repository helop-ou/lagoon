import Testing
@testable import Lagoon

/// The hero moves on by itself only while nobody could be interrupted.
@Suite("Hero auto-advance")
struct HeroAutoAdvanceTests {
    private let idle = HeroAutoAdvance(
        isActive: true,
        isVisible: true,
        isSceneActive: true,
        itemCount: 2,
        reduceMotion: false,
        voiceOverEnabled: false,
        isScrolling: false,
        isFocused: false
    )

    @Test func anIdleVisibleHeroWithSomewhereToGoAdvances() {
        #expect(idle.isAllowed)
    }

    @Test(arguments: [
        \HeroAutoAdvance.isActive, \.isVisible, \.isSceneActive,
    ] as [WritableKeyPath<HeroAutoAdvance, Bool>])
    func aHeroNobodyCanSeeHoldsStill(condition: WritableKeyPath<HeroAutoAdvance, Bool>) {
        var hero = idle
        hero[keyPath: condition] = false
        #expect(!hero.isAllowed)
    }

    @Test(arguments: [
        \HeroAutoAdvance.reduceMotion, \.voiceOverEnabled, \.isScrolling, \.isFocused,
    ] as [WritableKeyPath<HeroAutoAdvance, Bool>])
    func aViewerWhoIsBusyOrAskedForLessMotionIsNotInterrupted(condition: WritableKeyPath<HeroAutoAdvance, Bool>) {
        var hero = idle
        hero[keyPath: condition] = true
        #expect(!hero.isAllowed)
    }

    @Test func aSingleSlideHasNowhereToGo() {
        var hero = idle
        hero.itemCount = 1
        #expect(!hero.isAllowed)
    }
}
