#if DEBUG
import LagoonEngine
import Observation
import SwiftUI

private enum PlayerComponentPreview: String, CaseIterable, Identifiable {
    case skipIntroCountdown
    case skipIntroButton
    case skipRecap
    case nextEpisodeCountdown
    case nextEpisodeCard
    case subtitle
    case seekForward
    case buffering
    case watchTogetherToast
    case watchTogetherSheet
    case playerPanel
    case playerTransport
    case legalAddress

    var id: String { rawValue }

    var title: String {
        switch self {
        case .skipIntroCountdown: "Skip Intro — Countdown"
        case .skipIntroButton: "Skip Intro — Button"
        case .skipRecap: "Skip Recap"
        case .nextEpisodeCountdown: "Next Episode — Countdown"
        case .nextEpisodeCard: "Next Episode — Card"
        case .subtitle: "Text Subtitle"
        case .seekForward: "Seek Forward"
        case .buffering: "Buffering"
        case .watchTogetherToast: "Watch Together — Toast"
        case .watchTogetherSheet: "Watch Together — Sheet"
        case .playerPanel: "Player Panel"
        case .playerTransport: "Player Transport"
        case .legalAddress: "Legal Address — QR"
        }
    }

    var hasCountdown: Bool {
        self == .skipIntroCountdown || self == .nextEpisodeCountdown
    }
}

/// Development-build gallery of the real player components, so chrome can be
/// approved without finding media that triggers each state.
struct DeveloperSettingsView: View {
    let subtitleStyle: SubtitleRenderStyle

    @State private var selectedPreview = PlayerComponentPreview.skipIntroCountdown
    @State private var countdown: PlaybackCountdown?
    @State private var showsPlayerPanelPreview = false
    @State private var showsPlayerTransportPreview = false
    @State private var showsWatchTogetherPreview = false
    #if os(tvOS)
    @State private var presentedLegalAddress: LegalAddress?
    #endif

