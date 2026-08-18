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
/// tvOS Settings → Video and Audio — `systemMatchingEnabled` reports
/// that, and the HUD surfaces both sides so an A/B can't silently run
/// ungated. Passing nil returns the display to the system's default.
@MainActor
enum DisplayModeMatcher {
    static func apply(_ request: DisplayMatchRequest?) {
        guard let manager = displayManager() else { return }
        manager.preferredDisplayCriteria = request.map {
            AVDisplayCriteria(refreshRate: $0.frameRate, formatDescription: $0.formatDescription)
        }
    }

    /// The user's tvOS Match Content setting — criteria are ignored while
    /// this is false, and defaults off on a factory device.
    static var systemMatchingEnabled: Bool {
        displayManager()?.isDisplayCriteriaMatchingEnabled ?? false
    }

    private static func displayManager() -> AVDisplayManager? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        // The simulator's UIWindow never implements AVKit's category —
        // calling it straight throws doesNotRecognizeSelector and killed
        // the player on this feature's very first sim run. There are no
        // display modes to match there anyway.
        guard let window, window.responds(to: #selector(getter: UIWindow.avDisplayManager)) else {
            return nil
        }
        return window.avDisplayManager
    }
}
#endif
