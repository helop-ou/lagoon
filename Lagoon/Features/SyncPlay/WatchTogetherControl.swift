import SwiftUI

/// The Watch Together action on a detail page.
///
/// The detail page resolves the permission, never this control: it renders
/// nothing until allowed, so its own task would never run.
///
/// The symbol is `person.2.fill`, never `shareplay`: this is not Apple's
/// GroupActivities.
struct WatchTogetherControl: View {
    let item: MediaItem
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

    /// Weight and opacity, not colour: a tint vanishes in the tvOS focus lozenge.
    private var glyph: some View {
        Image(systemName: "person.2.fill")
            .fontWeight(syncPlay.isJoined ? .bold : .regular)
            .opacity(syncPlay.isJoined ? 1 : 0.55)
    }

    private var label: LocalizedStringKey {
        syncPlay.isJoined ? "Your Group" : "Watch Together"
    }
}
