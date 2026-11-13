import Testing
@testable import Lagoon

/// A classified stretch of a title: which positions it holds, which kinds a
/// viewer can skip, and the server strings its kinds are read from.
@Suite("Media segment")
struct MediaSegmentTests {
    @Test func aSegmentHoldsItsStartButNotItsEnd() {
        let intro = MediaSegment(id: "intro", kind: .intro, start: 10, end: 70)

        #expect(intro.contains(10))
        #expect(intro.contains(69.9))
        #expect(!intro.contains(70))
        #expect(!intro.contains(9.9))
    }

    @Test func onlyIntrosAndRecapsCanBeSkipped() {
        let kinds: [MediaSegment.Kind] = [.intro, .outro, .recap, .preview, .commercial, .other]

        #expect(kinds.filter(\.isSkippable) == [.intro, .recap])
    }

    @Test func aRecapIsNamedOnItsSkipButton() {
        #expect(MediaSegment.Kind.recap.skipTitle == "Skip Recap")
        #expect(MediaSegment.Kind.intro.skipTitle == "Skip Intro")
    }

    /// Jellyfin sends `MediaSegmentType` capitalised. A type it adds later
    /// reads as none of these, and the client files it under `other`.
    @Test func kindsAreReadFromJellyfinsSegmentTypes() {
        #expect(MediaSegment.Kind(rawValue: "Intro") == .intro)
        #expect(MediaSegment.Kind(rawValue: "Outro") == .outro)
        #expect(MediaSegment.Kind(rawValue: "Recap") == .recap)
        #expect(MediaSegment.Kind(rawValue: "Preview") == .preview)
        #expect(MediaSegment.Kind(rawValue: "Commercial") == .commercial)
        #expect(MediaSegment.Kind(rawValue: "Unknown") == nil)
    }
}
