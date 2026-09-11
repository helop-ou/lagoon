#if DEBUG && os(iOS)
import SwiftUI

/// Settings → Developer → Downloads Spike: the manifest as a list, with
/// pause, resume and delete. Debug builds, iOS only (HEL-166).
struct DownloadSpikeView: View {
    @State private var store = DownloadSpikeStore.shared
    @AppStorage("downloads.spike.wifiOnly") private var wifiOnly = false

    var body: some View {
        TouchSettingsPage("Downloads Spike") {
            Section {
                Toggle("Wi-Fi only (next launch)", isOn: $wifiOnly)
                LabeledContent("Folder", value: store.directory.lastPathComponent)
            } footer: {
                Text("Start a download from a film's page. Transfers use a background session; suspend or kill the app to test resumption.")
            }
            Section("Downloads") {
                if store.entries.isEmpty {
                    Text("Nothing downloaded").foregroundStyle(.secondary)
                }
                ForEach(store.entries) { entry in
                    row(entry)
                }
            }
        }
    }

    private func row(_ entry: DownloadSpikeEntry) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xs) {
            Text(entry.title)
            Text("\(entry.kind.rawValue) · \(entry.state.rawValue) · \(bytes(entry.receivedBytes))\(entry.expectedBytes.map { " of \(bytes($0))" } ?? "")")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let failure = entry.failure {
                Text(failure).font(.caption).foregroundStyle(.secondary)
            }
            if let expected = entry.expectedBytes, expected > 0, entry.state == .downloading {
                ProgressView(value: Double(entry.receivedBytes), total: Double(expected))
            }
            HStack(spacing: Metrics.Space.m) {
                if entry.state == .downloading {
                    Button("Pause") { store.pause(entry) }
                }
                if entry.resumeDataFile != nil, entry.state != .downloading {
                    Button("Resume") { store.resume(entry) }
                }
                Button("Delete", role: .destructive) { store.delete(entry) }
            }
            .buttonStyle(.bordered)
            .font(.caption)
        }
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
#endif
