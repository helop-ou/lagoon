#if os(tvOS)
import SwiftUI
import Testing
import UIKit
@testable import Lagoon

@Suite("Siri Remote touch-surface tap")
@MainActor
struct RemoteTouchTapTests {
    @Test func touchTapRecognizerDoesNotConsumeSelectPresses() throws {
        let controller = MenuGateHostingController(rootView: EmptyView())
        controller.loadViewIfNeeded()

        let recognizer = try #require(controller.remoteTouchTapRecognizer)
        #expect(recognizer.allowedPressTypes.isEmpty)
        #expect(
            recognizer.allowedTouchTypes
                == [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        )
        #expect(!recognizer.cancelsTouchesInView)
    }

    @Test func recognizedTouchTapUsesTheLatestHandler() {
        let controller = MenuGateHostingController(rootView: EmptyView())
        var count = 0
        controller.onRemoteTouchTap = { count += 1 }
        controller.remoteTouchTapRecognized()
        #expect(count == 1)

        // UIViewControllerRepresentable refreshes this closure as SwiftUI
        // state changes; the recognizer must not retain the first render's
        // handler.
        controller.onRemoteTouchTap = { count += 10 }
        controller.remoteTouchTapRecognized()
        #expect(count == 11)
    }
}
#endif
