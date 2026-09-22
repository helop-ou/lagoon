import SwiftUI

/// The viewer-facing text of a notice; nil when the picture already says it.
extension SyncPlayNotice {
    var message: String? {
        switch self {
        case .joined(let group):
            String(localized: "Joined \(group)")
        case .userJoined(let name):
            String(localized: "\(name) joined")
        case .userLeft(let name):
            String(localized: "\(name) left")
        case .state(let state, _):
            // Only "Paused": the picture shows playing and stopping, and the
            // transport spinner already says "Waiting".
            switch state {
            case .paused: String(localized: "Paused by the group")
            case .waiting, .playing, .idle, .unknown: nil
            }
        case .left(let reason):
            switch reason {
            case .leftGroup: String(localized: "Left the group")
            case .notInGroup: String(localized: "You're no longer in the group")
            case .groupDoesNotExist: String(localized: "That group has ended")
            }
        case .accessDenied:
            String(localized: "This account can't see what the group is playing")
        case .requestFailed:
            String(localized: "Couldn't update the group. Try again.")
        }
    }
}

/// The player's transient group notice.
///
/// Reads the store in its own body, so the player root never re-renders for
/// a notice. Never hit-tested: on tvOS a focusable overlay would take the
/// remote from the video surface. SDR chrome, no dynamic-range lift.
struct SyncPlayNoticeToast: View {
    let store: SyncPlayStore
    var reduceMotion = false

    private static let dwell = Duration.seconds(2)

    @State private var shown: SyncPlayStore.Entry?

    var body: some View {
        let latest = store.notices.last
        VStack {
            if let text = shown?.notice.message {
                SyncPlayToastLabel(text: text)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, Metrics.screenGutter)
        .padding(.top, Metrics.Space.xl)
        // Value-driven: a withAnimation transaction does not survive tvOS's
        // MenuPressGate hosting boundary.
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.fast), value: shown?.id)
        .allowsHitTesting(false)
        .task(id: latest?.id) {
            // A silent notice still clears the previous line.
            shown = latest
            guard latest?.notice.message != nil else { return }
            do { try await Task.sleep(for: Self.dwell) } catch { return }
            shown = nil
        }
    }
}

/// Shared with the Debug component gallery.
struct SyncPlayToastLabel: View {
    let text: String
    var accessibilityIdentifier = "player.together.toast"

    var body: some View {
        Label(text, systemImage: "person.2.fill")
            .font(.callout)
            .lineLimit(2)
            .padding(.horizontal, Metrics.Space.l)
            .padding(.vertical, Metrics.Space.m)
            .background(.regularMaterial, in: Capsule())
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}
