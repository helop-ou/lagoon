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
            TextField("Header name", text: $header.name, prompt: Text("CF-Access-Client-Id"))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .modifier(UnderlinedField(isOn: underlined))
                .accessibilityIdentifier("\(identifierPrefix).header.\(index).name")
            SecureField("Value", text: $header.value)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .modifier(UnderlinedField(isOn: underlined))
                .accessibilityIdentifier("\(identifierPrefix).header.\(index).value")
            Button("Remove \(header.trimmedName.isEmpty ? "Header" : header.trimmedName)", role: .destructive) {
                headers.removeAll { $0.id == header.id }
            }
            .accessibilityIdentifier("\(identifierPrefix).header.\(index).remove")
        }
        Button("Add Header") {
            headers.append(CustomHTTPHeader())
        }
        .accessibilityIdentifier("\(identifierPrefix).header.add")
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