    var body: some View {
        #if os(tvOS)
        TVSettingsPage(
            "Developer",
            description: "Preview Lagoon's real player components in isolation. This destination is compiled only into Debug builds."
        ) {
            TVSettingsSection(
                "Player Components",
                footer: "Choose a component, inspect it against a video-like background, and replay timed states before changing the production design."
            ) {
                TVSettingsMenuPicker(
                    title: "Component",
                    valueTitle: selectedPreview.title,
                    accessibilityIdentifier: "settings.developer.component",
                    selection: $selectedPreview,
                    options: PlayerComponentPreview.allCases.map {
                        TVSettingsOption(value: $0, title: $0.title)
                    }
                )

                previewCanvas

                if selectedPreview.hasCountdown {
                    Button(action: replayCountdown) {
                        TVSettingsActionLabel("Replay Countdown")
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("settings.developer.replay")
                }
            }
        }
        .fullScreenCover(isPresented: $showsPlayerPanelPreview) {
            PlayerPanelComponentPreviewScreen()
        }
        .fullScreenCover(isPresented: $showsPlayerTransportPreview) {
            PlayerTransportComponentPreviewScreen()
        }
        .sheet(isPresented: $showsWatchTogetherPreview) {
            watchTogetherPreview
        }
        .sheet(item: $presentedLegalAddress) { address in
            legalAddressPreview(address)
        }
        #else
        Form {
            Section("Player Component") {
                Picker("Component", selection: $selectedPreview) {
                    ForEach(PlayerComponentPreview.allCases) { preview in
                        Text(preview.title).tag(preview)
                    }
                }
            }

            Section("Preview") {
                previewCanvas
                if selectedPreview.hasCountdown {
                    Button("Replay Countdown", action: replayCountdown)
                }
            }
        }
        .navigationTitle("Developer")
        .fullScreenCover(isPresented: $showsPlayerPanelPreview) {
            PlayerPanelComponentPreviewScreen()
        }
        .fullScreenCover(isPresented: $showsPlayerTransportPreview) {
            PlayerTransportComponentPreviewScreen()
        }
        .sheet(isPresented: $showsWatchTogetherPreview) {
            watchTogetherPreview
        }
        #endif
    }

    @ViewBuilder
    private var previewCanvas: some View {
        let canvas = previewCanvasContent
            .onChange(of: selectedPreview) { _, _ in
                countdown = nil
            }

        if selectedPreview == .playerPanel
            || selectedPreview == .playerTransport
            || selectedPreview == .watchTogetherSheet {
            // Do not turn this branch into a synthetic accessibility
            // element: its production tabs and rows must remain focusable.
            canvas
        } else {
            canvas
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(selectedPreview.title)
                .accessibilityIdentifier("settings.developer.preview")
        }
    }

    private var previewCanvasContent: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Metrics.panelCornerRadius)
                .fill(
                    LinearGradient(
                        colors: [.indigo.opacity(0.5), .black.opacity(0.95)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            componentPreview
                .padding(Metrics.Space.xl)
        }
        .frame(maxWidth: .infinity, minHeight: 360)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.panelCornerRadius))
    }

    @ViewBuilder
    private var componentPreview: some View {
        switch selectedPreview {
        case .skipIntroCountdown:
            PlayerSkipPrompt(
                title: String(localized: "Skip Intro"),
                showsCountdown: true,
                fill: 0.62,
                countdown: countdown,
                accessibilityIdentifier: "settings.developer.preview.skipIntroCountdown"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        case .skipIntroButton:
            PlayerSkipPrompt(
                title: String(localized: "Skip Intro"),
                showsCountdown: false,
                fill: 0,
                accessibilityIdentifier: "settings.developer.preview.skipIntroButton"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        case .skipRecap:
            PlayerSkipPrompt(
                title: String(localized: "Skip Recap"),
                showsCountdown: false,
                fill: 0,
                accessibilityIdentifier: "settings.developer.preview.skipRecap"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        case .nextEpisodeCountdown:
            PlayerNextUpCard(
                episode: previewEpisode,
                showsCountdown: true,
                fill: 0.62,
                countdown: countdown,
                hint: previewNextUpHint,
                accessibilityIdentifier: "settings.developer.preview.nextEpisodeCountdown"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        case .nextEpisodeCard:
            PlayerNextUpCard(
                episode: previewEpisode,
                showsCountdown: false,
                fill: 0,
                hint: previewNextUpHint,
                accessibilityIdentifier: "settings.developer.preview.nextEpisodeCard"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        case .subtitle:
            VStack {
                Spacer()
                PlayerSubtitleText(
                    text: "This is a subtitle preview.",
                    style: subtitleStyle,
                    accessibilityIdentifier: "settings.developer.preview.subtitle"
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .seekForward:
            PlayerSeekIndicator(
                forward: true,
                accessibilityIdentifier: "settings.developer.preview.seekForward"
            )
        case .buffering:
            ProgressView()
                .tint(.white)
                .accessibilityIdentifier("settings.developer.preview.buffering")
        case .watchTogetherToast:
            SyncPlayToastLabel(
                text: String(localized: "Alex joined"),
                accessibilityIdentifier: "settings.developer.preview.watchTogetherToast"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .watchTogetherSheet:
            VStack(spacing: Metrics.Space.l) {
                Image(systemName: "person.2.fill")
                    .font(Typography.glyph)
                Text("The real Watch Together screen, over this server's own groups. Starting one from here would name a title the server does not have, so it is for judging the page rather than the flow.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    showsWatchTogetherPreview = true
                } label: {
                    Label("Open Watch Together", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("settings.developer.watchTogether.open")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .legalAddress:
            VStack(spacing: Metrics.Space.l) {
                QRCodeView(text: Self.previewLegalAddressURL.absoluteString)
                Text("Both legal addresses are still nil, so this is the only way to see the code until the site is live. Point a phone at it from where you actually sit, not from in front of the screen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                #if os(tvOS)
                Button {
                    presentedLegalAddress = Self.previewLegalAddress
                } label: {
                    Label("Open the whole sheet", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("settings.developer.legalAddress.open")
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .playerPanel:
            VStack(spacing: Metrics.Space.l) {
                Image(systemName: "rectangle.inset.filled.and.person.filled")
                    .font(Typography.glyph)
                Text("The player panel uses the full screen so its layout and focus geometry match playback.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    showsPlayerPanelPreview = true
                } label: {
                    Label("Open Player Panel Preview", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("settings.developer.playerPanel.open")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .playerTransport:
            VStack(spacing: Metrics.Space.l) {
                Image(systemName: "slider.horizontal.below.rectangle")
                    .font(Typography.glyph)
                Text("The transport uses the full screen so its resting and scrubbing states can be judged over video-like content.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    showsPlayerTransportPreview = true
                } label: {
                    Label("Open Player Transport Preview", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("settings.developer.playerTransport.open")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// `MediaItem` is decode-only, so build one from JSON. The sheet only
    /// needs an argument; nothing it draws reads it.
    static let previewMediaItem: MediaItem? = {
        let json = Data(#"{"Id":"developer-preview","Name":"Rick and Morty","Type":"Episode"}"#.utf8)
        return try? JellyfinClient.decoder.decode(MediaItem.self, from: json)
    }()

    /// A real address, so the QR code has its final size.
    private static let previewLegalAddressURL = URL(string: "https://lagoon.helop.dev/privacy/")!

    #if os(tvOS)
    private static let previewLegalAddress = LegalAddress(
        id: "settings.developer.legalAddress",
        title: "Privacy Policy",
        url: previewLegalAddressURL
    )

    @ViewBuilder
    private func legalAddressPreview(_ address: LegalAddress) -> some View {
        LegalAddressSheet(address: address)
            .frame(width: Metrics.modalPanelSize.width)
            .presentationSizing(.fitted)
    }
    #endif

    @ViewBuilder
    private var watchTogetherPreview: some View {
        if let item = Self.previewMediaItem {
            WatchTogetherSheet(item: item, startPositionTicks: 0)
        } else {
            ErrorStateView(message: "The preview item could not be decoded.") {}
        }
    }

    private var previewEpisode: NextUpEpisode {
        NextUpEpisode(
            title: "The Next Chapter",
            subtitle: "S1 E4",
            imageURL: nil
        )
    }

    private var previewNextUpHint: LocalizedStringKey {
        #if os(tvOS)
        selectedPreview == .nextEpisodeCountdown
            ? "Select to play now · Back to stay"
            : "Select to play now"
        #else
        "Tap to play now"
        #endif
    }

    private func replayCountdown() {
        countdown = PlaybackCountdown(duration: .seconds(SkipMode.autoDelaySeconds))
    }
}

/// The production transport over varied luminance. Right/Left enters the real
/// tvOS scrub; touch platforms drag the same bar.
private struct PlayerTransportComponentPreviewScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var engine = PlayerPanelPreviewEngine()
    @State private var automation = PlaybackAutomation()

    var body: some View {
        CustomPlayerView(
            engine: engine,
            playbackIdentity: "player-transport-preview",
            bufferedFraction: 0.18,
            bufferedRanges: [
                PlaybackBufferedRange(lowerFraction: 0, upperFraction: 0.18),
                PlaybackBufferedRange(lowerFraction: 0.29, upperFraction: 0.62),
            ],
            info: previewInfo,
            automation: automation,
            onDismiss: { dismiss() }
        ) {
            previewSurface
        }
        .preferredColorScheme(.dark)
        .task {
            engine.timePosition = 404
        }
    }

    private var previewInfo: PlayerItemInfo {
        PlayerItemInfo(
            title: "Rick and Morty",
            subtitle: "S1 E1 · Pilot",
            overview: nil,
            facts: [],
            videoSummary: nil,
            posterURL: nil,
            chapters: [
                PlayerChapter(id: 0, name: "Cold Open", start: 0),
                PlayerChapter(id: 1, name: "The Garage", start: 312),
                PlayerChapter(id: 2, name: "Dimension 35-C", start: 724),
                PlayerChapter(id: 3, name: "End Credits", start: 1_240),
            ]
        )
    }

    private var previewSurface: some View {
        // Keep the shapes' 760pt width from shifting the player's controls.
        Color.black.overlay {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.16, blue: 0.28),
                    Color(red: 0.23, green: 0.08, blue: 0.22),
                    .black,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(.cyan.opacity(0.5))
                .frame(width: 540, height: 540)
                .blur(radius: 70)
                .offset(x: 430, y: -170)

            Circle()
                .fill(.purple.opacity(0.42))
                .frame(width: 680, height: 680)
                .blur(radius: 100)
                .offset(x: -500, y: 260)

            RoundedRectangle(cornerRadius: 48)
                .fill(.white.opacity(0.08))
                .frame(width: 760, height: 390)
                .rotationEffect(.degrees(-9))
                .offset(x: 150, y: -40)
        }
        }
        .ignoresSafeArea()
    }
}

/// The production `PlayerControlPanel` with representative state and local actions.
private struct PlayerPanelComponentPreviewScreen: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            LinearGradient(
                colors: [.indigo.opacity(0.5), .black.opacity(0.95)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            PlayerPanelComponentPreview(onDismiss: { dismiss() })
        }
        #if os(tvOS)
        .onExitCommand { dismiss() }
        #endif
    }
}

private struct PlayerPanelComponentPreview: View {
    let onDismiss: () -> Void
    @State private var selectedTab = PlayerPanelTab.info
    @State private var engine = PlayerPanelPreviewEngine()
    @State private var isPictureInPictureActive = false
    @State private var ignoresWait = false
    // Opens on the subtitle results browser; Done reveals the track list.
    @State private var subtitleSearch = SubtitleSearchCoordinator
        .previewingResults(PlayerPanelComponentPreview.subtitleResults)
    @FocusState private var panelFocus: PlayerControlFocus?

    var body: some View {
        PlayerControlPanelHost(
            engine: engine,
            selectedTab: $selectedTab,
            focus: $panelFocus,
            info: previewInfo,
            subtitleSearch: subtitleSearch,
            isPictureInPicturePossible: true,
            isPictureInPictureActive: isPictureInPictureActive,
            onTogglePictureInPicture: {
                isPictureInPictureActive.toggle()
            },
            // A group, so the Watch Together tab shows without joining one.
            together: previewTogether,
            onLeaveGroup: {},
            onSetIgnoreWait: { ignoresWait = $0 },
            onDismiss: onDismiss
        )
        .equatable()
        .overlay(alignment: .topLeading) {
            Text("Player panel performance")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Player panel performance")
                .accessibilityValue(
                    String(format: "memoryMB=%.1f", MemorySnapshot.current().footprintMB)
                )
                .accessibilityIdentifier("player.panel.performance")
                .allowsHitTesting(false)
        }
        .onChange(of: panelFocus) { _, focusedControl in
            if case .tab(let tab) = focusedControl {
                selectedTab = tab
            }
        }
        .task {
            // Match the live panel's post-mount focus claim.
            try? await Task.sleep(for: .milliseconds(225))
            guard !Task.isCancelled else { return }
            panelFocus = .tab(.info)
        }
    }

    private var previewTogether: PlayerTogetherState {
        PlayerTogetherState(
            groupName: "Alex's room",
            participants: ["Alex", "Development", "Robin"],
            state: .playing,
            ignoresWait: ignoresWait
        )
    }

    private var previewInfo: PlayerItemInfo {
        PlayerItemInfo(
            title: "Rick and Morty",
            subtitle: "S1 E1 · Pilot",
            overview: "Rick moves in with his daughter's family and establishes himself as a bad influence on Morty.",
            facts: ["22 min", "2013", "1080p", "VC-1", "Dolby Digital 5.1", "23.976 fps"],
            videoSummary: "VC-1 · 1080p · 1920×1080 · 23.976 fps",
            posterURL: nil
        )
    }

    /// Varied providers, formats, flags and download counts, to show the
    /// longest detail line.
    static let subtitleResults: [SubtitleCandidate] = [
        SubtitleCandidate(
            id: "preview-1",
            name: "Rick.and.Morty.S01E01.1080p.BluRay.x264-DEMAND",
            language: "eng",
            providerName: "OpenSubtitles",
            format: "srt",
            downloadCount: 48_213,
            isHashMatch: true
        ),
        SubtitleCandidate(
            id: "preview-2",
            name: "Rick and Morty - Pilot (English SDH)",
            language: "eng",
            providerName: "OpenSubtitles",
            format: "srt",
            downloadCount: 9_104,
            isHearingImpaired: true
        ),
        SubtitleCandidate(
            id: "preview-3",
            name: "Rick.and.Morty.S01E01.WEB-DL.forced",
            language: "eng",
            providerName: "Subscene",
            format: "ass",
            downloadCount: 412,
            isForced: true
        ),
        SubtitleCandidate(
            id: "preview-4",
            name: "Rick ja Morty - Pilootosa",
            language: "est",
            providerName: "OpenSubtitles",
            format: "srt",
            downloadCount: 87
        ),
        SubtitleCandidate(
            id: "preview-5",
            name: "Rick.and.Morty.S01E01.720p.HDTV.x264-IMMERSE",
            language: "eng",
            providerName: "Addic7ed",
            format: "vtt",
            downloadCount: 2_760
        ),
        SubtitleCandidate(
            id: "preview-6",
            name: "Rick y Morty - Piloto (Latino)",
            language: "spa",
            providerName: "Subscene",
            format: "srt",
            downloadCount: 15_940,
            isMachineTranslated: true
        ),
        SubtitleCandidate(
            id: "preview-7",
            name: "Rick et Morty - Pilote",
            language: "fra",
            providerName: "OpenSubtitles",
            format: "sub",
            downloadCount: 631
        ),
        SubtitleCandidate(
            id: "preview-8",
            name: "Rick and Morty S01E01 (retail)",
            language: "nld",
            providerName: "Addic7ed",
            format: "srt"
        ),
    ]
}

/// Local fixture with playback's Observation boundary, for performance and
/// focus tests without a media server.
@Observable
private final class PlayerPanelPreviewEngine: PlayerEngine {
    var timePosition = 0.0
    var duration = 1_320.0
    var isPaused = false
    var isBuffering = false
    var stallCount = 0
    var videoSize: CGSize? = CGSize(width: 1_920, height: 1_080)
    var audioTracks: [PlayerTrack] = [
        PlayerTrack(
            engineID: 1,
            kind: .audio,
            displayName: "English · Dolby Digital 5.1",
            isSelected: true,
            languageTag: "eng"
        ),
        PlayerTrack(
            engineID: 2,
            kind: .audio,
            displayName: "English Commentary · AAC Stereo",
            isSelected: false,
            languageTag: "eng"
        ),
    ]
    var subtitleTracks: [PlayerTrack] = {
        // As large as the libraries that show the panel's worst case on Apple TV.
        let languages = [
            ("English", "eng"), ("Estonian", "est"), ("Spanish", "spa"),
            ("French", "fra"), ("German", "deu"), ("Italian", "ita"),
            ("Finnish", "fin"), ("Swedish", "swe"), ("Norwegian", "nor"),
            ("Danish", "dan"),
        ]
        return (0..<30).map { offset in
            let language = languages[offset % languages.count]
            let engineID = 11 + offset
            return PlayerTrack(
                engineID: engineID,
                kind: .subtitle,
                displayName: offset < languages.count
                    ? language.0
                    : "\(language.0) · Track \(offset + 1)",
                isSelected: engineID == 11,
                languageTag: language.1,
                isForced: offset.isMultiple(of: 11),
                isHearingImpaired: offset.isMultiple(of: 7),
                source: offset.isMultiple(of: 5) ? .external : .embedded
            )
        }
    }()
    var currentSubtitleText: String?
    var currentSubtitleImages: [SubtitleImage] = []
    var audioDelay = 0.0
    var rate = 1.0
    var displayMatchRequest: DisplayMatchRequest?

    func play() { isPaused = false }
    func pause() { isPaused = true }
    func togglePause() { isPaused.toggle() }
    func setRate(_ rate: Double) { self.rate = PlaybackRatePolicy.clamped(rate) }
    func seek(by seconds: Double) { seek(to: timePosition + seconds) }
    func seek(to seconds: Double) { timePosition = min(max(seconds, 0), duration) }

    func selectAudioTrack(id: Int?) {
        audioTracks = audioTracks.map { track in
            PlayerTrack(
                engineID: track.engineID,
                kind: track.kind,
                displayName: track.displayName,
                isSelected: track.engineID == id,
                languageTag: track.languageTag,
                isForced: track.isForced,
                isHearingImpaired: track.isHearingImpaired,
                source: track.source
            )
        }
    }

    func selectSubtitleTrack(id: Int?) {
        subtitleTracks = subtitleTracks.map { track in
            PlayerTrack(
                engineID: track.engineID,
                kind: track.kind,
                displayName: track.displayName,
                isSelected: track.engineID == id,
                languageTag: track.languageTag,
                isForced: track.isForced,
                isHearingImpaired: track.isHearingImpaired,
                source: track.source
            )
        }
    }

    func addExternalSubtitle(_ track: ExternalSubtitleTrack) {}

    func setAudioDelay(_ seconds: Double) {
        audioDelay = (min(max(seconds, -5), 5) * 10).rounded() / 10
    }
}
#endif
