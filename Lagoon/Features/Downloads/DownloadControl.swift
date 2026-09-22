import SwiftUI

#if os(iOS)
/// The download circle beside Play on a detail page. State reads through
/// symbol weight and opacity, never color. Hidden when the account can't
/// download and nothing is on disk.
struct DownloadControl: View {
    let item: MediaItem

    @Environment(SessionStore.self) private var session
    private var store: DownloadStore { .shared }

    @State private var transcodingAllowed: Bool?
    @State private var fetchedItem: MediaItem?
    @State private var alertMessage: String?
    @State private var pendingConfirmation: PendingDownload?
    @State private var confirmingDelete = false

    private struct PendingDownload: Identifiable {
        let source: MediaSource
        let quality: DownloadQuality
        let estimate: DownloadStore.Estimate
        var id: String { quality.rawValue }
    }

    private var entry: DownloadEntry? { store.entry(for: item.id) }

    /// A rail or context-menu item has no media sources, so the control
    /// fetches its own copy.
    private var sourceItem: MediaItem {
        item.mediaSources != nil ? item : (fetchedItem ?? item)
    }

    var body: some View {
        Group {
            if let entry {
                existingControl(entry)
            } else if store.permitted == true {
                newDownloadMenu
            }
        }
        .task(id: item.id) {
            // The store owns the download permission; see `permitted`.
            transcodingAllowed = await session.client.canTranscodeForDownload()
        }
        .task(id: item.id) {
            guard item.mediaSources == nil else { return }
            fetchedItem = try? await session.client.item(id: item.id)
        }
        .alert("Couldn't Download", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .alert(
            "Large Download",
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { if !$0 { pendingConfirmation = nil } }
            ),
            presenting: pendingConfirmation
        ) { pending in
            Button("Download") {
                begin(source: pending.source, quality: pending.quality)
                pendingConfirmation = nil
            }
            Button("Cancel", role: .cancel) { pendingConfirmation = nil }
        } message: { pending in
            Text(largeDownloadMessage(for: pending))
        }
    }

    // MARK: - No entry yet

    /// Default first. Transcode qualities only when the account may transcode.
    private var orderedQualities: [DownloadQuality] {
        let allowed: [DownloadQuality] = transcodingAllowed == true ? DownloadQuality.allCases : [.original]
        guard allowed.contains(store.defaultQuality) else { return allowed }
        return [store.defaultQuality] + allowed.filter { $0 != store.defaultQuality }
    }

    private var newDownloadMenu: some View {
        DetailCircleMenu {
            ForEach(orderedQualities) { quality in
                Button {
                    pick(quality)
                } label: {
                    Text(quality.title)
                    Text(qualitySubtitle(for: quality))
                }
            }
        } label: {
            Image(systemName: "arrow.down.circle")
        }
        .accessibilityLabel("Download")
        .accessibilityIdentifier("detail.download")
    }

