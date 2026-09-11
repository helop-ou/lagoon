import SwiftUI

/// What Lagoon ships that it did not write: every third-party component, the
/// licence that governs it, and the names that belong to other projects
/// (HEL-143, audit A06).
///
/// Modelled on `ChangelogView`, and for its reasons: a modal you read and
/// dismiss rather than a pushed page, no `NavigationStack` on tvOS — its
/// title has no background of its own, so content scrolls visibly behind it,
/// and it squeezes the sheet to roughly half its natural width — and every
/// paragraph focusable, because tvOS scrolls by moving focus and a panel of
/// plain text cannot be scrolled at all.
///
/// The licence text is a second screen. On iOS that is a push; on tvOS,
/// without a navigation stack, the panel swaps its own scrolling content and
/// offers Back beside Done.
struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss

    /// Entries start collapsed: the list of names is what this was opened to
    /// show, and each entry's provenance is three lines you can ask for.
    @State private var expanded: Set<String> = []

    #if os(tvOS)
    @State private var readingLicense: ThirdPartyComponent?
    #endif

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        phoneBody
        #endif
    }

    // MARK: - tvOS

    #if os(tvOS)
    private var tvBody: some View {
        // The same three-part stack as the changelog — title, scrolling
        // content, footer — rather than safeAreaInset overlays, which draw
        // over the content and need their own material to hide it.
        VStack(spacing: 0) {
            Text(panelTitle)
                .font(.title3.bold())
                .padding(Metrics.Space.l)

            if let component = readingLicense {
                licenseParagraphs(for: component)
            } else {
                componentList
            }

            HStack(spacing: Metrics.Space.l) {
                if readingLicense != nil {
                    Button("Back") { closeLicense() }
                        .buttonStyle(.glass)
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.glass)
            }
            .padding(Metrics.Space.l)
        }
        // Menu leaves the licence text the way Back does, and only then the
        // sheet: one press should never skip a level.
        .onExitCommand {
            if readingLicense == nil { dismiss() } else { closeLicense() }
        }
        .accessibilityIdentifier("settings.acknowledgements")
    }

    private var panelTitle: String {
        readingLicense?.name ?? String(localized: "Acknowledgements")
    }

    private var componentList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Space.xxl) {
                ForEach(Acknowledgements.components) { component in
                    VStack(alignment: .leading, spacing: Metrics.Space.m) {
                        // The header is the control, as in the changelog:
                        // focus a component, press, and its provenance opens.
                        Button {
                            toggle(component)
                        } label: {
                            entryHeader(component)
                        }
                        .accessibilityIdentifier("settings.acknowledgements.\(component.id)")

                        if expanded.contains(component.id) {
                            entryDetail(component)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                trademarks
            }
            .padding(.horizontal, Metrics.Space.xl)
            .padding(.bottom, Metrics.Space.xl)
        }
    }

    private func licenseParagraphs(for component: ThirdPartyComponent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Space.l) {
                Text(component.licenseName)
                    .font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Focusable for the same reason the changelog's notes are: on
                // tvOS the scroll view follows focus, and text that cannot be
                // focused cannot be scrolled. Nothing pins the first
                // paragraph: the engine already opens the licence at its top,
                // and Down walks the text and then leaves it for the Back and
                // Done buttons below, which is the whole way out by remote.
                ForEach(Array(Self.paragraphs(of: component).enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .focusable()
                }
            }
            .padding(.horizontal, Metrics.Space.xl)
            .padding(.bottom, Metrics.Space.xl)
        }
    }

    private func closeLicense() {
        withAnimation(.easeInOut(duration: Motion.fast)) {
            readingLicense = nil
        }
    }
    #endif

    // MARK: - iOS

    #if !os(tvOS)
    private var phoneBody: some View {
        List {
            ForEach(Acknowledgements.components) { component in
                Section {
                    DisclosureGroup(isExpanded: expansion(of: component)) {
                        entryDetail(component)
                        NavigationLink {
                            licenseScreen(component)
                        } label: {
                            Text("License Text")
                        }
                        .accessibilityIdentifier("settings.acknowledgements.\(component.id).license")
                    } label: {
                        entryHeader(component)
                            .accessibilityIdentifier("settings.acknowledgements.\(component.id)")
                    }
                }
            }

            Section("Trademarks") {
                trademarks
            }
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .accessibilityIdentifier("settings.acknowledgements")
    }

    private func expansion(of component: ThirdPartyComponent) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(component.id) },
            set: { isExpanded in
                if isExpanded {
                    expanded.insert(component.id)
                } else {
                    expanded.remove(component.id)
                }
            }
        )
    }

    private func licenseScreen(_ component: ThirdPartyComponent) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Space.l) {
                Text(component.licenseName)
                    .font(.callout.weight(.medium))

                ForEach(Array(Self.paragraphs(of: component).enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.screenGutter)
        }
        .navigationTitle(component.name)
        .navigationBarTitleDisplayMode(.inline)
    }
    #endif

    // MARK: - Shared parts

    private func toggle(_ component: ThirdPartyComponent) {
        withAnimation(.easeInOut(duration: Motion.fast)) {
            if expanded.contains(component.id) {
                expanded.remove(component.id)
            } else {
                expanded.insert(component.id)
            }
        }
    }

    private func entryHeader(_ component: ThirdPartyComponent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.Space.m) {
            #if os(tvOS)
            // iOS gets its chevron from `DisclosureGroup`; the tvOS panel
            // draws its own, as the changelog does.
            Image(systemName: expanded.contains(component.id) ? "chevron.down" : "chevron.forward")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            #endif

            VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.Space.m) {
                    Text(component.name)
                        .font(.headline)
                    Text(component.version)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: Metrics.Space.m)
                    Text(component.licenseName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // What the component does stays visible while collapsed: it
                // is the line that says why Lagoon carries it at all.
                Text(component.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func entryDetail(_ component: ThirdPartyComponent) -> some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            detailLine(component.copyright)
            if let notes = component.notes {
                detailLine(notes)
            }
            // A viewer on Apple TV cannot follow a link, so the address is
            // what the screen gives them to type on another device.
            detailLine(String(localized: "Source: \(LegalDestinations.displayAddress(component.sourceURL))"))

            Button("License Text") {
                withAnimation(.easeInOut(duration: Motion.fast)) {
                    readingLicense = component
                }
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("settings.acknowledgements.\(component.id).license")
            .padding(.top, Metrics.Space.s)
        }
        #else
        detailLine(component.copyright)
        if let notes = component.notes {
            detailLine(notes)
        }
        Link(destination: component.sourceURL) {
            LabeledContent(
                "Source",
                value: LegalDestinations.displayAddress(component.sourceURL)
            )
        }
        #endif
    }

    private func detailLine(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(tvOS)
            .focusable()
            #endif
    }

    @ViewBuilder
    private var trademarks: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            Text("Trademarks")
                .font(.headline)
            trademarkNotice
        }
        #else
        trademarkNotice
        #endif
    }

    private var trademarkNotice: some View {
        Text(Acknowledgements.trademarkNotice)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(tvOS)
            .focusable()
            #endif
            .accessibilityIdentifier("settings.acknowledgements.trademarks")
    }

    /// Licence files are hard-wrapped to a terminal width they were never
    /// going to keep here: at ten feet those columns either re-wrap raggedly
    /// or force type too small to read. Each blank-line-separated paragraph
    /// is reflowed into one block instead, which is also what makes it a
    /// focus target the scroll view can follow.
    static func paragraphs(of component: ThirdPartyComponent) -> [String] {
        guard let text = Acknowledgements.licenseText(for: component) else {
            return [
                String(
                    localized: "This build is missing the text of this licence. It is published in full at the component's source address."
                )
            ]
        }
        return text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { paragraph in
                paragraph
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
    }
}
