#if os(tvOS)
import SwiftUI

/// A tvOS settings page with a visible Back button and a Menu handler, so
/// navigation never depends on implicit focus.
struct TVSettingsPage<Content: View>: View {
    @Environment(\.dismiss) private var dismiss

    let title: LocalizedStringKey
    let backTitle: LocalizedStringKey
    let pageDescription: String?
    let titleLineLimit: Int
    @ViewBuilder let content: Content

    init(
        _ title: LocalizedStringKey,
        backTitle: LocalizedStringKey = "Settings",
        description: String? = nil,
        // Single long-word titles pass 1: with room to wrap, SwiftUI
        // hyphenates rather than scales.
        titleLineLimit: Int = 2,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.backTitle = backTitle
        self.pageDescription = description
        self.titleLineLimit = titleLineLimit
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.Space.section) {
            VStack(alignment: .leading, spacing: Metrics.Space.xl) {
                Button {
                    dismiss()
                } label: {
                    Label(backTitle, systemImage: "chevron.backward")
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("settings.detail.back")

                Text(title)
                    .font(.title.bold())
                    .lineLimit(titleLineLimit)
                    .minimumScaleFactor(0.6)

                if let pageDescription {
                    Text(pageDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.detail.description")
                }
            }
            // Full height, so Left from low controls finds Back.
            .frame(width: Metrics.settingsIdentityWidth, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .padding(.top, Metrics.Space.l)
            // Makes the whole identity column Back's focus region.
            .focusSection()

            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.Space.xxl) {
                    content
                }
                .padding(.vertical, Metrics.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollClipDisabled()
            // Some pages start with unfocusable content; this keeps a target right of Back.
            .focusSection()
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Metrics.screenGutter)
        .padding(.top, Metrics.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The app's background; otherwise Settings inherits the system grey.
        .themedPageBackground()
        .navigationBarBackButtonHidden(true)
        .onExitCommand { dismiss() }
    }
}

struct TVSettingsSection<Content: View>: View {
    let title: LocalizedStringKey
    let footer: LocalizedStringKey?
    @ViewBuilder let content: Content

    init(
        _ title: LocalizedStringKey,
        footer: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Metrics.Space.m)

            VStack(spacing: Metrics.Space.m) {
                content
            }

            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Metrics.Space.m)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The label of every tvOS settings row: a title, an optional value, and an
/// accessory glyph that says what the row does.
struct TVSettingsRowLabel: View {
    enum Accessory {
        /// A plain row, or a button that acts.
        case none
        /// Pushes a page.
        case navigation
        /// Opens a pull-down menu.
        case menu
    }

    let title: LocalizedStringKey
    let value: String?
    let accessory: Accessory

    init(_ title: LocalizedStringKey, value: String? = nil, accessory: Accessory = .none) {
        self.title = title
        self.value = value
        self.accessory = accessory
    }

    var body: some View {
        HStack(spacing: accessory == .navigation ? Metrics.Space.l : Metrics.Space.xl) {
            Text(title)
            Spacer(minLength: Metrics.Space.xl)
            if let value {
                Text(value)
                    .opacity(0.7)
                    .lineLimit(1)
            }
            if let glyph {
                Image(systemName: glyph)
                    .font(.caption.bold())
                    .opacity(0.55)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var glyph: String? {
        switch accessory {
        case .none: nil
        case .navigation: "chevron.forward"
        case .menu: "chevron.up.chevron.down"
        }
    }
}

/// A read-only row: a title and its value on a material, not focusable.
struct TVSettingsInfoRow: View {
    let title: LocalizedStringKey
    let value: String

    init(_ title: LocalizedStringKey, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        TVSettingsRowLabel(title, value: value)
            .padding(.horizontal, Metrics.Space.l)
            .frame(minHeight: Metrics.settingsRowMinHeight)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Metrics.settingsRowCornerRadius))
    }
}

struct TVSettingsOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String

    var id: Value { value }
}

/// A full-width pull-down row. The tvOS `.menu` Picker collapses custom
/// labels to a value-only pill.
struct TVSettingsMenuPicker<Value: Hashable>: View {
    let title: LocalizedStringKey
    /// Shown on the row; the selected option's title unless a caller's
    /// display differs from its menu entries.
    let valueTitle: String?
    let accessibilityIdentifier: String
    @Binding var selection: Value
    let options: [TVSettingsOption<Value>]

    init(
        title: LocalizedStringKey,
        valueTitle: String? = nil,
        accessibilityIdentifier: String,
        selection: Binding<Value>,
        options: [TVSettingsOption<Value>]
    ) {
        self.title = title
        self.valueTitle = valueTitle
        self.accessibilityIdentifier = accessibilityIdentifier
        _selection = selection
        self.options = options
    }

    private var resolvedValueTitle: String {
        valueTitle ?? options.first { $0.value == selection }?.title ?? ""
    }

    var body: some View {
        Menu {
            ForEach(options) { option in
                Toggle(isOn: Binding(
                    get: { selection == option.value },
                    set: { isSelected in
                        if isSelected { selection = option.value }
                    }
                )) {
                    Text(option.title)
                }
            }
        } label: {
            TVSettingsRowLabel(title, value: resolvedValueTitle, accessory: .menu)
        }
        .buttonStyle(.glass)
        // Keep automation, VoiceOver and focus on the Menu button, not its label children.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(resolvedValueTitle)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

extension TVSettingsMenuPicker where Value: CaseIterable {
    /// One option per case, titled by `optionTitle`.
    init(
        title: LocalizedStringKey,
        accessibilityIdentifier: String,
        selection: Binding<Value>,
        optionTitle: (Value) -> String
    ) {
        self.init(
            title: title,
            accessibilityIdentifier: accessibilityIdentifier,
            selection: selection,
            options: Value.allCases.map { TVSettingsOption(value: $0, title: optionTitle($0)) }
        )
    }
}

/// A native toggle with the same row geometry as the other tvOS settings controls.
struct TVSettingsToggle: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            TVCheckmarkToggleLabel(title: title, isOn: isOn)
        }
        .buttonStyle(.glass)
        .accessibilityValue(isOn ? "On" : "Off")
        .padding(.horizontal, Metrics.Space.l)
        .frame(minHeight: Metrics.settingsRowMinHeight)
    }
}
#endif
