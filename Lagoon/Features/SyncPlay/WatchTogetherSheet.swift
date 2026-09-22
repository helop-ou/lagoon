import SwiftUI

/// Watch Together: server groups, starting one, and the joined group.
///
/// Presented from a detail page, so starting a group always queues that
/// item; an empty queue tells other members nothing.
///
/// **Nothing here is private.** Every group is listed to every account that
/// may join; the footer says so.
struct WatchTogetherSheet: View {
    let item: MediaItem
    /// The resume point Play would use, so a group doesn't restart the film.
    let startPositionTicks: Int64

    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session
    @Environment(SyncPlayStore.self) private var syncPlay

    @State private var name = ""
    @State private var isWorking = false

    static let nameLimit = 50
    /// The socket only carries this client's own group, so other groups
    /// need polling.
    private static let listCadence = Duration.seconds(5)

    var body: some View {
        page
            .task { await pollGroups() }
            .task(id: syncPlay.isJoined) {
                guard !syncPlay.isJoined else { return }
                name = defaultName
            }
            .alert("Watch Together", isPresented: Binding(
                get: { syncPlay.errorMessage != nil },
                set: { if !$0 { syncPlay.clearError() } }
            )) {
                Button("OK", role: .cancel) { syncPlay.clearError() }
            } message: {
                Text(syncPlay.errorMessage ?? "")
            }
            .accessibilityIdentifier("watchTogether.sheet")
    }

    // MARK: - The page

    @ViewBuilder
    private var page: some View {
        #if os(tvOS)
        // A modal panel (title, scrolling content, Done), not
        // `TVSettingsPage`, which is a full-screen destination.
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.Space.xxl) {
                    if syncPlay.isJoined {
                        joinedSections
                    } else {
                        browseSections
                    }
                }
                .padding(.horizontal, Metrics.Space.xl)
                .padding(.bottom, Metrics.Space.xl)
            }

            Button("Done") { dismiss() }
                .buttonStyle(.glass)
                .padding(Metrics.Space.l)
                .accessibilityIdentifier("watchTogether.close")
        }
        // tvOS ignores `presentationSizing` for custom content. Fixed size,
        // because the polled group list would resize a fitted panel under focus.
        .frame(
            width: Metrics.modalPanelSize.width,
            height: Metrics.modalPanelSize.height
        )
        .presentationSizing(.fitted)
        .onExitCommand { dismiss() }
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

    #if os(tvOS)
    /// The explainer hides once joined.
    private var header: some View {
        VStack(spacing: Metrics.Space.s) {
            Text("Watch Together")
                .font(.title3.bold())

            if !syncPlay.isJoined {
                Text("Everyone in a group watches in step: play, pause and skip reach all of you, and the group waits for whoever is still loading.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Metrics.Space.l)
    }
    #endif

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

            // A creator can get an empty participant list and no
            // `UserJoined`, so empty still means "you".
            if syncPlay.session.participants.isEmpty {
                Text("Just you so far.")
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
                if await syncPlay.play(item, startPositionTicks: startPositionTicks) { dismiss() }
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

        // Jellyfin can allow joining without creating.
        if syncPlay.availability.canCreate {
            section("Start a Group", footer: "The group starts on this title, where you left off.") {
                TextField("Group name", text: $name)
                    .onChange(of: name) { _, updated in
                        guard updated.count > Self.nameLimit else { return }
                        name = String(updated.prefix(Self.nameLimit))
                    }
                    .accessibilityIdentifier("watchTogether.name")

                actionButton("Start Group", systemImage: "person.2.fill", identifier: "watchTogether.start") {
                    if await syncPlay.startGroup(
                        named: trimmedName,
                        playing: item,
                        startPositionTicks: startPositionTicks
                    ) { dismiss() }
                }
                .disabled(trimmedName.isEmpty || isWorking)
            }
        }
    }

    @ViewBuilder
    private func groupRow(_ group: SyncPlayGroup) -> some View {
        rowButton(identifier: "watchTogether.group.\(group.groupId)") {
            if await syncPlay.join(group) { dismiss() }
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

    /// Borderless on touch: in a shared form row, an automatic button fires
    /// its neighbour.
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

/// Shared so every screen words the group state the same way.
nonisolated enum SyncPlayStateCopy {
    static func title(for state: SyncPlayGroupState) -> String {
        switch state {
        case .waiting: String(localized: "Waiting for the group")
        case .paused: String(localized: "Paused")
        case .playing: String(localized: "Playing")
        case .idle, .unknown: String(localized: "Nothing playing")
        }
    }
}
