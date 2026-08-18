import SwiftUI

/// "Who's watching?" — the remembered server+user pairs, plus a way to add
/// another (HEL-38).
///
/// Not shown at every launch: `SessionStore.restore()` resumes the last
/// account, so a single-profile install never sees this. It appears when no
/// account can be resumed, and whenever Settings asks for it.
struct AccountPickerView: View {
    @Environment(SessionStore.self) private var session

    /// The server line only earns its place when accounts actually span more
    /// than one server; on the common single-server setup it is noise under
    /// every avatar.
    private var showsServer: Bool {
        Set(session.accounts.map(\.serverURL)).count > 1
    }

    var body: some View {
        ZStack {
            BrandBackgroundGradient()

            VStack(spacing: Metrics.Space.section) {
                Text("Who's watching?")
                    .font(.largeTitle.bold())

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
        .contextMenu {
            Button(role: .destructive) {
                session.remove(account)
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
    }

    /// Initials rather than a photo: Jellyfin user images are optional and
    /// usually absent, and an empty avatar frame reads worse than a letter.
    private func avatar(for account: StoredAccount) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Metrics.cardArtRadius)
                .fill(.white.opacity(0.12))
            Text(initials(for: account.displayName))
                .font(.largeTitle.weight(.semibold))
        }
        .frame(width: Metrics.accountTileSize, height: Metrics.accountTileSize)
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}
