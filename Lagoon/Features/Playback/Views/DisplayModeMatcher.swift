#if os(tvOS)
import AVFoundation
import AVKit
import UIKit

/// Asks the Apple TV to match display output to the playing video — what
/// AVPlayerViewController does automatically and this player must do by hand.
///
/// Without it the display stays at its idle mode and the compositor
/// cadence-converts and tone-maps every frame. That is the standing suspect
/// for the hardware drops on full 3840×2160 HDR10 titles when a 3840×1600
/// encode of the same codec, range and bitrate plays clean.
///
/// Criteria, not a command: honoured only with Match Content enabled in tvOS
/// Settings. `statusDescription` reports display manager reachability, the
/// user setting and real switches posted separately, because the first
/// hardware run showed "off" that could have meant "disabled" or "never
/// reached" — an A/B cannot run on an ambiguous gate. nil restores the
/// default.
@MainActor
enum DisplayModeMatcher {
    /// Mode switches the system has announced since launch
    /// (`AVDisplayManagerModeSwitchStart`) — proof a request actually
    /// moved the display, whether or not anyone saw the blink.
    private(set) static var modeSwitchCount = 0
    private static var observerInstalled = false

    /// The last request handed to `apply`, so re-stating it is free. Callers
    /// re-apply on every scene activation and on every engine change, and an
    /// assignment that reaches the display manager risks a real HDMI round
    /// trip — a black screen mid-film. Compare before assigning rather than
    /// trusting AVDisplayManager to notice the criteria did not change.
    private static var appliedRequest: DisplayMatchRequest??

    static func apply(_ request: DisplayMatchRequest?) {
        installObserverIfNeeded()
        if let appliedRequest, appliedRequest == request { return }
        // Recorded only past the manager lookup: a request made before any
        // window exists was never applied and must not be remembered as if
        // it were, or the real one later would be skipped.
        guard let manager = displayManager() else { return }
        manager.preferredDisplayCriteria = request.map {
            AVDisplayCriteria(refreshRate: $0.frameRate, formatDescription: $0.formatDescription)
        }
        appliedRequest = request
    }

    /// One phrase for the HUD naming which layer answered: "no window" /
    /// "no manager" (lookup failed — nothing was applied), or the user
    /// setting plus any switch activity.
    static var statusDescription: String {
        guard !windows().isEmpty else { return "no window" }
        guard let manager = displayManager() else { return "no manager" }
        var status = manager.isDisplayCriteriaMatchingEnabled ? "system on" : "system off"
        if manager.isDisplayModeSwitchInProgress { status += " · switching" }
        if modeSwitchCount > 0 { status += " · switched ×\(modeSwitchCount)" }
        return status
    }

    /// The refresh rate of the screen the app's scene is on, for the decode
    /// trace. `UIScreen.main` is deprecated in favour of a screen found
    /// through a window's scene; nil before any window exists.
    static var maximumFramesPerSecond: Int? {
        windows().first?.windowScene?.screen.maximumFramesPerSecond
    }

    private static func displayManager() -> AVDisplayManager? {
        // Any window of the scene reaches the screen's manager — do not
        // insist on the key window (during a fullScreenCover the key flag
        // is not guaranteed to sit where expected, and returning nil here
        // silently disabled the whole feature on the first hardware run).
        let all = windows()
        let window = all.first(where: \.isKeyWindow) ?? all.first
        // The simulator's UIWindow never implements AVKit's category —
        // calling it straight throws doesNotRecognizeSelector and killed
        // the player on this feature's very first sim run. There are no
        // display modes to match there anyway.
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
