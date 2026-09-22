import SwiftUI

#if os(iOS)
/// Downloads grouped by series. Row text comes from the entry, so the
/// screen renders with no server; only thumbs and taps need the snapshot.
struct DownloadsView: View {
    private var store: DownloadStore { .shared }
    @Environment(SessionStore.self) private var session

    @State private var confirmingDeleteAll = false

    var body: some View {
        Group {
            if store.entries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Downloads")
        .accessibilityIdentifier("downloads.view")
        .toolbar {
            if !store.entries.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("Delete All", role: .destructive) {
                        confirmingDeleteAll = true
                    }
                }
            }
        }
        .confirmationDialog(
            "Delete All Downloads?",
            isPresented: $confirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { store.deleteAll() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var list: some View {
        ThemedForm {
            if !films.isEmpty {
                Section("Films") {
                    ForEach(films) { row(for: $0) }
                }
            }
            ForEach(seriesGroups) { group in
                Section(group.seriesName) {
                    ForEach(group.entries) { row(for: $0) }
                }
            }
            Section {
            } footer: {
                Text(footerText)
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Downloads",
            systemImage: "arrow.down.circle",
            description: Text("Titles you take offline for playback without a network appear here.")
        )
    }

    // MARK: - Grouping

    private var films: [DownloadEntry] {
        store.entries
            .filter { $0.type == .movie }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private struct SeriesGroup: Identifiable {
        let seriesID: String
        let seriesName: String
        let entries: [DownloadEntry]
        var id: String { seriesID }
    }

    private var seriesGroups: [SeriesGroup] {
        let grouped = Dictionary(grouping: store.entries.filter { $0.type != .movie }) {
            $0.seriesID ?? $0.itemID
        }
        return grouped
            .map { seriesID, entries in
                SeriesGroup(
                    seriesID: seriesID,
                    seriesName: entries.first?.seriesName ?? entries.first?.title ?? String(localized: "Series"),
                    entries: entries.sorted {
                        ($0.seasonNumber ?? 0, $0.episodeNumber ?? 0) < ($1.seasonNumber ?? 0, $1.episodeNumber ?? 0)
                    }
                )
            }
            .sorted { $0.seriesName.localizedStandardCompare($1.seriesName) == .orderedAscending }
    }

    private var footerText: String {
        let count = store.entries.count
        let size = ByteCountFormatter.string(fromByteCount: store.storageUsed, countStyle: .file)
        return count == 1
            ? String(localized: "1 title, \(size) on device")
            : String(localized: "\(count) titles, \(size) on device")
    }

    // MARK: - Row

    private func row(for entry: DownloadEntry) -> some View {
        let snapshot = store.snapshotItem(for: entry.itemID)
        return NavigationLink(value: snapshot.map(ContentNavigationRoute.item)) {
            HStack(spacing: Metrics.Space.m) {
                posterThumb(for: snapshot)
                VStack(alignment: .leading, spacing: Metrics.Space.hair) {
                    Text(entry.title)
                        .font(.body)
                        .lineLimit(1)
                    Text(subtitle(for: entry))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if entry.isActive, let fraction = entry.fractionComplete {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                    }
                }
                Spacer(minLength: Metrics.Space.s)
                trailing(for: entry)
            }
            .padding(.vertical, Metrics.Space.hair)
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", role: .destructive) {
                store.delete(entry.itemID)
            }
            switch entry.state {
            case .queued, .downloading:
                Button("Pause") { store.pause(entry.itemID) }
                    .tint(.orange)
            case .paused, .failed:
                Button("Resume") { store.resume(entry.itemID, client: session.client) }
                    .tint(.blue)
            case .complete:
                EmptyView()
            }
        }
        .accessibilityIdentifier("downloads.item.\(entry.itemID)")
    }

    private var thumbWidth: CGFloat { Metrics.posterWidth * 0.2 }
    private var thumbHeight: CGFloat { (thumbWidth * 3 / 2).rounded() }

    @ViewBuilder
    private func posterThumb(for snapshot: MediaItem?) -> some View {
        Group {
            if let snapshot,
               let url = session.client.imageURL(for: snapshot, kind: .poster, maxWidth: Int(thumbWidth * 3)) {
                CachedAsyncImage(url: url, maxPixelSize: Int(thumbWidth * 3)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.08)
                }
            } else {
                Color.white.opacity(0.08)
            }
        }
        .frame(width: thumbWidth, height: thumbHeight)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.badgeCornerRadius))
    }

    @ViewBuilder
    private func trailing(for entry: DownloadEntry) -> some View {
        switch entry.state {
        case .queued, .downloading:
            // iOS ignores `value` for the circular style, so a known fraction
            // gets a bar under the subtitle instead.
            if entry.fractionComplete == nil {
                ProgressView()
                    .progressViewStyle(.circular)
            }
        case .paused:
            Image(systemName: "pause.circle")
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.secondary)
        case .complete:
            EmptyView()
        }
    }

    private func subtitle(for entry: DownloadEntry) -> String {
        var parts: [String] = []
        if let episodeLabel = entry.episodeLabel {
            parts.append(episodeLabel)
        } else if let year = entry.productionYear {
            parts.append(String(year))
        }
        parts.append(statusText(for: entry))
        return parts.joined(separator: " · ")
    }

    private func statusText(for entry: DownloadEntry) -> String {
        switch entry.state {
        case .queued:
            return String(localized: "Queued")
        case .downloading:
            if let fraction = entry.fractionComplete {
                return String(localized: "Downloading… \(Int(fraction * 100))%")
            }
            return String(localized: "Downloading…")
        case .paused:
            return entry.resumesFromStart
                ? String(localized: "Paused, resumes from the start")
                : String(localized: "Paused")
        case .failed:
            return entry.failure ?? String(localized: "Failed")
        case .complete:
            return ByteCountFormatter.string(fromByteCount: entry.receivedBytes, countStyle: .file)
        }
    }
}
#endif
