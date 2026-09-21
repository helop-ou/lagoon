import SwiftUI

/// The Watch Together action in a film or episode page's secondary row:
/// a glass circle on a phone, where every control in that row is one,
/// and the labelled pill wherever there is width for it.
///
/// Whether the account may use groups at all is the store's answer, and
/// the detail page is what asks for it — never this control. It renders
/// nothing until it is allowed, and a task on a view that renders nothing
/// never runs, so a control that resolved its own permission could never
/// appear (the trap `DownloadControl` documents).
///
/// The symbol is `person.2.fill` and never `shareplay`: SharePlay is
/// Apple's GroupActivities, which this does not use. Borrowing its glyph
/// would promise the wrong feature.
struct WatchTogetherControl: View {
    let item: MediaItem
    /// Where a group started here begins — the page's resume point.
    let startPositionTicks: Int64

    @Environment(SyncPlayStore.self) private var syncPlay
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @State private var isPresented = false

    var body: some View {
        Group {
            if syncPlay.availability.canJoin {
                control
            }
        }
        .sheet(isPresented: $isPresented) {
            WatchTogetherSheet(item: item, startPositionTicks: startPositionTicks)
        }
    }

    @ViewBuilder
    private var control: some View {
        #if os(iOS)
        if DetailLayout.usesLeadingColumn(horizontalSizeClass) {
            pill
        } else {
            DetailCircleButton {
                isPresented = true
            } label: {
                glyph
            }
            .accessibilityLabel(label)
            .accessibilityIdentifier("detail.watchTogether")
        }
        #else
        pill
        #endif
    }

    private var pill: some View {
        Button {
            isPresented = true
        } label: {
            Label(label, systemImage: "person.2.fill")
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("detail.watchTogether")
    }

    /// Membership reads through weight and opacity, not colour: a tinted
    /// label disappears inside the tvOS focused lozenge.
    private var glyph: some View {
        Image(systemName: "person.2.fill")
            .fontWeight(syncPlay.isJoined ? .bold : .regular)
            .opacity(syncPlay.isJoined ? 1 : 0.55)
    }

    private var label: LocalizedStringKey {
        syncPlay.isJoined ? "Your Group" : "Watch Together"
    }
}
