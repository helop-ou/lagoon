#if os(tvOS)
import AVFoundation
import AVKit
import UIKit

/// Asks the Apple TV to switch its display output to match the playing
/// video (HEL-64) — the thing AVPlayerViewController does automatically
/// and this custom player therefore has to do by hand.
///
/// Why it matters beyond correctness: without a mode switch the display
/// stays at its idle mode (typically 60 Hz, whatever range the UI runs
/// in) and the compositor must cadence-convert and tone-map every video
/// frame. That per-pixel work is the standing suspect for the hardware
/// frame drops that hit full 3840×2160 HDR10 titles while a 3840×1600
/// letterbox encode of the same codec/range/bitrate plays clean.
///
/// The request is criteria, not a command: the system only honors it when
/// the user has enabled Match Content (frame rate / dynamic range) in
/// tvOS Settings → Video and Audio. `statusDescription` reports each
/// layer separately — whether a display manager was reachable at all,
/// what the user setting says, and how many real mode switches the
/// system has posted — because the first hardware run showed "off" that
/// could have meant either "disabled" or "never reached", and an A/B
/// can't run on an ambiguous gate. Passing nil returns the display to
/// the system's default.
@MainActor
enum DisplayModeMatcher {
    /// Mode switches the system has announced since launch
    /// (`AVDisplayManagerModeSwitchStart`) — proof a request actually
    /// moved the display, whether or not anyone saw the blink.
    private(set) static var modeSwitchCount = 0
    private static var observerInstalled = false

    static func apply(_ request: DisplayMatchRequest?) {
        installObserverIfNeeded()
        guard let manager = displayManager() else { return }
        manager.preferredDisplayCriteria = request.map {
            AVDisplayCriteria(refreshRate: $0.frameRate, formatDescription: $0.formatDescription)
        }
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
