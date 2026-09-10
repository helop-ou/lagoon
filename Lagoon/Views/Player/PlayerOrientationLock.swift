#if os(iOS)
import SwiftUI
import UIKit

/// UIKit only asks the app what orientations it supports through this
/// delegate callback — there is no other run-time hook to narrow them once
/// the process has launched. Because it overrides whatever the Info.plist
/// lists wholesale, `PlayerOrientationLock.defaultMask` has to restate the
/// per-idiom lists (`INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone`
/// / `_iPad`) itself rather than deferring to them.
final class LagoonAppDelegate: NSObject, UIApplicationDelegate {
    static var supportedOrientations: UIInterfaceOrientationMask = PlayerOrientationLock.defaultMask

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.supportedOrientations
    }
}

/// iPhone landscape lock for the full-screen player (HEL-153). The lock
/// applies only on iPhone: iPad is deliberately left free to rotate — Apple's
/// own TV app rotates freely there, and iPad multitasking expects every
/// orientation to stay available — so `lockToLandscape()`/`unlock()` are
/// no-ops on that idiom.
enum PlayerOrientationLock {
    static var defaultMask: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    static func lockToLandscape() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        LagoonAppDelegate.supportedOrientations = .landscape
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            updateSupportedOrientations(in: windowScene)
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { _ in }
        }
    }

    static func unlock() {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        LagoonAppDelegate.supportedOrientations = defaultMask
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            // No geometry request here: once the mask allows it again, UIKit
            // rotates back to match the physical device on its own.
            updateSupportedOrientations(in: windowScene)
        }
    }

    /// Walks the tab root and every presented view controller (the player's
    /// `fullScreenCover` included) so each re-queries the mask rather than
    /// keeping whatever it resolved at presentation time.
    private static func updateSupportedOrientations(in scene: UIWindowScene) {
        var controller = scene.keyWindow?.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
    }
}
#endif
