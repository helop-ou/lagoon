import SwiftUI

#if os(iOS)
/// Downloads preferences (HEL-166): the quality newly started downloads
/// default to, whether transfers wait for Wi-Fi, how much space they use on
/// this device, how many titles are on it with a way to the list, and a way
/// to clear all of them at once.
struct DownloadsSettingsView: View {
    private var store: DownloadStore { .shared }

    @Environment(\.showDownloadsList) private var showDownloadsList
    @State private var confirmingDeleteAll = false

    var body: some View {
        TouchSettingsPage("Downloads") {
            Section {
                Picker("Quality", selection: qualityBinding) {
                    ForEach(DownloadQuality.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .accessibilityIdentifier("settings.downloads.quality")
            } footer: {
                Text(store.defaultQuality.detail)
            }

            Section {
                Toggle("Wi-Fi Only", isOn: wifiOnlyBinding)
                    .accessibilityIdentifier("settings.downloads.wifiOnly")
            } footer: {
                Text("New downloads wait for Wi-Fi and pause in Low Data Mode. A download already under way keeps going.")
            }

            Section {
                LabeledContent("Storage", value: storageText)
                LabeledContent("Downloaded Titles", value: store.entries.count, format: .number)
                Button("Show Downloads") {
                    showDownloadsList?()
                }
                .disabled(store.entries.isEmpty)
                .accessibilityIdentifier("settings.downloads.show")
                Button("Delete All Downloads", role: .destructive) {
                    confirmingDeleteAll = true
                }
                .disabled(store.entries.isEmpty)
                .accessibilityIdentifier("settings.downloads.deleteAll")
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

    private var qualityBinding: Binding<DownloadQuality> {
        Binding(get: { store.defaultQuality }, set: { store.defaultQuality = $0 })
    }

    private var wifiOnlyBinding: Binding<Bool> {
        Binding(get: { store.wifiOnly }, set: { store.wifiOnly = $0 })
    }

    private var storageText: String {
        ByteCountFormatter.string(fromByteCount: store.storageUsed, countStyle: .file)
    }
}
#endif
