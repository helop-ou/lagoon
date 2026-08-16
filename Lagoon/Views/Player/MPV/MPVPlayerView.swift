import SwiftUI

/// Full-screen mpv playback with a minimal focus-safe transport overlay.
///
/// tvOS focus invariants: the whole surface is focusable (Menu would quit
/// the app from an unfocusable screen) and remote commands act on it —
/// play/pause toggles, left/right arrows seek ±10 s, Menu dismisses via the
/// enclosing cover's `.onExitCommand`.
struct MPVPlayerView: View {
    let engine: MPVPlayerEngine
    let title: String
    let subtitle: String?
    let onDismiss: () -> Void

    @State private var controlsVisible = true
    @State private var interactionToken = 0

    var body: some View {
        ZStack {
            MPVVideoSurface(engine: engine)
                .ignoresSafeArea()

            if engine.isBuffering {
                ProgressView()
                    .tint(.white)
            }

            transportOverlay
                .opacity(controlsVisible || engine.isPaused ? 1 : 0)
                .animation(.easeInOut(duration: Motion.fast), value: controlsVisible)
        }
        .background(Color.black.ignoresSafeArea())
        #if os(tvOS)
        .focusable()
        .onPlayPauseCommand {
            engine.togglePause()
            pokeControls()
        }
        .onMoveCommand { direction in
            switch direction {
            case .left: engine.seek(by: -10)
            case .right: engine.seek(by: 10)
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
        .task(id: interactionToken) {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation { controlsVisible = false }
        }
    }

    private func pokeControls() {
        controlsVisible = true
        interactionToken += 1
    }

    private var transportOverlay: some View {
        VStack {
            #if os(iOS)
            HStack {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.glass)
                Spacer()
                Button {
                    engine.togglePause()
                } label: {
                    Image(systemName: engine.isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.glass)
            }
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
