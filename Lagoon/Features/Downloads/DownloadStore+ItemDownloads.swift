#if os(iOS)
import os
import SwiftUI

/// Downloads as shared cards and menus show them.
extension DownloadStore: ItemDownloadPresenting {
    func contextMenuItems(for item: MediaItem) -> AnyView {
        AnyView(DownloadContextMenuItems(item: item, store: self))
    }
}

/// A card's long-press download entries. Movies and episodes only; others
/// have no file of their own. A new download gets `DownloadControl`'s
/// quality picker.
private struct DownloadContextMenuItems: View {
    let item: MediaItem
    let store: DownloadStore
    @Environment(SessionStore.self) private var session

    var body: some View {
        if item.type == .movie || item.type == .episode {
            if store.isDownloaded(item.id) {
                Button(role: .destructive) {
                    store.delete(item.id)
                } label: {
                    Label("Delete Download", systemImage: "arrow.down.circle.fill")
                }
            } else if store.entry(for: item.id) != nil {
                Button(role: .destructive) {
                    store.delete(item.id)
                } label: {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            } else if session.client.cachedContentDownloadingAllowed == true {
                Menu {
                    ForEach(qualities) { quality in
                        Button(quality.title) {
                            Task {
                                if let failure = await DownloadActions.start(item: item, quality: quality, session: session) {
                                    DownloadStore.log.error("Context menu download failed: \(failure, privacy: .public)")
                                }
                            }
                        }
                    }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
        }
    }

    /// Default quality first, as in `DownloadControl`. High and Standard need
    /// transcode permission; Original needs only download permission.
    private var qualities: [DownloadQuality] {
        DownloadQuality.ordered(
            default: store.defaultQuality,
            transcodingAllowed: session.client.cachedVideoTranscodingAllowed == true
        )
    }
}
#endif
