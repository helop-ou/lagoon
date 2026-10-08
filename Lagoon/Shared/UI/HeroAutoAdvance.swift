/// When the hero may move on by itself: on screen, in front, with somewhere
/// to go, and never under a viewer who is scrolling, has focus on it, reads
/// with VoiceOver or asked for less motion.
nonisolated struct HeroAutoAdvance {
    var isActive: Bool
    var isVisible: Bool
    var isSceneActive: Bool
    var itemCount: Int
    var reduceMotion: Bool
    var voiceOverEnabled: Bool
    var isScrolling: Bool
    var isFocused: Bool

    var isAllowed: Bool {
        isActive && isVisible && isSceneActive && itemCount > 1
            && !reduceMotion && !voiceOverEnabled && !isScrolling && !isFocused
    }
}
