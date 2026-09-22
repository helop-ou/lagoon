#if os(tvOS)
import AVFoundation
import AVKit
import LagoonEngine
import UIKit

/// Asks the Apple TV to match display output to the video, as
/// AVPlayerViewController does. Without it the compositor cadence-converts
/// and tone-maps every frame.
///
/// Criteria, not a command: honoured only with Match Content on in tvOS
/// Settings. nil restores the default.
@MainActor
enum DisplayModeMatcher {
    /// `AVDisplayManagerModeSwitchStart` posts since launch.
    private(set) static var modeSwitchCount = 0
    private static var observerInstalled = false

    /// Callers re-apply often, and any assignment to the display manager
    /// risks an HDMI round trip (a black screen), so compare first.
    private static var appliedRequest: DisplayMatchRequest??

    static func apply(_ request: DisplayMatchRequest?) {
        installObserverIfNeeded()
        if let appliedRequest, appliedRequest == request { return }
        // Record only once applied, or a later real request is skipped.
        guard let manager = displayManager() else { return }
        manager.preferredDisplayCriteria = request.map {
            AVDisplayCriteria(refreshRate: $0.frameRate, formatDescription: $0.formatDescription)
        }
        appliedRequest = request
    }

    /// HUD phrase: which lookup failed, or the user setting and switches.
    static var statusDescription: String {
        guard !windows().isEmpty else { return "no window" }
        guard let manager = displayManager() else { return "no manager" }
        var status = manager.isDisplayCriteriaMatchingEnabled ? "system on" : "system off"
        if manager.isDisplayModeSwitchInProgress { status += " · switching" }
        if modeSwitchCount > 0 { status += " · switched ×\(modeSwitchCount)" }
        return status
    }

    /// For the decode trace. nil before any window exists.
    static var maximumFramesPerSecond: Int? {
        windows().first?.windowScene?.screen.maximumFramesPerSecond
    }

    private static func displayManager() -> AVDisplayManager? {
        // Do not require the key window: under a fullScreenCover it may not
        // be where expected, and nil silently disables matching.
        let all = windows()
        let window = all.first(where: \.isKeyWindow) ?? all.first
        // The simulator's UIWindow lacks AVKit's category; calling it
        // throws doesNotRecognizeSelector.
        guard let window, window.responds(to: #selector(getter: UIWindow.avDisplayManager)) else {
            return nil
        }
        return window.avDisplayManager
    }

    private static func windows() -> [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
    }

    private static func installObserverIfNeeded() {
        guard !observerInstalled else { return }
        observerInstalled = true
        NotificationCenter.default.addObserver(
            forName: .AVDisplayManagerModeSwitchStart,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                modeSwitchCount += 1
            }
        }
    }
}
#endif
