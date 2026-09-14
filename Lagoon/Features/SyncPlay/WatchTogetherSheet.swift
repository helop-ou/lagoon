import SwiftUI

/// Watch Together's one screen (HEL-172): the groups this server is
/// running, a way to start another, and — once this device is in one —
/// who else is there and what to do about it.
///
/// Always presented from a film or episode's page, so there is an item in
/// hand: starting a group sets that item as its queue, and so does "Play
/// This Here". A group with an empty queue is a room nobody can see into,
/// and Jellyfin has no way to tell the other members what it was for.
///
/// **Nothing here is private.** Every group on the server is listed to
/// every account that may join one, under the name whoever made it chose.
/// The footer says so rather than letting a name imply otherwise.
struct WatchTogetherSheet: View {
    let item: MediaItem
    /// Where a group started from this page begins: the same resume point
    /// Play would use, so starting a group does not silently restart a
    /// film the host was halfway through.
    let startPositionTicks: Int64

    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session
    @Environment(SyncPlayStore.self) private var syncPlay

    @State private var name = ""
    @State private var isWorking = false

    /// Long enough to be a name, short enough to read in a list of them.
    static let nameLimit = 50
    /// The group list is server-wide and other people are changing it.
    /// The socket only carries the group this client is in, so polling is
    /// the only way to see one appear.
    private static let listCadence = Duration.seconds(5)

    var body: some View {
        page
            .task { await pollGroups() }
            .task(id: syncPlay.isJoined) {
                // A fresh sheet, and a sheet whose group just ended, both
                // want the default name back rather than a half-typed one.
                guard !syncPlay.isJoined else { return }
                name = defaultName
            }
            .accessibilityIdentifier("watchTogether.sheet")
    }

    // MARK: - The page

    @ViewBuilder
    private var page: some View {
        #if os(tvOS)
        TVSettingsPage(
            "Watch Together",
            backTitle: "Close",
            description: String(
                localized: "Everyone in a group watches in step: play, pause and skip reach all of you, and the group waits for whoever is still loading."
            )
        ) {
            if syncPlay.isJoined {
                joinedSections
            } else {
                browseSections
            }
        }
        #else
        NavigationStack {
            ThemedForm {
                if syncPlay.isJoined {
                    joinedSections
                } else {
                    browseSections
                }
            }
            .navigationTitle("Watch Together")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "xmark", role: .close) { dismiss() }
                        .accessibilityIdentifier("watchTogether.close")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }

    // MARK: - Already in a group

