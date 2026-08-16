import SwiftUI

/// Full-screen custom player styled after the Infuse reference shots on
/// HEL-35: a "Swipe down for Info" hint, a bottom-left title block over a
/// thin scrubber, and a swipe-down panel of centered pill tabs
/// (Info · Video · Audio · Subtitles) above one floating material card.
/// Talks only to `PlayerEngine` so the HEL-48 engine swap never touches it.
///
/// tvOS focus invariants: the surface is focusable at all times (Menu
/// would quit the app from an unfocusable screen). Remote grammar:
/// play/pause toggles anywhere; on the surface left/right seek ±10 s and
/// down opens the panel; in the panel left/right walk the tabs (selection
/// follows focus), down enters the track rows. Menu/Escape is intercepted
/// at the UIKit press layer by `MenuPressGate` — panel open closes the
/// panel, otherwise the player exits (SwiftUI's `onExitCommand` never
/// fires inside a fullScreenCover on tvOS 26).
struct CustomPlayerView<Surface: View>: View {
    let engine: any PlayerEngine
    let info: PlayerItemInfo
    let onDismiss: () -> Void
    /// Lets the host react to the panel opening (the debug HUD hides so
    /// it can't sit on top of the track card).
    var onPanelToggle: ((Bool) -> Void)? = nil
    @ViewBuilder let surface: () -> Surface

    private enum PanelTab: CaseIterable, Hashable {
        case info
        case video
        case audio
        case subtitles

        var title: String {
            switch self {
            case .info: String(localized: "Info")
            case .video: String(localized: "Video")
            case .audio: String(localized: "Audio")
            case .subtitles: String(localized: "Subtitles")
            }
        }
    }

    @State private var controlsVisible = true
    @State private var interactionToken = 0
    @State private var panelOpen = false
    @State private var selectedTab: PanelTab = .info
    @FocusState private var focusedTab: PanelTab?

    var body: some View {
        #if os(tvOS)
        // Menu never reaches SwiftUI inside a fullScreenCover on tvOS 26;
        // the gate intercepts the press itself (see MenuPressGate).
        MenuPressGate {
            if panelOpen {
                closePanel()
            } else {
                onDismiss()
            }
        } content: {
            playerContent
        }
        .ignoresSafeArea()
        #else
        playerContent
        #endif
    }

