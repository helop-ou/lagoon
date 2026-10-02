import SwiftUI

/// Rows for the custom HTTP headers a server behind a forward-auth proxy
/// needs, such as a Cloudflare Access service token. Empty by default; the
/// caller validates and stores them when it connects.
struct CustomHeaderFields: View {
    @Binding var headers: [CustomHTTPHeader]
    /// Where the fields are, for UI tests: "server" or "seerr".
    let identifierPrefix: String
    /// Outside a Form, each header's fields form an onboarding card.
    var onboarding = false

    static let footer: LocalizedStringKey =
        "For a server behind an access proxy such as Cloudflare Access, Authelia or Authentik. Lagoon sends these with every request to that server, only over HTTPS, and keeps them in the keychain."

    var body: some View {
        ForEach($headers) { $header in
            let index = headers.firstIndex { $0.id == header.id } ?? 0
            if usesOnboardingLayout {
                // Outside a Form nothing separates one header from the next,
                // so each keeps its fields and its Remove together.
                VStack(alignment: .trailing, spacing: Metrics.Space.s) {
                    onboardingCard { fields($header, index: index) }
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
        onboarding
        #else
        false
        #endif
    }

    @ViewBuilder
    private func fields(_ header: Binding<CustomHTTPHeader>, index: Int) -> some View {
        TextField("Header name", text: header.name, prompt: Text("CF-Access-Client-Id"))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .modifier(OnboardingHeaderField(isOn: usesOnboardingLayout))
            .accessibilityIdentifier("\(identifierPrefix).header.\(index).name")
        SecureField("Value", text: header.value)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .modifier(OnboardingHeaderField(isOn: usesOnboardingLayout))
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

extension CustomHeaderFields {
    @ViewBuilder
    private func onboardingCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        #if os(iOS)
        OnboardingFieldGroup { content() }
        #else
        content()
        #endif
    }
}

private struct OnboardingHeaderField: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        if isOn { content.modifier(OnboardingField()) } else { content }
        #else
        content
        #endif
    }
}