    @ViewBuilder
    private var joinedSections: some View {
        section("Your Group", footer: nil) {
            VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                Text(syncPlay.session.groupName ?? String(localized: "Watch Together"))
                    .font(.headline)
                Text(stateTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("watchTogether.currentGroup")

            // "Others", because Jellyfin never names this session: the
            // member that created a group is handed an empty participant
            // list and no `UserJoined` of its own.
            if syncPlay.session.participants.isEmpty {
                Text("Nobody else has joined yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(syncPlay.session.participants, id: \.self) { participant in
                    Label(participant, systemImage: "person.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }

        section("This Title", footer: "Everyone in the group moves to it, wherever they were.") {
            actionButton("Play This Here", systemImage: "play.fill", identifier: "watchTogether.playHere") {
                await syncPlay.play(item, startPositionTicks: startPositionTicks)
                dismiss()
            }

            actionButton("Leave Group", systemImage: "rectangle.portrait.and.arrow.right", identifier: "watchTogether.leave") {
                await syncPlay.leave()
                dismiss()
            }
        }
    }

    // MARK: - Not in a group

    @ViewBuilder
    private var browseSections: some View {
        section("Groups on This Server", footer: "Anyone signed in to this server can see these groups and join them.") {
            if syncPlay.groups.isEmpty {
                Text("No groups yet. Start one below and the others can join it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(syncPlay.groups) { group in
                    groupRow(group)
                }
            }
        }

        // `joinOnly` is a real Jellyfin permission, not a corner case: an
        // account may be allowed into other people's groups without being
        // allowed to make one. Offering a control the server would refuse
        // is worse than not offering it.
        if syncPlay.availability.canCreate {
            section("Start a Group", footer: "The group starts on this title, where you left off.") {
                TextField("Group name", text: $name)
                    .onChange(of: name) { _, updated in
                        guard updated.count > Self.nameLimit else { return }
                        name = String(updated.prefix(Self.nameLimit))
                    }
                    .accessibilityIdentifier("watchTogether.name")

                actionButton("Start Group", systemImage: "person.2.fill", identifier: "watchTogether.start") {
                    await syncPlay.startGroup(
                        named: trimmedName,
                        playing: item,
                        startPositionTicks: startPositionTicks
                    )
                    dismiss()
                }
                .disabled(trimmedName.isEmpty || isWorking)
            }
        }
    }

    @ViewBuilder
    private func groupRow(_ group: SyncPlayGroup) -> some View {
        rowButton(identifier: "watchTogether.group.\(group.groupId)") {
            await syncPlay.join(group)
            dismiss()
        } label: {
            HStack(spacing: Metrics.Space.l) {
                VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                    Text(group.groupName.isEmpty ? String(localized: "Watch Together") : group.groupName)
                        .font(.headline)
                    Text(summary(of: group))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: Metrics.Space.s)
                Text("Join")
                    .font(.callout.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
    }

    // MARK: - Copy

    private var stateTitle: String {
        SyncPlayStateCopy.title(for: syncPlay.session.state)
    }

    private func summary(of group: SyncPlayGroup) -> String {
        let state = SyncPlayStateCopy.title(for: group.state)
        guard !group.participants.isEmpty else { return state }
        return "\(state) · \(group.participants.joined(separator: ", "))"
    }

    /// "Jaagop's room" — a name the others recognise without anyone having
    /// to type one. A profile with no name falls back to the feature's own.
    private var defaultName: String {
        guard let user = session.userName, !user.isEmpty else {
            return String(localized: "Watch Together")
        }
        return String(localized: "\(user)'s room")
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Work

    private func pollGroups() async {
        while !Task.isCancelled {
            if !syncPlay.isJoined, syncPlay.availability.canJoin {
                await syncPlay.refreshGroups()
            }
            do { try await Task.sleep(for: Self.listCadence) } catch { return }
        }
    }

    private func perform(_ work: @escaping () async -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            await work()
            isWorking = false
        }
    }

    // MARK: - Platform shapes

    /// One section, in whichever container this platform's page is made of.
    @ViewBuilder
    private func section<Content: View>(
        _ title: LocalizedStringKey,
        footer: LocalizedStringKey?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        #if os(tvOS)
        TVSettingsSection(title, footer: footer) {
            content()
        }
        #else
        Section {
            content()
        } header: {
            Text(title)
        } footer: {
            if let footer { Text(footer) }
        }
        #endif
    }

    /// A labelled action whose work is asynchronous: glass on the TV, a
    /// borderless form row on touch, where several controls share a row
    /// and an automatic button would fire its neighbour.
    private func actionButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        identifier: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            perform(action)
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(tvOS)
        .buttonStyle(.glass)
        #else
        .buttonStyle(.borderless)
        #endif
        .disabled(isWorking)
        .accessibilityIdentifier(identifier)
    }

    private func rowButton<Label: View>(
        identifier: String,
        action: @escaping () async -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            perform(action)
        } label: {
            label()
        }
        #if os(tvOS)
        .buttonStyle(.glass)
        #else
        .buttonStyle(.borderless)
        #endif
        .disabled(isWorking)
        .accessibilityIdentifier(identifier)
    }
}

/// The group's state in the viewer's words, shared by every screen that
/// shows it (HEL-172) so the sheet, the player's Together tab and the
/// toast never disagree about what "Waiting" means.
nonisolated enum SyncPlayStateCopy {
    static func title(for state: SyncPlayGroupState) -> String {
        switch state {
        case .waiting: String(localized: "Waiting for the group")
        case .paused: String(localized: "Paused")
        case .playing: String(localized: "Playing")
        // Both mean the same thing to a viewer: a room with nothing in it
        // yet. There is no useful distinction to draw for a state this
        // client did not recognise.
        case .idle, .unknown: String(localized: "Nothing playing")
        }
    }
}
