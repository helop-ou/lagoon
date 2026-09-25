import SwiftUI

/// "Who's watching?" Full screen when no profile can be resumed, at launch
/// or after signing out. Opened from inside the app it is presented over it:
/// the current profile stays active, carries a check mark, and Back closes
/// the picker.
///
/// Profiles are grouped by server, each group headed by the server's name,
/// address and whether it answered. With one server the headers would all
/// say the same thing, so they collapse into one row.
struct AccountPickerView: View {
    /// True when presented over the app, not as the session's own phase.
    var isPresentedFromApp = false
    /// In-app only: adding a profile opens its own cover, so the presenter
    /// closes the picker first and adds once it is gone.
    var onAddProfile: (() -> Void)?

    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var accountToForget: StoredAccount?
    @State private var reachability: [URL: Reachability] = [:]
    #if os(tvOS)
    @Namespace private var pickerFocus
    #endif

    private enum Reachability {
        case online, offline
    }

    private var groups: [ProfileGrouping.ServerGroup] {
        ProfileGrouping.groups(session.accounts)
    }

    private var portraitSize: CGFloat {
        groups.count > 1 ? Metrics.groupedProfilePortraitSize : Metrics.profilePortraitSize
    }

    /// The iOS sheet sits over the app on the system's sheet background.
    private var drawsGround: Bool {
        #if os(tvOS)
        true
        #else
        !isPresentedFromApp
        #endif
    }

