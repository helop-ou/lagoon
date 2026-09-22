import SwiftUI

/// "Who's watching?" Shown only when no account can be resumed, or from Settings.
struct AccountPickerView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.displayScale) private var displayScale
    @State private var errorMessage: String?
    @State private var accountToForget: StoredAccount?

    /// Only when accounts span more than one server.
    private var showsServer: Bool {
        Set(session.accounts.map(\.serverURL)).count > 1
    }

    var body: some View {
        ZStack {
            GroundBackground()
            JellyfishSwimLayer(school: .besideTheRail)

            VStack(spacing: Metrics.Space.section) {
                VStack(spacing: Metrics.Space.l) {
                    LagoonLockup(
                        layout: .horizontal,
                        symbolHeight: Metrics.lockupHeaderSymbolHeight
                    )
                    Text("Who's watching?")
                        .font(.largeTitle.bold())
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: Metrics.cardSpacing) {
                        ForEach(session.accounts) { account in
                            accountButton(account)
                        }
                        addButton
                    }
                    // Room for the focus lift (see docs/design-system.md).
                    .padding(.horizontal, Metrics.screenGutter)
                    .padding(.vertical, Metrics.railTopPadding)
                }
                .scrollClipDisabled()
            }
        }
        .alert("Couldn't Forget User", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "The saved credential could not be removed.")
        }
        .confirmationDialog(
            "Forget \(accountToForget?.displayName ?? "This User")?",
            isPresented: Binding(
                get: { accountToForget != nil },
                set: { if !$0 { accountToForget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Forget This User", role: .destructive) {
                guard let account = accountToForget else { return }
                accountToForget = nil
                forget(account)
            }
            Button("Cancel", role: .cancel) {
                accountToForget = nil
            }
        } message: {
            Text("This removes the saved sign-in from Lagoon. You can add the account again later.")
        }
    }

    private func accountButton(_ account: StoredAccount) -> some View {
        Button {
            session.switchTo(account)
        } label: {
            VStack(spacing: Metrics.Space.m) {
                avatar(for: account)
                VStack(spacing: Metrics.Space.hair) {
                    Text(account.displayName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if showsServer {
                        Text(account.serverLabel)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
                .frame(width: Metrics.accountTileSize)
            }
        }
        .cardButtonStyle()
        .accessibilityIdentifier("account.select.\(account.userId)")
        .contextMenu {
            Button(role: .destructive) {
                accountToForget = account
            } label: {
                Label("Forget This User", systemImage: "person.crop.circle.badge.minus")
            }
        }
    }

    private var addButton: some View {
        Button {
            session.addAccount()
        } label: {
            VStack(spacing: Metrics.Space.m) {
                ZStack {
                    RoundedRectangle(cornerRadius: Metrics.cardArtRadius)
                        .fill(.white.opacity(0.08))
                    Image(systemName: "plus")
                        .font(Typography.glyph)
                }
                .frame(width: Metrics.accountTileSize, height: Metrics.accountTileSize)

                Text("Add Account")
                    .font(.callout.weight(.semibold))
                    .frame(width: Metrics.accountTileSize)
            }
        }
        .cardButtonStyle()
        .accessibilityIdentifier("account.add")
    }

    /// The user's picture, or initials while loading and when there is none.
    private func avatar(for account: StoredAccount) -> some View {
        let pixels = ArtworkSizing.pixels(for: Metrics.accountTileSize, displayScale: displayScale)
        // Keep the fill under the picture; a transparent PNG would float.
        return ZStack {
            RoundedRectangle(cornerRadius: Metrics.cardArtRadius)
                .fill(.white.opacity(0.12))
            CachedAsyncImage(url: account.avatarURL(maxWidth: pixels), maxPixelSize: pixels) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Text(initials(for: account.displayName))
                    .font(.largeTitle.weight(.semibold))
            }
        }
        .frame(width: Metrics.accountTileSize, height: Metrics.accountTileSize)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    private func forget(_ account: StoredAccount) {
        do {
            try session.remove(account)
        } catch {
            // RootView shows cleanup failures even if this view unmounts.
            if session.cleanupErrorMessage == nil { errorMessage = error.localizedDescription }
        }
    }
}
