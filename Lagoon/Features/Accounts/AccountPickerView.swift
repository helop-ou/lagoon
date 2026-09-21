import SwiftUI

/// "Who's watching?" — the remembered server+user pairs, plus a way to add
/// another.
///
/// Not shown at every launch: `SessionStore.restore()` resumes the last
/// account, so a single-profile install never sees this. It appears when no
/// account can be resumed, and whenever Settings asks for it.
struct AccountPickerView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.displayScale) private var displayScale
    @State private var errorMessage: String?
    @State private var accountToForget: StoredAccount?

    /// The server line only earns its place when accounts actually span more
    /// than one server; on the common single-server setup it is noise under
    /// every avatar.
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
                    // The focus lift needs room inside the scroller, same
                    // rule as every other rail (see docs/design-system.md).
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

    /// The user's picture when Jellyfin has one; initials while it
    /// loads and for the many users who have none, because an empty avatar
    /// frame reads worse than a letter.
    private func avatar(for account: StoredAccount) -> some View {
        let pixels = ArtworkSizing.pixels(for: Metrics.accountTileSize, displayScale: displayScale)
        // The tile fill stays under the picture: Jellyfin serves whatever
        // was uploaded, and a transparent PNG would otherwise float.
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
            // SessionStore removes access immediately and RootView presents
            // the persistent, retryable cleanup failure even if this unmounts.
            if session.cleanupErrorMessage == nil { errorMessage = error.localizedDescription }
        }
    }
}
