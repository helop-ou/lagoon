import SwiftUI

/// Home's reminder that a group is still running, and the way back into
/// it (HEL-172).
///
/// A banner above the rails rather than a card inside one: a rail head is
/// a piece of a list of titles, and this is neither a title nor something
/// to browse — it is a temporary state of this session, which is also why
/// it is not a sixth tab (the bar is full, and HEL-169 reserves its last
/// slot). It appears only while a group has this device as a member and
/// nothing of that group's is on screen; closing the player is what puts
/// it there, and Rejoin is what takes it away again.
struct WatchTogetherHomeCard: View {
    @Environment(SyncPlayStore.self) private var syncPlay

    var body: some View {
        if syncPlay.isJoined, !syncPlay.isPlayerOpen {
            card
                .padding(.horizontal, Metrics.screenGutter)
                .padding(.bottom, Metrics.Space.xl)
                .accessibilityIdentifier("home.watchTogether")
        }
    }

    private var card: some View {
        content
            .padding(Metrics.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.cardCornerRadius))
    }

    @ViewBuilder
    private var content: some View {
        #if os(tvOS)
        HStack(spacing: Metrics.Space.xl) {
            summary
            Spacer(minLength: Metrics.Space.l)
            actions
        }
        #else
        VStack(alignment: .leading, spacing: Metrics.Space.l) {
            summary
            HStack(spacing: Metrics.Space.m) { actions }
        }
        #endif
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xs) {
            Label(syncPlay.session.groupName ?? String(localized: "Watch Together"), systemImage: "person.2.fill")
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actions: some View {
        // Nothing to come back to until the group has picked something.
        if syncPlay.session.queue?.playingItem != nil {
            Button {
                Task { await syncPlay.rejoinPlayback() }
            } label: {
                Label("Rejoin", systemImage: "play.fill")
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("home.watchTogether.rejoin")
        }

        Button {
            Task { await syncPlay.leave() }
        } label: {
            Label("Leave", systemImage: "rectangle.portrait.and.arrow.right")
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("home.watchTogether.leave")
    }

    private var detail: String {
        let people = syncPlay.session.participants
        let state = SyncPlayStateCopy.title(for: syncPlay.session.state)
        guard !people.isEmpty else { return state }
        return "\(state) · \(people.joined(separator: ", "))"
    }
}
