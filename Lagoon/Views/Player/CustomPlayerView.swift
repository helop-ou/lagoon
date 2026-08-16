import SwiftUI

/// Full-screen custom player: an engine-agnostic transport and track panel
/// over an injected video surface (HEL-35). Talks only to `PlayerEngine`
/// so the HEL-48 engine swap never touches this UI.
///
/// tvOS focus invariants: the surface is focusable whenever the track panel
/// is closed (Menu would quit the app from an unfocusable screen);
/// play/pause toggles, left/right seek ±10 s, down opens the track panel,
/// Menu exits. With the panel open, focus lives in the panel's buttons and
/// Menu closes the panel instead.
struct CustomPlayerView<Surface: View>: View {
    let engine: any PlayerEngine
    let title: String
    let subtitle: String?
    let onDismiss: () -> Void
    @ViewBuilder let surface: () -> Surface

    @State private var controlsVisible = true
    @State private var interactionToken = 0
    @State private var showTrackPanel = false
    @FocusState private var focusedTrackID: String?

    var body: some View {
        ZStack {
            videoSurface

            if engine.isBuffering {
                ProgressView()
                    .tint(.white)
            }

            transportOverlay
                .opacity((controlsVisible || engine.isPaused) && !showTrackPanel ? 1 : 0)
                .animation(.easeInOut(duration: Motion.fast), value: controlsVisible)
                .animation(.easeInOut(duration: Motion.fast), value: showTrackPanel)

            if showTrackPanel {
                trackPanel
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(Color.black.ignoresSafeArea())
        .task(id: interactionToken) {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, !showTrackPanel, !engine.isPaused else { return }
            withAnimation { controlsVisible = false }
        }
    }

    // MARK: - Surface & remote commands

    private var videoSurface: some View {
        surface()
            .ignoresSafeArea()
        #if os(tvOS)
            .focusable(!showTrackPanel)
            .onPlayPauseCommand {
                engine.togglePause()
                pokeControls()
            }
            .onMoveCommand { direction in
                switch direction {
                case .left: engine.seek(by: -10)
                case .right: engine.seek(by: 10)
                case .down: openTrackPanel()
                default: break
                }
                pokeControls()
            }
            .onExitCommand {
                onDismiss()
            }
        #endif
            .onTapGesture {
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

    private var hasTracks: Bool {
        !engine.audioTracks.isEmpty || !engine.subtitleTracks.isEmpty
    }

    private func openTrackPanel() {
        guard hasTracks else { return }
        withAnimation(.easeInOut(duration: Motion.fast)) { showTrackPanel = true }
    }

    private func closeTrackPanel() {
        withAnimation(.easeInOut(duration: Motion.fast)) { showTrackPanel = false }
        pokeControls()
    }

    // MARK: - Transport

    private var transportOverlay: some View {
        VStack {
            #if os(iOS)
            HStack(spacing: 12) {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                Spacer()
                if hasTracks {
                    Button {
                        openTrackPanel()
                    } label: {
                        Image(systemName: "captions.bubble")
                    }
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

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if engine.isPaused {
                        Image(systemName: "pause.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if hasTracks {
                        #if os(tvOS)
                        Label("Audio & Subtitles", systemImage: "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .labelStyle(.titleAndIcon)
                        #endif
                    }
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.25))
                        Capsule()
                            .fill(.white)
                            .frame(width: proxy.size.width * progressFraction)
                    }
                }
                .frame(height: Metrics.progressBarHeight)

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

    // MARK: - Track panel

    private static var subtitleOffID: String { "subtitle-off" }

    private var trackPanel: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Metrics.screenGutter) {
                if !engine.audioTracks.isEmpty {
                    trackColumn(
                        header: "Audio",
                        rows: engine.audioTracks.map { ($0.id, $0.displayName, $0.isSelected) }
                    ) { rowID in
                        if let track = engine.audioTracks.first(where: { $0.id == rowID }) {
                            engine.selectAudioTrack(id: track.engineID)
                        }
                    }
                }
                if !engine.subtitleTracks.isEmpty {
                    trackColumn(
                        header: "Subtitles",
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
            .padding(Metrics.screenGutter)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Metrics.panelCornerRadius))
            .padding(.horizontal, Metrics.screenGutter)
            .padding(.top, Metrics.railTopPadding)

            Spacer()
        }
        .defaultFocus($focusedTrackID, initialPanelFocusID)
        #if os(tvOS)
        .onExitCommand {
            closeTrackPanel()
        }
        #endif
        #if os(iOS)
        .background(
            // Dim + tap-out on iOS; tvOS closes via Menu.
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { closeTrackPanel() }
        )
        #endif
    }

    private var initialPanelFocusID: String? {
        if let selected = engine.audioTracks.first(where: \.isSelected) {
            return selected.id
        }
        return engine.subtitleTracks.first(where: \.isSelected)?.id ?? Self.subtitleOffID
    }

    private func trackColumn(
        header: String,
        rows: [(id: String, name: String, selected: Bool)],
        onSelect: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header)
                .font(.caption.smallCaps())
                .foregroundStyle(.secondary)
                .padding(.leading, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows, id: \.id) { row in
                        Button {
                            onSelect(row.id)
                        } label: {
                            HStack {
                                Image(systemName: "checkmark")
                                    .font(.caption.bold())
                                    .opacity(row.selected ? 1 : 0)
                                Text(row.name)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .focused($focusedTrackID, equals: row.id)
                    }
                }
            }
            .frame(maxHeight: 420)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