    var body: some View {
        ZStack {
            if drawsGround {
                GroundBackground()
                JellyfishSwimLayer(school: .besideTheRail)
            }

            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: Metrics.Space.xl) {
                        header
                        if groups.count > 1 {
                            serverSections
                            addPill
                        } else if let group = groups.first {
                            profileRow(group, includesAdd: true)
                        } else {
                            addPill
                        }
                    }
                    .padding(.horizontal, Metrics.screenGutter)
                    .padding(.vertical, Metrics.Space.xxl)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
                .scrollClipDisabled()
            }
            #if os(tvOS)
            .focusScope(pickerFocus)
            #endif
        }
        .task(id: groups.map(\.serverURL)) {
            await probeServers()
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

    // MARK: - Header

    private var header: some View {
        VStack(spacing: Metrics.Space.l) {
            if drawsGround {
                LagoonLockup(
                    layout: .horizontal,
                    symbolHeight: Metrics.lockupHeaderSymbolHeight
                )
            }
            Text("Who's watching?")
                .font(.largeTitle.bold())
            if groups.count == 1, let group = groups.first {
                serverLine(group, prefix: "on ")
            }
        }
    }

    // MARK: - Servers

    /// tvOS puts each server beside its row, so three servers still fit on
    /// one screen, and Up and Down move between servers. iOS heads each
    /// section with its server, a grid underneath.
    @ViewBuilder
    private var serverSections: some View {
        #if os(tvOS)
        Grid(horizontalSpacing: Metrics.Space.xxl, verticalSpacing: Metrics.Space.xl) {
            ForEach(groups) { group in
                GridRow {
                    serverLine(group, prefix: "", stacked: true)
                        .gridColumnAlignment(.trailing)
                    profileRow(group, includesAdd: false)
                        .gridColumnAlignment(.leading)
                }
            }
        }
        #else
        ForEach(groups) { group in
            VStack(spacing: Metrics.Space.m) {
                serverLine(group, prefix: "")
                profileRow(group, includesAdd: false)
            }
        }
        #endif
    }

    /// Name, address and status, read as one element by VoiceOver. Stacked,
    /// the address goes under the name, both aligned to the row they label.
    private func serverLine(_ group: ProfileGrouping.ServerGroup, prefix: String, stacked: Bool = false) -> some View {
        let status = reachability[group.serverURL]
        let layout = stacked
            ? AnyLayout(VStackLayout(alignment: .trailing, spacing: Metrics.Space.xs))
            : AnyLayout(HStackLayout(spacing: Metrics.Space.s))
        return layout {
            HStack(spacing: Metrics.Space.s) {
                Circle()
                    .fill(status == .online ? Color.green : Color.secondary)
                    .opacity(status == nil ? 0.4 : 1)
                    .frame(width: Metrics.Space.s, height: Metrics.Space.s)
                Text(prefix + group.name)
                    .font(.headline)
            }
            Text(status == .offline ? "\(group.address) · Offline" : group.address)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(serverAccessibilityLabel(group, status: status))
        .accessibilityIdentifier("account.server.\(group.address)")
    }

    private func serverAccessibilityLabel(_ group: ProfileGrouping.ServerGroup, status: Reachability?) -> String {
        let state = switch status {
        case .online: "online"
        case .offline: "offline"
        case nil: "checking"
        }
        return "\(group.name), \(group.address), \(state)"
    }

    // MARK: - Profiles

    @ViewBuilder
    private func profileRow(_ group: ProfileGrouping.ServerGroup, includesAdd: Bool) -> some View {
        let dimmed = reachability[group.serverURL] == .offline
        #if os(tvOS)
        HStack(alignment: .top, spacing: Metrics.cardSpacing) {
            ForEach(group.accounts) { account in
                portraitButton(account, dimmed: dimmed)
            }
            if includesAdd { addPortrait }
        }
        .focusSection()
        #else
        // Short groups centre under their header instead of hugging the
        // left, and four make a square rather than three and a straggler.
        let count = group.accounts.count + (includesAdd ? 1 : 0)
        let columns = count == 4 ? 2 : min(count, 3)
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: Metrics.cardSpacing), count: max(columns, 1)),
            spacing: Metrics.Space.xl
        ) {
            ForEach(group.accounts) { account in
                portraitButton(account, dimmed: dimmed)
            }
            if includesAdd { addPortrait }
        }
        .frame(maxWidth: (portraitSize + Metrics.Space.xl) * CGFloat(max(columns, 1)) + Metrics.cardSpacing * CGFloat(max(columns - 1, 0)))
        #endif
    }

    private func isCurrent(_ account: StoredAccount) -> Bool {
        isPresentedFromApp && account.id == session.activeAccount?.id
    }

    private func portraitButton(_ account: StoredAccount, dimmed: Bool) -> some View {
        PortraitButton(
            title: account.displayName,
            identifier: "account.select.\(account.userId)",
            size: portraitSize,
            dimmed: dimmed,
            isCurrent: isCurrent(account),
            focusNamespace: focusNamespace,
            onForget: { accountToForget = account }
        ) {
            choose(account)
        } portrait: {
            ProfilePortrait(account: account, size: portraitSize)
        }
    }

    private var focusNamespace: Namespace.ID? {
        #if os(tvOS)
        pickerFocus
        #else
        nil
        #endif
    }

    private var addPortrait: some View {
        PortraitButton(
            title: "Add Profile",
            identifier: "account.add",
            size: portraitSize,
            dimmed: false,
            isCurrent: false,
            focusNamespace: focusNamespace,
            onForget: nil
        ) {
            addProfile()
        } portrait: {
            Circle()
                .fill(.white.opacity(0.1))
                .overlay {
                    Image(systemName: "plus")
                        .font(Typography.glyph)
                }
                .frame(width: portraitSize, height: portraitSize)
        }
    }

    private var addPill: some View {
        Button("Add Profile", systemImage: "plus") {
            addProfile()
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("account.add")
    }

    // MARK: - Actions

    private func addProfile() {
        if let onAddProfile {
            onAddProfile()
        } else {
            session.addAccount()
        }
    }

    private func choose(_ account: StoredAccount) {
        guard isPresentedFromApp else {
            session.switchTo(account)
            return
        }
        dismiss()
        guard account.id != session.activeAccount?.id else { return }
        session.switchTo(account)
    }

    private func probeServers() async {
        let urls = groups.map(\.serverURL)
        await withTaskGroup(of: (URL, Bool).self) { tasks in
            for url in urls {
                tasks.addTask { (url, await JellyfinClient.isReachable(url)) }
            }
            for await (url, reachable) in tasks {
                reachability[url] = reachable ? .online : .offline
            }
        }
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

/// A profile's picture in a circle, or its initials on a colour picked from
/// the user id, so a profile keeps its colour across launches.
struct ProfilePortrait: View {
    let account: StoredAccount
    var size: CGFloat = Metrics.profilePortraitSize

    @Environment(\.displayScale) private var displayScale

    private static let fills: [Color] = [.teal, .pink, .orange, .indigo, .mint, .purple]

    private var fill: Color {
        let seed = account.userId.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return Self.fills[seed % Self.fills.count]
    }

    var body: some View {
        let pixels = ArtworkSizing.pixels(for: size, displayScale: displayScale)
        // Keep the fill under the picture; a transparent PNG would float.
        ZStack {
            Circle().fill(fill.gradient)
            CachedAsyncImage(url: account.avatarURL(maxWidth: pixels), maxPixelSize: pixels) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initials: String {
        let letters = account.displayName.split(separator: " ").prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

/// A round portrait with its name underneath. On tvOS only the portrait is
/// the button, with the system card focus shaped to the circle, and the name
/// stays put below it like the system's own profile rows. Touch makes the
/// whole stack the target.
private struct PortraitButton<Portrait: View>: View {
    let title: String
    let identifier: String
    let size: CGFloat
    let dimmed: Bool
    let isCurrent: Bool
    /// tvOS: where the current profile claims default focus.
    let focusNamespace: Namespace.ID?
    let onForget: (() -> Void)?
    let action: () -> Void
    @ViewBuilder let portrait: () -> Portrait

    var body: some View {
        #if os(tvOS)
        VStack(spacing: Metrics.Space.l) {
            decorated(
                Button(action: action) {
                    portrait()
                }
                .buttonStyle(.card)
                .buttonBorderShape(.circle)
                .accessibilityLabel(title)
                // Outside the button: the card clips its content to the circle.
                .overlay(alignment: .bottomTrailing) { currentBadge }
            )
            name
        }
        .opacity(dimmed ? 0.5 : 1)
        #else
        decorated(
            Button(action: action) {
                VStack(spacing: Metrics.Space.m) {
                    portrait()
                        .overlay(alignment: .bottomTrailing) { currentBadge }
                    name
                }
                .opacity(dimmed ? 0.5 : 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
        )
        #endif
    }

    /// On the focusable button itself: UI tests find it by identifier, and
    /// tvOS delivers press-and-hold and default focus only there.
    @ViewBuilder
    private func decorated<Content: View>(_ button: Content) -> some View {
        let base = button
            .accessibilityIdentifier(identifier)
            .accessibilityValue(isCurrent ? "Current profile" : "")
            .contextMenu {
                if let onForget {
                    Button(role: .destructive, action: onForget) {
                        Label("Forget This User", systemImage: "person.crop.circle.badge.minus")
                    }
                }
            }
        #if os(tvOS)
        if let focusNamespace {
            base.prefersDefaultFocus(isCurrent, in: focusNamespace)
        } else {
            base
        }
        #else
        base
        #endif
    }

    @ViewBuilder
    private var currentBadge: some View {
        if isCurrent {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.black, Color.accentColor)
                .font(.system(size: size * 0.22, weight: .bold))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var name: some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: size + Metrics.Space.xl)
            .accessibilityHidden(true)
    }
}