    private var playerContent: some View {
        ZStack {
            videoSurface

            subtitleOverlay

            if engine.isBuffering {
                ProgressView()
                    .tint(.white)
            }

            transportOverlay
                .opacity((controlsVisible || engine.isPaused) && !panelOpen ? 1 : 0)
                .animation(.easeInOut(duration: Motion.fast), value: controlsVisible)
                .animation(.easeInOut(duration: Motion.fast), value: panelOpen)

            if panelOpen {
                panel
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(Color.black.ignoresSafeArea())
        #if os(tvOS)
        .onPlayPauseCommand {
            engine.togglePause()
            pokeControls()
        }
        #endif
        .onChange(of: focusedTab) { _, tab in
            if let tab {
                withAnimation(.easeInOut(duration: Motion.fast)) { selectedTab = tab }
            }
        }
        .task(id: interactionToken) {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !panelOpen, !engine.isPaused else { return }
            withAnimation { controlsVisible = false }
        }
    }

    // MARK: - Surface & remote commands

    private var videoSurface: some View {
        surface()
            .ignoresSafeArea()
        #if os(tvOS)
            // Always focusable: if the surface could resign focus, any
            // instant with nothing focused would route Menu straight to the
            // fullScreenCover's default dismissal (and melt the focus
            // system with it — seen as a full app freeze). With the panel
            // open, arrows just nudge focus into the panel instead.
            .focusable()
            .onMoveCommand { direction in
                if panelOpen {
                    focusedTab = selectedTab
                    return
                }
                switch direction {
                case .left: engine.seek(by: -10)
                case .right: engine.seek(by: 10)
                case .down: openPanel()
                default: break
                }
                pokeControls()
            }
        #endif
            .onTapGesture {
                guard !panelOpen else { return }
                #if os(tvOS)
                engine.togglePause()
                #else
                controlsVisible.toggle()
                #endif
                pokeControls()
            }
    }

    private func pokeControls() {
        controlsVisible = true
        interactionToken += 1
    }

    // MARK: - Subtitles (HEL-48 M5)

    /// Bitmap cues (PGS/VobSub) land exactly where they compose on the
    /// video plane; text cues sit bottom-center Infuse-style.
    private var subtitleOverlay: some View {
        GeometryReader { proxy in
            let videoRect = displayedVideoRect(in: proxy.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(Array(engine.currentSubtitleImages.enumerated()), id: \.offset) { _, cue in
                    Image(decorative: cue.image, scale: 1)
                        .resizable()
                        .frame(
                            width: videoRect.width * cue.rect.width,
                            height: videoRect.height * cue.rect.height
                        )
                        .position(
                            x: videoRect.minX + videoRect.width * cue.rect.midX,
                            y: videoRect.minY + videoRect.height * cue.rect.midY
                        )
                }
                if let text = engine.currentSubtitleText {
                    VStack {
                        Spacer()
                        Text(text)
                            .font(.title3.weight(.medium))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.9), radius: 3, y: 1)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                            .padding(.bottom, Metrics.screenGutter)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// Where the aspect-fit video actually sits inside the surface.
    private func displayedVideoRect(in container: CGSize) -> CGRect {
        guard let videoSize = engine.videoSize, videoSize.width > 0, videoSize.height > 0,
              container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / videoSize.width, container.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func openPanel() {
        withAnimation(.easeInOut(duration: Motion.fast)) { panelOpen = true }
        onPanelToggle?(true)
        // defaultFocus is only honored when a fresh scene appears — for a
        // mid-screen reveal tvOS leaves focus where it was, stranding the
        // panel. Claim focus immediately (an unfocused instant would send
        // Menu straight to the cover's default dismissal) and again once
        // the reveal has settled, in case the first assignment was too
        // early to take.
        focusedTab = selectedTab
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard panelOpen, focusedTab == nil else { return }
            focusedTab = selectedTab
        }
    }

    private func closePanel() {
        focusedTab = nil
        withAnimation(.easeInOut(duration: Motion.fast)) { panelOpen = false }
        onPanelToggle?(false)
        pokeControls()
    }

    // MARK: - Transport

    private var transportOverlay: some View {
        VStack {
            #if os(tvOS)
            VStack(spacing: 2) {
                Text("Swipe down for Info")
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.compact.down")
                    .font(.title3.weight(.bold))
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.top, Metrics.railTopPadding)
            #else
            HStack(spacing: 12) {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                Spacer()
                Button {
                    openPanel()
                } label: {
                    Image(systemName: "info.circle")
                }
                Button {
                    engine.togglePause()
                } label: {
                    Image(systemName: engine.isPaused ? "play.fill" : "pause.fill")
                }
            }
            .buttonStyle(.glass)
            .padding(Metrics.screenGutter)
            #endif

            Spacer()

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let subtitle = info.subtitle {
                            Text(subtitle)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Text(info.title)
                            .font(.title2.bold())
                    }
                    Spacer()
                    if engine.isPaused {
                        Image(systemName: "pause.fill")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.3))
                        Capsule()
                            .fill(.white)
                            .frame(width: max(proxy.size.width * progressFraction, Metrics.scrubberHeight))
                    }
                }
                .frame(height: Metrics.scrubberHeight)

                HStack {
                    Text(Self.timestamp(engine.timePosition))
                    Spacer()
                    Text("-" + Self.timestamp(max(engine.duration - engine.timePosition, 0)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(Metrics.screenGutter)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
            // Info-only: never intercept taps meant for the surface. The
            // iOS button row above stays interactive.
            .allowsHitTesting(false)
        }
        .foregroundStyle(.white)
    }

    // MARK: - Panel

    private static var subtitleOffID: String { "subtitle-off" }

    private var panel: some View {
        VStack(spacing: 24) {
            tabBar

            tabCard
                .padding(.horizontal, Metrics.screenGutter)

            Spacer()
        }
        .padding(.top, Metrics.railTopPadding)
        .defaultFocus($focusedTab, selectedTab)
        #if os(iOS)
        .background(
            // Dim + tap-out on iOS; tvOS closes via Menu.
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { closePanel() }
        )
        #endif
    }

    // Native buttons only: the system's focused lozenge IS the Infuse
    // white-pill look — never draw custom focus chrome around it. The
    // active tab keeps bold text once focus moves down into the card.
    private var tabBar: some View {
        HStack(spacing: 14) {
            ForEach(PanelTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: Motion.fast)) { selectedTab = tab }
                } label: {
                    Text(tab.title)
                        .fontWeight(selectedTab == tab ? .bold : .regular)
                }
                .focused($focusedTab, equals: tab)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var tabCard: some View {
        Group {
            switch selectedTab {
            case .info: infoCard
            case .video: videoCard
            case .audio: audioCard
            case .subtitles:
                trackCard(
                    rows: [(Self.subtitleOffID, String(localized: "Off"), !engine.subtitleTracks.contains(where: \.isSelected))]
                        + engine.subtitleTracks.map { ($0.id, $0.displayName, $0.isSelected) }
                ) { rowID in
                    if rowID == Self.subtitleOffID {
                        engine.selectSubtitleTrack(id: nil)
                    } else if let track = engine.subtitleTracks.first(where: { $0.id == rowID }) {
                        engine.selectSubtitleTrack(id: track.engineID)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.panelCornerRadius))
        .foregroundStyle(.white)
    }

    private var infoCard: some View {
        HStack(alignment: .top, spacing: 24) {
            CachedAsyncImage(url: info.posterURL, maxPixelSize: 400) { image in
                image
                    .resizable()
                    .aspectRatio(2 / 3, contentMode: .fill)
            } placeholder: {
                Color.white.opacity(0.1)
            }
            .frame(width: 130, height: 195)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))

            VStack(alignment: .leading, spacing: 10) {
                Text(combinedTitle)
                    .font(.headline)
                if let overview = info.overview {
                    Text(overview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if !info.facts.isEmpty {
                    Text(info.facts.joined(separator: "    "))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var combinedTitle: String {
        if let subtitle = info.subtitle {
            return "\(info.title) – \(subtitle)"
        }
        return info.title
    }

    // Tracks column plus the Infuse-style OPTIONS column (audio delay,
    // HEL-48 M6).
    private var audioCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            trackCard(rows: engine.audioTracks.map { ($0.id, $0.displayName, $0.isSelected) }) { rowID in
                if let track = engine.audioTracks.first(where: { $0.id == rowID }) {
                    engine.selectAudioTrack(id: track.engineID)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                cardHeader("Options")
                HStack(spacing: 14) {
                    Text("Audio Delay")
                        .font(.callout)
                    Spacer()
                    Button {
                        engine.setAudioDelay(engine.audioDelay - 0.1)
                    } label: {
                        Image(systemName: "minus")
                    }
                    Text(String(format: "%+.1f s", engine.audioDelay))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(engine.audioDelay == 0 ? .secondary : .primary)
                    Button {
                        engine.setAudioDelay(engine.audioDelay + 0.1)
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }

    private var videoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader("Track")
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.caption.bold())
                Text(info.videoSummary ?? String(localized: "Unknown video track"))
                    .font(.callout)
            }
        }
    }

    private func trackCard(
        rows: [(id: String, name: String, selected: Bool)],
        onSelect: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader("Tracks")
            // The card hugs short lists; only long ones scroll.
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows, id: \.id) { row in
                        Button {
                            onSelect(row.id)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark")
                                    .font(.caption.bold())
                                    .opacity(row.selected ? 1 : 0)
                                Text(row.name)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxHeight: min(CGFloat(rows.count) * 64 + 16, 340))
        }
    }

    private func cardHeader(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .textCase(.uppercase)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 12)
    }

    private var progressFraction: CGFloat {
        guard engine.duration > 0 else { return 0 }
        return CGFloat(min(max(engine.timePosition / engine.duration, 0), 1))
    }

    private static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
