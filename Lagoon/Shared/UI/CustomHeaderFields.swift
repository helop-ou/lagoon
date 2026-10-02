import SwiftUI

/// Rows for the custom HTTP headers a server behind a forward-auth proxy
/// needs, such as a Cloudflare Access service token. Empty by default; the
/// caller validates and stores them when it connects.
struct CustomHeaderFields: View {
    @Binding var headers: [CustomHTTPHeader]
    /// Where the fields are, for UI tests: "server" or "seerr".
    let identifierPrefix: String
    /// Outside a Form, the fields take the onboarding address field's look.
    var underlined = false

    static let footer: LocalizedStringKey =
        "For a server behind an access proxy such as Cloudflare Access, Authelia or Authentik. Lagoon sends these with every request to that server, only over HTTPS, and keeps them in the keychain."

    var body: some View {
        ForEach($headers) { $header in
            let index = headers.firstIndex { $0.id == header.id } ?? 0
            if usesOnboardingLayout {
                // Outside a Form nothing separates one header from the next,
                // so each keeps its fields and its Remove together.
                VStack(alignment: .trailing, spacing: Metrics.Space.s) {
                    fields($header, index: index)
                    removeButton(header, index: index)
                        .font(.footnote)
                        .buttonStyle(.borderless)
                }
            } else {
                fields($header, index: index)
                removeButton(header, index: index)
            }
        }
        if usesOnboardingLayout {
            Button("Add Header", systemImage: "plus", action: addHeader)
                .buttonStyle(.glass)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("\(identifierPrefix).header.add")
        } else {
            Button("Add Header", action: addHeader)
                .accessibilityIdentifier("\(identifierPrefix).header.add")
        }
    }

    private var usesOnboardingLayout: Bool {
        #if os(iOS)
        underlined
        #else
        false
        #endif
    }

    @ViewBuilder
    private func fields(_ header: Binding<CustomHTTPHeader>, index: Int) -> some View {
        TextField("Header name", text: header.name, prompt: Text("CF-Access-Client-Id"))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .modifier(UnderlinedField(isOn: underlined))
            .accessibilityIdentifier("\(identifierPrefix).header.\(index).name")
        SecureField("Value", text: header.value)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .modifier(UnderlinedField(isOn: underlined))
            .accessibilityIdentifier("\(identifierPrefix).header.\(index).value")
    }

    private func removeButton(_ header: CustomHTTPHeader, index: Int) -> some View {
        Button("Remove \(header.trimmedName.isEmpty ? "Header" : header.trimmedName)", role: .destructive) {
            headers.removeAll { $0.id == header.id }
        }
        .accessibilityIdentifier("\(identifierPrefix).header.\(index).remove")
    }

    private func addHeader() {
        headers.append(CustomHTTPHeader())
    }
}

/// The onboarding field look on iPhone and iPad: plain, a touch target
/// tall, over a hairline. tvOS keeps its system fields.
private struct UnderlinedField: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        if isOn {
            content
                .textFieldStyle(.plain)
                .frame(minHeight: Metrics.touchTarget)
                .overlay(alignment: .bottom) { Divider() }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
