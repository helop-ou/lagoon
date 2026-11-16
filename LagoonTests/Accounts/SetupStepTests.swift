import Foundation
import Testing
@testable import Lagoon

@Suite("Setup steps")
@MainActor
struct SetupStepTests {
    @Test func theStepsRunFromTheLookToTheReportsAndBack() {
        #expect(SetupStep.allCases == [.look, .languages, .subtitleLook, .reports])
        // Forward from the first visits each once and stops.
        var walked: [SetupStep] = []
        var step: SetupStep? = .look
        while let current = step {
            walked.append(current)
            step = current.next
        }
        #expect(walked == SetupStep.allCases)
        // Back from the last does the same the other way.
        walked = []
        step = .reports
        while let current = step {
            walked.append(current)
            step = current.previous
        }
        #expect(walked == SetupStep.allCases.reversed())
    }

    @Test func eachStepSaysWhereItIsAndWhatItAsks() {
        #expect(SetupStep.allCases.map(\.position) == ["Step 1 of 4", "Step 2 of 4", "Step 3 of 4", "Step 4 of 4"])
        #expect(Set(SetupStep.allCases.map(\.title)).count == 4)
        #expect(Set(SetupStep.allCases.map(\.message)).count == 4)
        #expect(SetupStep.allCases.allSatisfy { !$0.title.isEmpty && !$0.message.isEmpty })
    }

    @Test func theSetupOffersTheCommonLanguagesAndTheOneInUse() throws {
        let common = SubtitlePreferencesStore.commonLanguageChoices
        #expect(SetupLanguagesStepView.languages(including: nil).map(\.value) == common.map(Optional.some))
        // A common language in use is not listed twice.
        let first = try #require(common.first)
        #expect(SetupLanguagesStepView.languages(including: first).count == common.count)
        // One that is not common is put first, so the menu shows the choice it stands on.
        let rare = try #require(["is", "mt", "cy", "eu"].first { !common.contains($0) })
        let withRare = SetupLanguagesStepView.languages(including: rare)
        #expect(withRare.first?.value == rare)
        #expect(withRare.count == common.count + 1)
        #expect(withRare.allSatisfy { !$0.title.isEmpty })
    }
}
