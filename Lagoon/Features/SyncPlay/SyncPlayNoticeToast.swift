import SwiftUI

/// What a Watch Together notice says to the viewer.
///
/// Separate from `SyncPlayNotice` itself, which is pure and carries the
/// tests: the reducer decides *that* something happened, and this decides
/// how to say it. Returning nil is a real answer — a state the picture
/// already reports is not worth a toast over it.
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
            // "Playing" arrives at the same moment the picture starts
            // moving, and "Nothing playing" at the moment it stops, so
            // neither is worth saying. Neither is "Waiting": the transport
            // already carries that line under its spinner, and it stays up
            // for as long as it is true instead of for two seconds.
            // "Paused" is the one state nothing else explains.
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

/// The player's transient line about the group: someone joined or left, the
/// group paused, the library is out of reach.
///
/// An overlay leaf shaped like `PlayerSkipOverlay`: it reads the store in its
/// own body, so the player root never re-renders for a notice. Top of screen,
/// clear of the transport and skip shelf, never hit-tested — on tvOS a
/// focusable overlay would take the remote from the video surface.
///
/// Plain material and semantic text, no dynamic-range lift: SDR chrome over a
/// possibly HDR frame, like every other notice the player draws.
struct SyncPlayNoticeToast: View {
    let store: SyncPlayStore
    var reduceMotion = false

    /// How long a line stays. Long enough to read six words, short enough
    /// that the next one is not queued behind it.
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
        // Value-driven, like every other animation over the player: a
        // withAnimation transaction does not survive tvOS's MenuPressGate
        // hosting boundary.
        .animation(reduceMotion ? nil : .easeOut(duration: Motion.fast), value: shown?.id)
        .allowsHitTesting(false)
        .task(id: latest?.id) {
            // A notice with nothing to say still counts as the latest, so
            // it clears whatever is on screen rather than letting the
            // previous line outstay it.
            shown = latest
            guard latest?.notice.message != nil else { return }
            do { try await Task.sleep(for: Self.dwell) } catch { return }
            shown = nil
        }
    }
}

/// The line itself, shared with the Debug component gallery so what is
/// approved there is what ships.
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
