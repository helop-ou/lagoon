import SwiftUI

/// The Legal section, shown in Settings → About and in the sign-in screens'
/// About sheet, since it must be reachable without an account. An unpublished
/// destination has no row.
struct LegalSettingsSection: View {
    @State private var showingAcknowledgements = false
    #if os(tvOS)
    @State private var presentedAddress: LegalAddress?
    #endif

    var body: some View {
        #if os(tvOS)
        tvSection
        #else
        phoneSection
        #endif
    }

    // MARK: - tvOS

    #if os(tvOS)
    private var tvSection: some View {
        TVSettingsSection("Legal") {
            Button {
                showingAcknowledgements = true
            } label: {
                TVSettingsActionLabel("Acknowledgements", value: Self.componentsValue)
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("settings.about.acknowledgements")

            if let url = LegalDestinations.privacyPolicy {
                addressButton("Privacy Policy", url: url, identifier: "settings.about.privacy")
            }
            if let url = LegalDestinations.support {
                addressButton("Support", url: url, identifier: "settings.about.support")
            }
        }
        .sheet(isPresented: $showingAcknowledgements) {
            AcknowledgementsView()
                .frame(
                    width: Metrics.modalPanelSize.width,
                    height: Metrics.modalPanelSize.height
                )
                .presentationSizing(.fitted)
        }
        .sheet(item: $presentedAddress) { address in
            LegalAddressSheet(address: address)
                .frame(width: Metrics.modalPanelSize.width)
                .presentationSizing(.fitted)
        }
    }

    /// tvOS has no browser, so this shows the address to scan or type elsewhere.
    private func addressButton(
        _ title: LocalizedStringKey,
        url: URL,
        identifier: String
    ) -> some View {
        Button {
            presentedAddress = LegalAddress(id: identifier, title: title, url: url)
        } label: {
            TVSettingsActionLabel(title, value: LegalDestinations.displayAddress(url))
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier(identifier)
    }
    #endif

    // MARK: - iOS

    #if !os(tvOS)
    private var phoneSection: some View {
        Section("Legal") {
            Button {
                showingAcknowledgements = true
            } label: {
                LabeledContent("Acknowledgements", value: Self.componentsValue)
            }
            .accessibilityIdentifier("settings.about.acknowledgements")
            // On the Button: a modifier on a Section stops the List treating it as one.
            .sheet(isPresented: $showingAcknowledgements) {
                NavigationStack { AcknowledgementsView() }
            }

            if let url = LegalDestinations.privacyPolicy {
                Link("Privacy Policy", destination: url)
                    .accessibilityIdentifier("settings.about.privacy")
            }
            if let url = LegalDestinations.support {
                Link("Support", destination: url)
                    .accessibilityIdentifier("settings.about.support")
            }
        }
    }
    #endif

    private static var componentsValue: String {
        let count = Acknowledgements.components.count
        return count == 1
            ? String(localized: "1 component")
            : String(localized: "\(count) components")
    }
}

#if os(tvOS)
struct LegalAddress: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let url: URL
}

/// Internal so the DEBUG gallery can open it.
struct LegalAddressSheet: View {
    @Environment(\.dismiss) private var dismiss
    let address: LegalAddress

    var body: some View {
        VStack(spacing: Metrics.Space.l) {
            Text(address.title)
                .font(.title3.bold())

            // The code to scan, with the address to type as a fallback.
            QRCodeView(text: address.url.absoluteString)

            Text(LegalDestinations.displayAddress(address.url))
                .font(.title2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("Scan the code, or open this address on your phone or computer.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Done") { dismiss() }
                .buttonStyle(.glass)
                .padding(.top, Metrics.Space.l)
        }
        .padding(Metrics.Space.section)
        .onExitCommand { dismiss() }
        .accessibilityIdentifier("\(address.id).sheet")
    }
}
#endif

/// Settings → About's Legal rows, for someone who has not signed in.
struct AboutLagoonSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        phoneBody
        #endif
    }

    #if os(tvOS)
    private var tvBody: some View {
        // The changelog's panel shape: title, scrolling content, Done. No
        // NavigationStack — see `AcknowledgementsView`.
        VStack(spacing: 0) {
            Text("About Lagoon")
                .font(.title3.bold())
                .padding(Metrics.Space.l)

            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.Space.xxl) {
                    TVSettingsSection("Application") {
                        ForEach(Self.applicationRows, id: \.title) { row in
                            TVSettingsActionLabel(LocalizedStringKey(row.title), value: row.value)
                        }
                    }

                    LegalSettingsSection()
                }
                .padding(.horizontal, Metrics.Space.xl)
                .padding(.bottom, Metrics.Space.xl)
            }

            Button("Done") { dismiss() }
                .buttonStyle(.glass)
                .padding(Metrics.Space.l)
        }
        .frame(
            width: Metrics.modalPanelSize.width,
            height: Metrics.modalPanelSize.height
        )
        .onExitCommand { dismiss() }
        .accessibilityIdentifier("signin.about.sheet")
    }
    #endif

    #if !os(tvOS)
    private var phoneBody: some View {
        NavigationStack {
            ThemedForm {
                Section("Application") {
                    ForEach(Self.applicationRows, id: \.title) { row in
                        LabeledContent(row.title, value: row.value)
                    }
                }

                LegalSettingsSection()
            }
            .navigationTitle("About Lagoon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("signin.about.sheet")
    }
    #endif

    private struct Row {
        let title: String
        let value: String
    }

    private static var applicationRows: [Row] {
        [
            Row(title: "Name", value: "Lagoon"),
            Row(title: "Version", value: Changelog.version()),
            Row(title: "Build", value: Changelog.build()),
        ]
    }
}

/// Last in the onboarding column, never the initial focus.
struct AboutLagoonButton: View {
    @State private var showingAbout = false

    var body: some View {
        Button("About Lagoon") { showingAbout = true }
            #if os(tvOS)
            .buttonStyle(.glass)
            #else
            .buttonStyle(.plain)
            .font(.footnote)
            .frame(minHeight: Metrics.touchTarget)
            #endif
            .accessibilityIdentifier("signin.about")
            .sheet(isPresented: $showingAbout) {
                #if os(tvOS)
                AboutLagoonSheet()
                    .presentationSizing(.fitted)
                #else
                AboutLagoonSheet()
                #endif
            }
    }
}
