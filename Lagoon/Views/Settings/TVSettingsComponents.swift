#if os(tvOS)
import SwiftUI

/// A consistent tvOS settings destination. Every detail page owns both a
/// visible Back button and the remote's Menu/Escape command, so navigation
/// never depends on an implicit focus state.
struct TVSettingsPage<Content: View>: View {
    @Environment(\.dismiss) private var dismiss

    let title: LocalizedStringKey
    let backTitle: LocalizedStringKey
    let pageDescription: String?
    @ViewBuilder let content: Content

    init(
        _ title: LocalizedStringKey,
        backTitle: LocalizedStringKey = "Settings",
        description: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.backTitle = backTitle
        self.pageDescription = description
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

                if let pageDescription {
                    Text(pageDescription)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.detail.description")
                }
            }
            .frame(width: Metrics.settingsIdentityWidth, alignment: .leading)
            .padding(.top, Metrics.Space.l)

            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.Space.xxl) {
                    content
                }
                .padding(.vertical, Metrics.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollClipDisabled()
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Metrics.screenGutter)
        .padding(.top, Metrics.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.forward")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
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
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }
}

struct TVSettingsOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String

    var id: Value { value }
}

/// A pull-down row whose label remains a normal full-width settings row.
/// SwiftUI's tvOS `.menu` Picker style otherwise collapses custom labels to
/// a small value-only pill, which hides what is being configured.
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
        // Keep UI automation, VoiceOver, and the focus engine attached to
        // the actual Menu button instead of its synthesized label children.
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
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
#endif
