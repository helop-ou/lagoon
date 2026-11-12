import SwiftUI

#if os(iOS)
/// The toolbar's Episodes list: a native list in a popover, which is a sheet
/// on a phone.
struct PlayerEpisodeListSheet: View {
    let list: PlayerEpisodeList
    let onSelect: (PlayerEpisodeList.Row) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(list.rows) { row in
                    Button {
                        dismiss()
                        onSelect(row)
                    } label: {
                        HStack(spacing: Metrics.Space.s) {
                            PlayerEpisodeRowText(row: row)
                            Spacer(minLength: Metrics.Space.s)
                            if row.isCurrent { Image(systemName: "checkmark") }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(row.isCurrent ? [.isSelected] : [])
                    .accessibilityIdentifier("player.episodes.row.\(row.index)")
                }
                .onAppear {
                    if let current = list.current { proxy.scrollTo(current.id, anchor: .center) }
                }
            }
            .navigationTitle(list.heading ?? String(localized: "Episodes"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", role: .close) { dismiss() }
                        .accessibilityIdentifier("player.episodes.close")
                }
            }
        }
        .accessibilityIdentifier("player.episodes.list")
    }
}
#endif

#if os(tvOS)
/// The tvOS Episodes list, above the control row like the sound list.
/// Focus starts on the playing title.
struct PlayerEpisodeListTV: View {
    let list: PlayerEpisodeList
    let focus: FocusState<PlayerControlFocus?>.Binding
    let onSelect: (PlayerEpisodeList.Row) -> Void
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            if let heading = list.heading {
                Text(heading)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    rows
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                }
                // A short season sits at its own height, a long one scrolls.
                .frame(height: rowsHeight > 0 ? min(rowsHeight, EpisodeListMetrics.maxListHeight) : nil)
                .onAppear {
                    if let current = list.current { proxy.scrollTo(current.id, anchor: .center) }
                }
            }
            .padding(-EpisodeListMetrics.focusInset)
        }
        .padding(Metrics.Space.xl)
        .frame(width: EpisodeListMetrics.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.panelCornerRadius))
        .focusSection()
        .accessibilityIdentifier("player.episodes.list")
    }

    private var rows: some View {
        LazyVStack(alignment: .leading, spacing: Metrics.Space.m) {
            ForEach(list.rows) { row in
                Button {
                    onSelect(row)
                } label: {
                    HStack(spacing: Metrics.Space.m) {
                        Image(systemName: "checkmark")
                            .font(.caption.bold())
                            .opacity(row.isCurrent ? 1 : 0)
                        PlayerEpisodeRowText(row: row)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .focused(focus, equals: .episode(row.index))
                .id(row.id)
                .accessibilityAddTraits(row.isCurrent ? [.isSelected] : [])
                .accessibilityIdentifier("player.episodes.row.\(row.index)")
            }
        }
        .padding(EpisodeListMetrics.focusInset)
    }
}

private enum EpisodeListMetrics {
    static let width: CGFloat = 760
    static let maxListHeight: CGFloat = 520
    /// Room for the focused row to lift inside the scroll view.
    static let focusInset: CGFloat = 20
}
#endif

/// The title and, in a mixed list, the series under it. Only hierarchical
/// styles: on tvOS the focused lozenge inverts what it inherits.
struct PlayerEpisodeRowText: View {
    let row: PlayerEpisodeList.Row

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xs) {
            Text(row.title)
                .lineLimit(2)
            if let detail = row.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
