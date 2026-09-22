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
        .background(Theme.background.ignoresSafeArea())
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

struct TVSettingsNavigationLabel: View {
    let title: LocalizedStringKey
    let detail: String?

    init(
        _ title: LocalizedStringKey,
        detail: String? = nil
    ) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: Metrics.Space.l) {
            Text(title)
            Spacer(minLength: Metrics.Space.xl)
            if let detail {
                Text(detail)
                    .opacity(0.7)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.forward")
                .font(.caption.bold())
                .opacity(0.55)
        }
        .frame(maxWidth: .infinity)
    }
}

struct TVSettingsValueLabel: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(spacing: Metrics.Space.xl) {
            Text(title)
            Spacer(minLength: Metrics.Space.xl)
            Text(value)
                .opacity(0.7)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.bold())
                .opacity(0.55)
        }
        .frame(maxWidth: .infinity)
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
    let valueTitle: String
    let accessibilityIdentifier: String
    @Binding var selection: Value
    let options: [TVSettingsOption<Value>]

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
            TVSettingsValueLabel(title: title, value: valueTitle)
        }
        .buttonStyle(.glass)
        // Keep automation, VoiceOver and focus on the Menu button, not its label children.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(valueTitle)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct TVSettingsActionLabel: View {
    let title: LocalizedStringKey
    let value: String?

    init(_ title: LocalizedStringKey, value: String? = nil) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(spacing: Metrics.Space.xl) {
            Text(title)
            Spacer(minLength: Metrics.Space.xl)
            if let value {
                Text(value)
                    .opacity(0.7)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
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
            HStack(spacing: Metrics.Space.xl) {
                Text(title)
                Spacer(minLength: Metrics.Space.xl)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .opacity(isOn ? 1 : 0.55)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.glass)
        .accessibilityValue(isOn ? "On" : "Off")
        .padding(.horizontal, Metrics.Space.l)
        .frame(minHeight: 66)
    }
}
#endif
