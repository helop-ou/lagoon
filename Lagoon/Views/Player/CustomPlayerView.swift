import SwiftUI

/// Full-screen custom player: an engine-agnostic transport and a tabbed
/// Info · Audio · Subtitles panel over an injected video surface (HEL-35,
/// Infuse-style). Talks only to `PlayerEngine` so the HEL-48 engine swap
/// never touches this UI.
///
/// tvOS focus invariants: the surface is focusable whenever the panel is
/// closed (Menu would quit the app from an unfocusable screen). Remote
/// grammar: play/pause toggles anywhere; on the surface left/right seek
/// ±10 s and down opens the panel; in the panel left/right walk the tabs,
/// down enters the track rows. Menu is handled once at the root — it
/// closes the panel when open, otherwise exits the player.
struct CustomPlayerView<Surface: View>: View {
    let engine: any PlayerEngine
    let info: PlayerItemInfo
    let onDismiss: () -> Void
    @ViewBuilder let surface: () -> Surface

    private enum PanelTab: CaseIterable, Hashable {
        case info
        case audio
        case subtitles

        var title: String {
            switch self {
            case .info: String(localized: "Info")
            case .audio: String(localized: "Audio")
            case .subtitles: String(localized: "Subtitles")
            }
        }
    }

    private enum PanelFocus: Hashable {
        case tab(PanelTab)
        case row(String)
    }

    @State private var controlsVisible = true
    @State private var interactionToken = 0
    @State private var panelOpen = false
    @State private var selectedTab: PanelTab = .audio
    @FocusState private var panelFocus: PanelFocus?

    var body: some View {
        ZStack {
            videoSurface

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
        // One place decides what Menu means, no matter where focus sits —
        // panel open: close the panel; otherwise: leave the player.
        .onExitCommand {
            if panelOpen {
                closePanel()
            } else {
                onDismiss()
            }
        }
        .onPlayPauseCommand {
            engine.togglePause()
            pokeControls()
        }
        #endif
        .onChange(of: panelFocus) { _, focus in
            if case .tab(let tab) = focus {
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
            .focusable(!panelOpen)
            .onMoveCommand { direction in
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

    private func openPanel() {
        withAnimation(.easeInOut(duration: Motion.fast)) { panelOpen = true }
    }

    private func closePanel() {
        withAnimation(.easeInOut(duration: Motion.fast)) { panelOpen = false }
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

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(info.title)
                        .font(.headline)
                    if let subtitle = info.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if engine.isPaused {
                        Image(systemName: "pause.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        #if os(tvOS)
                        Label("Details", systemImage: "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        #endif
                    }
                }

                // Sized and weighted like AVKit's transport bar: a thick
                // rounded track with a bright fill, times under each end.
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

    // MARK: - Panel (Info · Audio · Subtitles)

    private static var subtitleOffID: String { "subtitle-off" }

    private var panel: some View {
        VStack(spacing: 0) {
            VStack(spacing: 20) {
                tabBar
                tabContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Metrics.screenGutter)
            .frame(maxWidth: 1100)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Metrics.panelCornerRadius))
            .padding(.top, Metrics.railTopPadding)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .defaultFocus($panelFocus, .tab(selectedTab))
        #if os(iOS)
        .background(
            // Dim + tap-out on iOS; tvOS closes via Menu.
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { closePanel() }
        )
        #endif
    }

    private var tabBar: some View {
        HStack(spacing: 28) {
            ForEach(PanelTab.allCases, id: \.self) { tab in
                VStack(spacing: 6) {
                    Button {
                        withAnimation(.easeInOut(duration: Motion.fast)) { selectedTab = tab }
                    } label: {
                        Text(tab.title)
                            .fontWeight(selectedTab == tab ? .semibold : .regular)
                    }
                    .focused($panelFocus, equals: .tab(tab))

                    Capsule()
                        .fill(.white)
                        .frame(width: 28, height: 3)
                        .opacity(selectedTab == tab ? 1 : 0)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .info:
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(info.title)
                        .font(.title3.bold())
                    if let subtitle = info.subtitle {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if !info.facts.isEmpty {
                    Text(info.facts.joined(separator: "   ·   "))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let overview = info.overview {
                    Text(overview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }

        case .audio:
            trackRows(
                engine.audioTracks.map { ($0.id, $0.displayName, $0.isSelected) },
                emptyText: String(localized: "No audio tracks")
            ) { rowID in
                if let track = engine.audioTracks.first(where: { $0.id == rowID }) {
                    engine.selectAudioTrack(id: track.engineID)
                }
            }

        case .subtitles:
            trackRows(
                [(Self.subtitleOffID, String(localized: "Off"), !engine.subtitleTracks.contains(where: \.isSelected))]
                    + engine.subtitleTracks.map { ($0.id, $0.displayName, $0.isSelected) },
                emptyText: nil
            ) { rowID in
                if rowID == Self.subtitleOffID {
                    engine.selectSubtitleTrack(id: nil)
                } else if let track = engine.subtitleTracks.first(where: { $0.id == rowID }) {
                    engine.selectSubtitleTrack(id: track.engineID)
                }
            }
        }
    }

    private func trackRows(
        _ rows: [(id: String, name: String, selected: Bool)],
        emptyText: String?,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        Group {
            if rows.isEmpty, let emptyText {
                Text(emptyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
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
                            .focused($panelFocus, equals: .row(row.id))
                        }
                    }
                }
                .frame(maxHeight: 380)
            }
        }
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
