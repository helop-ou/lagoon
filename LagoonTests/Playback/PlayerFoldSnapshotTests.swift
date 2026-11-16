#if os(iOS)
import LagoonEngine
import SwiftUI
import Testing
import UIKit
@testable import Lagoon

/// A partly folded iPhone Duo gives the picture one side of the fold and the
/// controls the other.
@Suite("Player fold snapshots", .serialized)
@MainActor
struct PlayerFoldSnapshotTests {
    /// The open Duo's inner screen in points, held tall and held wide.
    private static let tall = CGSize(width: 669, height: 951)
    private static let wide = CGSize(width: 951, height: 669)
    private static let foldWidth: CGFloat = 12

    /// Folded like a laptop: the fold runs across the middle.
    private static let laptopFold = CGRect(x: 0, y: (tall.height - foldWidth) / 2, width: tall.width, height: foldWidth)
    /// Folded like a book: the fold runs down the middle.
    private static let bookFold = CGRect(x: (wide.width - foldWidth) / 2, y: 0, width: foldWidth, height: wide.height)

    /// The toolbar's buttons join the controls, and the Up Next card lies
    /// over the picture's corner, clear of the subtitles.
    @Test func aLaptopPosePutsThePictureAboveTheFoldAndTheControlsBelow() async throws {
        try await verify("player-duo-laptop", fold: Self.laptopFold, size: Self.tall)
    }

    /// The card stays above the transport, where the side has the height.
    @Test func aBookPosePutsThePictureBeforeTheFoldAndTheControlsAfter() async throws {
        try await verify("player-duo-book", fold: Self.bookFold, size: Self.wide)
    }

    @Test func anOpenDuoKeepsTheControlsOverThePicture() async throws {
        try await verify("player-duo-open", fold: nil, size: Self.tall)
    }

    /// In the credits with an Up Next card that waits for a tap, so no
    /// countdown fill moves between renders.
    private func automation() throws -> PlaybackAutomation {
        let suite = "PlayerFoldSnapshotTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(AutoplayMode.card.rawValue, forKey: AutoplayMode.defaultsKey)
        let automation = PlaybackAutomation(defaults: defaults)
        automation.beginItem(segments: [MediaSegment(id: "outro", kind: .outro, start: 2_400, end: 2_520)])
        automation.setNextUpAvailable(true)
        automation.tick(position: 2_410, duration: 2_520)
        return automation
    }

    private func verify(
        _ name: String,
        fold: CGRect?,
        size: CGSize,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let engine = PlayingEngine()
        // The player holds its engine weakly.
        defer { withExtendedLifetime(engine) {} }
        let image = try #require(
            await render(player(engine: engine, automation: try automation(), fold: fold, size: size), size: size),
            sourceLocation: sourceLocation
        )
        try await Snapshot.verify(image, named: name, sourceLocation: sourceLocation)
    }

    /// The player brings its own navigation stack and toolbar, which
    /// `Snapshot.verify(_:named:size:)` would nest and hide.
    private func render(_ view: some View, size: CGSize) async -> CGImage? {
        let host = UIHostingController(rootView: view
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.dynamicTypeSize, .large)
            .environment(\.displayScale, Snapshot.scale))
        host.view.backgroundColor = .black
        host.safeAreaRegions = []
        // The tests run inside the app, so its scene is there.
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return nil }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        for _ in 0..<3 { await Task.yield() }
        host.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = Snapshot.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }.cgImage
    }

    /// The player as a pose lays it out, with the fold drawn in so the
    /// picture shows what stays clear of it.
    private func player(engine: PlayingEngine, automation: PlaybackAutomation, fold: CGRect?, size: CGSize) -> some View {
        CustomPlayerView(
            engine: engine,
            playbackIdentity: "fold",
            info: PlayerItemInfo(title: "The Rookie", subtitle: "S4 E2 · Five Minutes", facts: []),
            automation: automation,
            onDismiss: {},
            nextUp: NextUpEpisode(title: "In the Line of Fire", subtitle: "S4 E3"),
            episodeButtons: PlayerEpisodeButtons(hasPrevious: true, hasNext: true)
        ) {
            // A flat 16:9 picture: clear glass refracts artwork a little
            // differently from one render to the next.
            Color.black.overlay(Color(white: 0.3).aspectRatio(16 / 9, contentMode: .fit))
        }
        .environment(\.foldFramesOverride, fold.map { [$0] })
        .overlay(alignment: .topLeading) {
            if let fold {
                Color.red.opacity(0.5)
                    .frame(width: fold.width, height: fold.height)
                    .offset(x: fold.minX, y: fold.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

@Observable
private final class PlayingEngine: PlayerEngine {
    var bufferState = PlaybackBufferState.empty
    var timePosition: Double = 2_410
    var duration: Double = 2_520
    var isPaused = false
    var isBuffering = false
    var rate: Double = 1
    var stallCount = 0
    var videoSize: CGSize? = CGSize(width: 1920, height: 1080)
    var audioTracks: [PlayerTrack] = []
    var subtitleTracks: [PlayerTrack] = []
    var currentSubtitleText: String? = "We're five minutes out."
    var currentSubtitleImages: [SubtitleImage] = []
    var audioDelay: Double = 0
    var displayMatchRequest: DisplayMatchRequest?

    func play() {}
    func pause() {}
    func togglePause() {}
    func setRate(_ rate: Double) {}
    func seek(by seconds: Double) {}
    func seek(to seconds: Double) {}
    func selectAudioTrack(id: Int?) {}
    func selectSubtitleTrack(id: Int?) {}
    func addExternalSubtitle(_ track: ExternalSubtitleTrack) {}
    func setAudioDelay(_ seconds: Double) {}
}
#endif
