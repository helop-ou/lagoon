import SwiftUI

struct ServerConnectView: View {
    @Environment(SessionStore.self) private var session

    @State private var address = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var localNetworkAccessDenied = false
    @State private var connectionTask: Task<Void, Never>?
    @State private var headers: [CustomHTTPHeader] = []
    @State private var showsAdvanced = false

    var body: some View {
        ZStack {
            GroundBackground()

            // All onboarding screens share this backdrop, so they read as one place.
            JellyfishSwimLayer()

            #if os(iOS)
            ScrollView {
                VStack(spacing: Metrics.Space.xl) {
                    VStack(spacing: Metrics.Space.l) {
                        LagoonLockup(layout: .horizontal, symbolHeight: Metrics.lockupHeaderSymbolHeight)
                        Text("Connect to your Jellyfin server")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Metrics.Space.l)

                    addressField
                    advancedSection
                    connectButton
                        .buttonStyle(.glass)
                        .controlSize(.large)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                    if localNetworkAccessDenied { LocalNetworkRecoveryView() }

                    AboutLagoonButton()
                }
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Metrics.screenGutter)
                .padding(.vertical, Metrics.Space.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            #else
            // Scrolls once the custom headers are open, and stays centred
            // while everything fits; focus moving down brings fields into view.
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: Metrics.Space.l) {
                        LagoonLockup()
                        Text("Connect to your Jellyfin server")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, Metrics.Space.l)

                        addressField
                        advancedSection
                            .buttonStyle(.glass)
                        connectButton
                            .buttonStyle(.glass)

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.callout)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }

                        // Legal information before any account. Last, so the
                        // address field keeps the initial focus.
                        AboutLagoonButton()
                            .padding(.top, Metrics.Space.xl)
                    }
                    .frame(maxWidth: 700)
                    .padding(.horizontal, Metrics.screenGutter)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollClipDisabled()
            }
            #endif
        }
        .onDisappear { connectionTask?.cancel() }
    }

    private var addressField: some View {
        TextField("Server address", text: $address, prompt: Text("Server URL or IP"))
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("server.address")
            #if os(iOS)
            .textFieldStyle(.plain)
            .frame(minHeight: Metrics.touchTarget)
            .overlay(alignment: .bottom) { Divider() }
            .keyboardType(.URL)
            .submitLabel(.go)
            #endif
            .onSubmit(connect)
    }

    /// Custom headers for a server behind an access proxy. Collapsed and
    /// empty unless asked for, so nothing changes for anyone else.
    @ViewBuilder
    private var advancedSection: some View {
        if showsAdvanced {
            VStack(alignment: .leading, spacing: Metrics.Space.s) {
                Text("Custom Headers")
                    .font(.headline)
                CustomHeaderFields(headers: $headers, identifierPrefix: "server", underlined: true)
                Text(CustomHeaderFields.footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            Button("Advanced") {
                showsAdvanced = true
                if headers.isEmpty { headers = [CustomHTTPHeader()] }
            }
            .accessibilityIdentifier("server.advanced")
        }
    }

    private var connectButton: some View {
        Button(action: connect) {
            if isConnecting {
                ProgressView()
            } else {
                Text("Connect")
                    .frame(maxWidth: .infinity)
            }
        }
        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
        .accessibilityIdentifier("server.connect")
    }

    private func connect() {
        guard !isConnecting else { return }
        isConnecting = true
        errorMessage = nil
        localNetworkAccessDenied = false
        // Saved before the first request, which the proxy answers too.
        let undoHeaders: @Sendable () -> Void
        do {
            undoHeaders = try ServerHeaderStore.shared.stage(headers, for: address, service: .jellyfin)
        } catch let problem as CustomHTTPHeader.Problem {
            errorMessage = problem.message
            isConnecting = false
            return
        } catch {
            errorMessage = "Lagoon couldn't save the custom headers. Try again."
            isConnecting = false
            return
        }
        connectionTask = Task {
            defer { isConnecting = false }
            do {
                try await session.connect(to: address)
            } catch is CancellationError {
                undoHeaders()
            } catch ServerAddress.Failure.invalid {
                undoHeaders()
                errorMessage = ServerAddress.Failure.invalid.localizedDescription
            } catch LocalNetworkAccess.Failure.denied {
                undoHeaders()
                localNetworkAccessDenied = true
                errorMessage = LocalNetworkAccess.Failure.denied.localizedDescription
            } catch {
                undoHeaders()
                if !Task.isCancelled {
                    errorMessage = headers.contains { !$0.trimmedName.isEmpty }
                        ? "Couldn't reach a Jellyfin server at that address. Check the address, the custom headers and the network connection, then try again."
                        : "Couldn't reach a Jellyfin server at that address. Check the address and network connection, then try again."
                }
            }
        }
    }
}
