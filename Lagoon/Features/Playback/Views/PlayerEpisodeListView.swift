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

/// The title and, in a mixed list, the series under it.
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