    private func qualitySubtitle(for quality: DownloadQuality) -> String {
        guard let source = sourceItem.mediaSources?.first else { return quality.detail }
        let estimate = store.estimate(for: sourceItem, source: source, quality: quality)
        guard let bytes = estimate.bytes else { return quality.detail }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func pick(_ quality: DownloadQuality) {
        guard let source = sourceItem.mediaSources?.first else {
            alertMessage = String(localized: "This title can't be downloaded.")
            return
        }
        let estimate = store.estimate(for: sourceItem, source: source, quality: quality)
        if estimate.exceedsFreeSpace {
            alertMessage = String(localized: "There isn't enough free space on this device for this download.")
            return
        }
        if estimate.isLarge {
            pendingConfirmation = PendingDownload(source: source, quality: quality, estimate: estimate)
            return
        }
        begin(source: source, quality: quality)
    }

    private func largeDownloadMessage(for pending: PendingDownload) -> String {
        guard let bytes = pending.estimate.bytes else {
            return String(localized: "This download is large. Continue?")
        }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return String(localized: "This download is about \(size). Continue?")
    }

    private func begin(source: MediaSource, quality: DownloadQuality) {
        Task {
            do {
                try await store.start(item: sourceItem, source: source, quality: quality, client: session.client)
            } catch is CancellationError {
                // A newer start or deletion already expressed the viewer's intent.
            } catch {
                alertMessage = Self.message(for: error)
            }
        }
    }

    static func message(for error: Error) -> String {
        guard let startError = error as? DownloadStore.StartError else {
            return String(localized: "The download couldn't start. Try again.")
        }
        switch startError {
        case .notPermitted:
            return String(localized: "This account isn't allowed to download from this server.")
        case .accountChanged:
            return String(localized: "The account changed before the download could start. Try again.")
        case .unsupportedItem:
            return String(localized: "This title can't be downloaded.")
        case .notSignedIn:
            return String(localized: "Sign in again to start downloads.")
        case .noSpace:
            return String(localized: "There isn't enough free space on this device for this download.")
        }
    }

    // MARK: - Existing entry

    @ViewBuilder
    private func existingControl(_ entry: DownloadEntry) -> some View {
        switch entry.state {
        case .queued, .downloading:
            DetailCircleMenu {
                Button("Pause") { store.pause(entry.itemID) }
                Button("Cancel Download", role: .destructive) { store.delete(entry.itemID) }
            } label: {
                ZStack {
                    DownloadProgressRing(fraction: entry.fractionComplete)
                    Image(systemName: "stop.fill")
                        .font(.system(size: Metrics.downloadMarkSize * 0.4))
                }
            }
            .accessibilityLabel(entry.state == .queued ? "Queued to download" : "Downloading")
            .accessibilityIdentifier("detail.download")
        case .paused:
            DetailCircleMenu {
                Button("Resume") { store.resume(entry.itemID, client: session.client) }
                Button("Delete", role: .destructive) { store.delete(entry.itemID) }
            } label: {
                Image(systemName: "pause.circle")
            }
            .accessibilityLabel("Download paused")
            .accessibilityIdentifier("detail.download")
        case .failed:
            VStack(spacing: Metrics.Space.xs) {
                DetailCircleMenu {
                    Button("Try Again") { store.resume(entry.itemID, client: session.client) }
                    Button("Delete", role: .destructive) { store.delete(entry.itemID) }
                } label: {
                    Image(systemName: "exclamationmark.circle")
                }
                .accessibilityLabel("Download failed")
                .accessibilityIdentifier("detail.download")
                if let failure = entry.failure {
                    Text(failure)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        case .complete:
            DetailCircleMenu {
                Button("Delete Download", role: .destructive) { confirmingDelete = true }
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .fontWeight(.bold)
            }
            .accessibilityLabel("Downloaded")
            .accessibilityIdentifier("detail.download")
            .confirmationDialog(
                "Delete Download?",
                isPresented: $confirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Download", role: .destructive) { store.delete(entry.itemID) }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

/// Determinate once the size is known, spinning before.
private struct DownloadProgressRing: View {
    let fraction: Double?

    @State private var isSpinning = false

    var body: some View {
        Group {
            if let fraction {
                Circle()
                    .trim(from: 0, to: max(0.03, fraction))
                    .stroke(style: StrokeStyle(lineWidth: Metrics.downloadRingLineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(style: StrokeStyle(lineWidth: Metrics.downloadRingLineWidth, lineCap: .round))
                    .rotationEffect(.degrees(isSpinning ? 360 : 0))
                    .animation(.linear(duration: Motion.crossfade).repeatForever(autoreverses: false), value: isSpinning)
                    .onAppear { isSpinning = true }
            }
        }
        .frame(width: Metrics.downloadMarkSize, height: Metrics.downloadMarkSize)
    }
}

/// Starts a download from a context menu: no estimate or confirmation.
/// Returns the failure for the caller to log, since a menu has no alert.
enum DownloadActions {
    @discardableResult
    static func start(item: MediaItem, quality: DownloadQuality, session: SessionStore) async -> String? {
        do {
            let resolved: MediaItem
            if item.mediaSources != nil {
                resolved = item
            } else {
                resolved = try await session.client.item(id: item.id)
            }
            guard let source = resolved.mediaSources?.first else {
                return "no media source for \(item.id)"
            }
            try await DownloadStore.shared.start(item: resolved, source: source, quality: quality, client: session.client)
            return nil
        } catch {
            return String(describing: error)
        }
    }
}
#endif
