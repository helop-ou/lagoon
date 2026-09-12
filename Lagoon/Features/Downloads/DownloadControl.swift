import SwiftUI

#if os(iOS)
/// The download action beside Play on a movie or episode's detail page
/// (HEL-166): a glass circle in the same family as `ItemActionRow`'s
/// watched and favorite toggles, its glyph and menu following the entry's
/// state. State reads through symbol weight and opacity, never color
/// (HEL-50).
///
/// Hidden entirely while the account can't download and there is nothing
/// already on disk for this item, so a server that disallows downloads
/// never shows a control that would only refuse.
struct DownloadControl: View {
    let item: MediaItem

    @Environment(SessionStore.self) private var session
    private var store: DownloadStore { .shared }

    @State private var permitted: Bool?
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

    /// The item to read media sources from: a detail read already carries
    /// them; a rail item or context-menu caller does not, so this control
    /// fetches its own copy the first time it needs one.
    private var sourceItem: MediaItem {
        item.mediaSources != nil ? item : (fetchedItem ?? item)
    }

    var body: some View {
        Group {
            if let entry {
                existingControl(entry)
            } else if permitted == true {
                newDownloadMenu
            }
        }
        .task(id: item.id) {
            // Always resolved, entry or not: an entry's Delete/Cancel button
            // can bring this view back to the no-entry state without a new
            // `item.id`, and that state needs `permitted` to already be an
            // answer rather than a `nil` that leaves the control blank.
            async let downloadAllowed = store.canDownload(client: session.client)
            async let transcodeAllowed = session.client.canTranscodeForDownload()
            permitted = await downloadAllowed
            transcodingAllowed = await transcodeAllowed
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

    /// Quality choices with the default first, so the common case is the
    /// menu's first tap. High and Standard are transcodes the server has to
    /// build, so they only appear when the account may ask for one; Original
    /// is always offered once downloading itself is permitted (HEL-166).
    private var orderedQualities: [DownloadQuality] {
        let allowed: [DownloadQuality] = transcodingAllowed == true ? DownloadQuality.allCases : [.original]
        guard allowed.contains(store.defaultQuality) else { return allowed }
        return [store.defaultQuality] + allowed.filter { $0 != store.defaultQuality }
    }

    private var newDownloadMenu: some View {
        Menu {
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
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
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
            Menu {
                Button("Pause") { store.pause(entry.itemID) }
                Button("Cancel Download", role: .destructive) { store.delete(entry.itemID) }
            } label: {
                ZStack {
                    DownloadProgressRing(fraction: entry.fractionComplete)
                    Image(systemName: "stop.fill")
                        .font(.system(size: Metrics.downloadMarkSize * 0.4))
                }
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(entry.state == .queued ? "Queued to download" : "Downloading")
            .accessibilityIdentifier("detail.download")
        case .paused:
            Menu {
                Button("Resume") { store.resume(entry.itemID, client: session.client) }
                Button("Delete", role: .destructive) { store.delete(entry.itemID) }
            } label: {
                Image(systemName: "pause.circle")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Download paused")
            .accessibilityIdentifier("detail.download")
        case .failed:
            VStack(spacing: Metrics.Space.xs) {
                Menu {
                    Button("Try Again") { store.resume(entry.itemID, client: session.client) }
                    Button("Delete", role: .destructive) { store.delete(entry.itemID) }
                } label: {
                    Image(systemName: "exclamationmark.circle")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
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
            Menu {
                Button("Delete Download", role: .destructive) { confirmingDelete = true }
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .fontWeight(.bold)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
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

/// The queued/downloading glyph's progress ring: a determinate arc once the
/// expected size is known, an indeterminate spin before it (HEL-166).
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

/// Starts a download from a lighter-weight caller than `DownloadControl`,
/// such as the item context menu (HEL-166): no size estimate, no large- or
/// free-space confirmation, just the quality the viewer picked. Failures are
/// returned for the caller to log rather than shown, since a context menu
/// has no room for an alert.
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
