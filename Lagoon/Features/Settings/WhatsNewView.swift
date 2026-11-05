import SwiftUI

/// The installed build's notes, from Settings → About and once after a minor
/// or major update.
struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    var entry: ChangelogEntry? = WhatsNew.entry
    /// Set for a build with no notes of its own yet, such as a development build.
    var unlistedVersion: String? = Changelog.runningBuildIsListed() ? nil : Changelog.runningDisplayVersion()

    var body: some View {
        #if os(tvOS)
        TVModalPanel(title: Text("What's New")) {
            notesContent
        }
        .accessibilityIdentifier("settings.whatsnew")
        #else
        ScrollView {
            notesContent
                .padding(.horizontal, Metrics.Space.xl)
                .padding(.bottom, Metrics.Space.xl)
        }
        .themedPageBackground()
        .navigationTitle("What's New")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "xmark", role: .close) { dismiss() }
            }
        }
        .accessibilityIdentifier("settings.whatsnew")
        #endif
    }

    private var notesContent: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xxl) {
            if let unlistedVersion {
                Text("You're running \(unlistedVersion), which has no notes yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let entry {
                VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                    Text("\(entry.displayVersion), \(entry.released)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(entry.headline)
                        .font(.title3.bold())
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.whatsnew.\(entry.build)")

                VStack(alignment: .leading, spacing: Metrics.Space.l) {
                    ForEach(entry.sections) { section in
                        VStack(alignment: .leading, spacing: Metrics.Space.s) {
                            Text(LocalizedStringKey(section.category.rawValue))
                                .accessibilityAddTraits(.isHeader)
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.primary)

                            ForEach(section.changes, id: \.self) { change in
                                HStack(alignment: .top, spacing: Metrics.Space.s) {
                                    Text("•")
                                        .accessibilityHidden(true)
                                    Text(change)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                #if os(tvOS)
                                // tvOS scrolls by focus. Unfocusable text cannot scroll.
                                .focusable()
                                #endif
                            }
                        }
                    }
                }
            }
        }
    }
}
