#if os(tvOS)
import SwiftUI
import Testing
import UIKit
@testable import Lagoon

/// The top-left profile button with the time inside its glass, focused and
/// not. Focus needs a key window and a focused tab bar to come from, as in
/// the app.
@Suite("Profile button snapshots", .serialized)
@MainActor
struct ProfileButtonSnapshotTests {
    private static let size = CGSize(width: 320, height: 120)
    private static let utc = TimeZone(identifier: "UTC")!

    private let time = try! Date("2026-11-03T15:07:00Z", strategy: .iso8601)

    @Test func theTimeSitsBeforeThePortraitInOneCapsule() async throws {
        try await Snapshot.verify(control(image: await portrait()), named: "profile", size: Self.size)
    }

    @Test func aPersonGlyphStandsInUntilThePortraitRenders() async throws {
        try await Snapshot.verify(control(image: nil), named: "profile-glyph", size: Self.size)
    }

    @Test func focusLiftsTheWholeCapsule() async throws {
        let image = try await renderFocused(control(image: await portrait()))
        try await Snapshot.verify(image, named: "profile-focused")
    }

    /// The snapshots draw the control at a fixed time. The button itself
    /// feeds it the current one, at Refresh's height.
    @Test func theButtonShowsTheCurrentTime() async throws {
        let before = Date()
        let host = UIHostingController(rootView: ProfileButton(
            image: nil,
            profileName: "Jaagop",
            isAvailable: true,
            moveDownAction: nil,
            moveLeftAction: nil,
            action: {}
        ))
        host.safeAreaRegions = []
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: Self.size)
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        for _ in 0..<3 { await Task.yield() }
        host.view.layoutIfNeeded()
        let after = Date()

        let button = try #require(host.view.firstSubview(of: TopChromeButton.self))
        let shown = [before, after].map {
            TVProfileControl.clockText(for: $0, locale: .autoupdatingCurrent, timeZone: .autoupdatingCurrent)
        }
        #expect(shown.contains(button.configuration?.title ?? ""))
        #expect(button.bounds.height == Metrics.topChromeButtonSize)
    }

    private func portrait() async -> UIImage? {
        let account = StoredAccount(
            serverURL: URL(string: "https://jellyfin.snapshot.test")!,
            serverName: nil,
            userId: "user",
            userName: "Jaagop"
        )
        return await ProfilePortrait.image(
            for: account, size: Metrics.chromeProfilePortraitSize, displayScale: Snapshot.scale
        )
    }

    private func control(image: UIImage?) -> some View {
        TVProfileControl(
            image: image,
            profileName: "Jaagop",
            time: time,
            allowsFocus: true,
            tracksTopChrome: false,
            moveDownAction: nil,
            moveLeftAction: nil,
            topChromeOffsetChanged: { _ in },
            action: {}
        )
        .frame(height: Metrics.topChromeButtonSize)
        .padding(Metrics.Space.xl)
        .environment(\.timeZone, Self.utc)
    }

    /// Focuses a tab bar beside the control, which lets the top chrome take
    /// focus, then moves focus to the control and draws only the control.
    private func renderFocused(_ view: some View) async throws -> CGImage {
        let host = UIHostingController(rootView: view
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.displayScale, Snapshot.scale)
        )
        host.view.backgroundColor = .black
        host.safeAreaRegions = []
        let root = FocusRoot()
        root.addChild(host)
        root.view.addSubview(host.view)
        host.view.frame = CGRect(origin: .zero, size: Self.size)
        host.didMove(toParent: root)
        let tabBar = UITabBar()
        tabBar.items = [UITabBarItem(title: "Home", image: nil, tag: 0)]
        tabBar.frame = CGRect(x: Self.size.width, y: 0, width: 400, height: 80)
        root.view.addSubview(tabBar)

        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: Self.size.width + 400, height: Self.size.height)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        let focus = try #require(UIFocusSystem.focusSystem(for: window))
        focus.requestFocusUpdate(to: tabBar)
        focus.updateFocusIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let button = try #require(host.view.firstSubview(of: TopChromeButton.self))
        root.preferred = button
        root.setNeedsFocusUpdate()
        root.updateFocusIfNeeded()
        #expect(button.isFocused)

        // The focus lift animates, slower under a full run's load. Draw
        // until two frames in a row match.
        let format = UIGraphicsImageRendererFormat()
        format.scale = Snapshot.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: Self.size, format: format)
        func draw() throws -> CGImage {
            try #require(renderer.image { _ in
                host.view.drawHierarchy(in: CGRect(origin: .zero, size: Self.size), afterScreenUpdates: true)
            }.cgImage)
        }
        var frame = try draw()
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(200))
            let next = try draw()
            if Snapshot.compare(next, with: frame).fraction == 0 { return next }
            frame = next
        }
        Issue.record("The focused button never settled")
        return frame
    }
}

private final class FocusRoot: UIViewController {
    var preferred: (any UIFocusEnvironment)?

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        preferred.map { [$0] } ?? super.preferredFocusEnvironments
    }
}

private extension UIView {
    func firstSubview<View: UIView>(of type: View.Type) -> View? {
        for subview in subviews {
            if let match = subview as? View ?? subview.firstSubview(of: type) { return match }
        }
        return nil
    }
}
#endif
